(** Tensor shape types and inference. *)

open Base

(** An index pointing to any of a shape's axes, including the kind of the axis kind ([Batch, Input, Output])
    and the position (which is counted from the end to facilitate broadcasting).
    
    Note the following inconsistency due to differing conventions in function notation and matrix notation:
    for label specifications and einsum notation, we write "batch|inputs->outputs", but when we convert
    a shape to an [Ndarray] index we do it in the order [[batch; outputs; inputs]]. *)
module AxisKey = struct
  module T = struct
    type kind = 
      | Batch
      | Input
      | Output
    [@@deriving compare, sexp, variants]
    type t = {
      in_axes: kind;
      from_end: int
      (** Axes are indexed from the end, to avoid reindexing when broadcasting; starting with [1]. *)
     } [@@deriving compare, sexp]
     let to_string key = 
      (match key.in_axes with Batch -> "bch" | Input -> "inp" | Output -> "out") ^
      Int.to_string key.from_end
  end
  include T
  include Comparator.Make(T)
end

type 'a axis_map = 'a Map.M(AxisKey).t [@@deriving compare, sexp]

(** The labels are strings assigned to [AxisKey] axes. *)
type axis_labels = string axis_map [@@deriving compare, sexp]

type dims =
| Given of int list
(** User-provided dimensions. They will not change but will be broadcasted to bigger sizes. *)
| Fixed of int list
(** User-provided dimensions that will fail if used in a different size context, even if broadcastable.
    Note that [Operation.stop_broadcast] implements additional shape logic:
    it converts the (bottom-up i.e. partially inferred) shape into a [Fixed] variant. *)
| Inferred of int list
(** Dimensions that will itself change to a bigger size: they adapt to the broadcasted size. *)
| Unknown
(** User-provided but quivalent to [Inferred []]. *)
[@@deriving compare, sexp, variants]

type deduce_dims =
[ `Not_deduced
| `Preserve
| `Scale of float
] [@@deriving compare, sexp, variants]

(** Converts dimensions according to the specification. Note that scalar axes (1D) are not scaled,
    for compatibility with broadcasting.
    
    Note that in practice [from] will be [Unknown] or [Inferred] dimensions, making it of little relevance
    how the [Given] and [Fixed] cases are interpreted here. *)
let deduce_dims from: deduce_dims -> dims = function
| `Not_deduced -> Unknown
| `Preserve ->
  (match from with
  | Given dims | Fixed dims -> Inferred dims
  | Inferred _ | Unknown -> from)
| `Scale sc ->
  match from with
  | Unknown -> Unknown
  | (Given dims | Fixed dims | Inferred dims) -> Inferred (List.map dims ~f:(
      fun d -> if d = 1 then 1 else Float.(iround_exn ~dir:`Up @@ sc * of_int d)))

(** The datatype from which the actual Ndarray shapes are computed.

    Mutability is sufficient to perform inference, since there is no need for backtracking and
    no explicit unification variables for now. [Unknown] stands for "not yet specified". *)
type t = {
  mutable batch: dims;
  mutable input: dims;
  mutable output: dims;
  mutable axis_labels: axis_labels;
  deduce_output_from_input: deduce_dims;
  (** Intended for terminal node cases where both [input] and [output] are initially
      unknown. It makes it trivial to implement dimension-preserving hidden layers: just set
      [deduce_output_from_input=`Preserve]. *)
} [@@deriving fields, sexp]

let dims_of_kind = function
  | AxisKey.Batch -> batch
  | AxisKey.Input -> input
  | AxisKey.Output -> output

type compose_type =
  [ `Pointwise
  (** NumPy-style broadcast matching batch, input and output axes, e.g. as in [s1 + s2]. *)
  | `Compose
  (** Compose the outputs of the second shape with the inputs of the first shape, i.e. the shape of
      [fun x -> s1(s2(x))], or [s1 * s2] where [*] is the inner product (e.g. matrix multiply). *)
  | `Einsum of axis_labels * axis_labels * axis_labels
  (** A version of the [einsum] syntax. Note that currently [`Pointwise] and [`Compose] are
      not redundant with [`Einsum], because they enable more shape inference: they do not specify
      the number of axes. The [axis_labels] use pseudo-labels local to the notation, to line up the axes.
      For [`Einsum (ls1, ls2, ls3)], the symmetric difference / disjunctive union of [ls1] and [ls2]'s
      pseudo-labels should be equal to [ls3] pseudo-labels.
      
      Currently, we support two variants of the [einsum] syntax: either all the axes are provided,
      or all input, output axes are provided but none of the batch axes. *)
  ]

type transpose_type =
  [ `Transpose
  (** Swaps inputs and outputs of a shape, preserves batch axes. *)
  | `Pointwise
  (** Preserves the shape. *)
  | `Permute of axis_labels * axis_labels
  (** [`Permute (ls1, ls2)] is equivalent to [`Einsum (ls1, ls1, ls2)] (also to 
      [`Einsum (ls1, axis_labels.empty, ls2)] etc.). *)
  ]

(** How to propagate shape updates and do the last update of [Formula.t.shape] when finalizing the formula.
    Axes are broadcast-expanded on a bottom-up update to fit the incoming shape. *)
type logic = 
  | Broadcast of compose_type * t * t
  (** Matches the shapes for a binary operation, allowing for broadcasting e.g. an axis of dimension 1
      does not conflict with a matching axis of a greater dimension.

     For [Broadcast (`Einsum (ls1, ls2, ls3), s1, s2)], the labels of [s1] and [s2] must match according
     to the [ls1], [ls2] lineup, and the resulting shape inherits the labels according to the [ls3] lineup.
  *)
  | Transpose of transpose_type * t
  (** Permutes the axes of a shape. One case of [Transpose] is to swap inputs with outputs of [s1],
      hence the name. *)
  | Terminal

(** Data required for a shape inference update step. A step should equilibrate information, passing it both
    top-down and bottom-up. The child should be identifiable within the parent via physical equality
    (allowing that a child fills both slots of a binary parent). *)
type update_step = {
  shape: t;
  logic: logic;
}

exception Shape_error of string * t * t [@@deriving sexp]

let list_of_dims = function
  | Given ls | Fixed ls | Inferred ls -> ls
  | Unknown -> []
  
(* Design choice: tensor shapes are decided while code is constructed, although not immediately.
   Due to mutable updates during shape inference, it is not possible to reuse the same formula with
   different shapes. The inference is finalized by invoking the [Formula.subtree_shape_updates] once
   on the root formula. *)

(** Performs a local step of shape inference, propagates information into and out of the parent shape
    and the child shape(s). *)
let propagate_shapes (update: update_step) =
  let pointwise_labels debug1 debug2 ls1 ls2 = Map.merge ls1 ls2 ~f:(fun ~key ->
    function
    | `Both (l1, l2) ->
      if String.equal l1 l2 then Some l1
      else
        let error = "Axis label mismatch: "^l1^" vs "^l2^" for "^
                    (Sexp.to_string_hum @@ AxisKey.sexp_of_t key) in
         raise @@ Shape_error (error, debug1, debug2)
    | `Right l | `Left l -> Some l
  ) in
  let broad_dim ~fixed_left ~fixed_right debug1 debug2 axis_key label = function
    | d1, d2 when d1 = d2 -> d1
    | 1, d when not fixed_left -> d
    | d, 1 when not fixed_right -> d
    | d1, d2 ->
      let opt_label = match label with None -> "" | Some l -> " ("^l^")" in
      let error = "Dimension mismatch for axis "^AxisKey.to_string axis_key^opt_label^": "^
                  Int.to_string d1^" vs. "^Int.to_string d2 in
      raise @@ Shape_error (error, debug1, debug2) in
  (* If initially [lhs] is [Unknown], [rhs1] is [sh1] and [rhs2] is [sh2],
     then [lhs] becomes [broadcast_dims sh1 sh2]. *)
  let broadcast_dims sh1 sh2 kind labels sh1_dims sh2_dims =
    let rec broad_back_dims ~fixed_left ~fixed_right accu i = function
    | [], [] -> accu
    | [], dims when not fixed_left -> List.rev_append dims accu
    | dims, [] when not fixed_right -> List.rev_append dims accu
    | [], _ | _, [] ->
      let key = AxisKey.{in_axes=kind; from_end=i} in
      let opt_label = match Map.find labels key with None -> "" | Some l -> " ("^l^")" in
      let error = "Different number of axes around from-end "^AxisKey.to_string key^opt_label in
      raise @@ Shape_error (error, sh1, sh2)
    | d1::dims1, d2::dims2 ->
      let key = AxisKey.{in_axes=kind; from_end=i} in
      broad_back_dims ~fixed_left ~fixed_right
        (broad_dim ~fixed_left ~fixed_right sh1 sh2 key (Map.find labels key) (d1, d2)::accu)
        (i+1) (dims1, dims2) in
    match sh1_dims, sh2_dims with
      | Unknown, Unknown -> Unknown
      | (Inferred dims | Given dims| Fixed dims), Unknown
      | Unknown, (Inferred dims | Given dims | Fixed dims) -> Inferred dims
      | (Inferred dims1 | Given dims1 | Fixed dims1), (Inferred dims2 | Given dims2 | Fixed dims2) ->
        Inferred (broad_back_dims ~fixed_left:(is_fixed sh1_dims) ~fixed_right:(is_fixed sh2_dims)
                    [] 1 (List.rev dims1, List.rev dims2)) in
  let cur_sh = update.shape in
  let update_labels sh1 to_kind sh2 from_kind =
    pointwise_labels sh1 sh2 sh1.axis_labels @@
    Map.map_keys_exn (module AxisKey) ~f:(fun k -> {k with in_axes=to_kind}) @@
    Map.filter_keys sh2.axis_labels ~f:(fun k -> phys_equal k.in_axes from_kind) in
  let broadcast_into to_sh to_kind from_sh from_kind =
    match dims_of_kind to_kind to_sh, dims_of_kind from_kind from_sh with
    | (Given _ | Fixed _) as into_dims, from_dims ->
      ignore @@
        broadcast_dims to_sh from_sh to_kind to_sh.axis_labels into_dims from_dims;
      into_dims
    | into_dims, from_dims ->
      to_sh.axis_labels <- update_labels to_sh to_kind from_sh from_kind;
      broadcast_dims to_sh from_sh to_kind to_sh.axis_labels into_dims from_dims in
  match update.logic with
  | Terminal -> ()
  | Transpose (`Transpose, sh) ->
    cur_sh.input <- broadcast_into cur_sh Input sh Output;
    cur_sh.output <- broadcast_into cur_sh Output sh Input;
    cur_sh.batch <- broadcast_into cur_sh Batch sh Batch;
    sh.input <- broadcast_into sh Input cur_sh Output;
    sh.output <- broadcast_into sh Output cur_sh Input;
    sh.batch <- broadcast_into sh Batch cur_sh Batch;

  | Transpose (`Pointwise, sh) ->
    cur_sh.input <- broadcast_into cur_sh Input sh Input;
    cur_sh.output <- broadcast_into cur_sh Output sh Output;
    cur_sh.batch <- broadcast_into cur_sh Batch sh Batch;
    sh.input <- broadcast_into sh Input cur_sh Input;
    sh.output <- broadcast_into sh Output cur_sh Output;
    sh.batch <- broadcast_into sh Batch cur_sh Batch;

  | Transpose (`Permute einsum, sh) -> 
    (* FIXME: NOT IMPLEMENTED *)
    ignore (einsum, sh); failwith "Not implemented yet"

  | Broadcast (`Pointwise, sh1, sh2) ->
    let up_labels = pointwise_labels sh1 sh2 sh1.axis_labels sh2.axis_labels in
    cur_sh.axis_labels <- up_labels;
    (if is_unknown cur_sh.input then
      cur_sh.input <- broadcast_dims sh1 sh2 AxisKey.Input up_labels sh1.input sh2.input
    else (
      cur_sh.input <- broadcast_into cur_sh Input sh1 Input;
      cur_sh.input <- broadcast_into cur_sh Input sh2 Input;
    ));
    (if is_unknown cur_sh.output then
      cur_sh.output <- broadcast_dims sh1 sh2 AxisKey.Output up_labels sh1.output sh2.output
    else (
      cur_sh.output <- broadcast_into cur_sh Output sh1 Output;
      cur_sh.output <- broadcast_into cur_sh Output sh2 Output;
    ));
    (if is_unknown cur_sh.batch then
      cur_sh.batch <- broadcast_dims sh1 sh2 AxisKey.Batch up_labels sh1.batch sh2.batch
    else (
      cur_sh.batch <- broadcast_into cur_sh Batch sh1 Batch;
      cur_sh.batch <- broadcast_into cur_sh Batch sh2 Batch;
    ));
    
    sh1.input <- broadcast_into sh1 Input cur_sh Input;
    sh1.output <- broadcast_into sh1 Output cur_sh Output;
    sh1.batch <- broadcast_into sh1 Batch cur_sh Batch;
    sh2.input <- broadcast_into sh2 Input cur_sh Input;
    sh2.output <- broadcast_into sh2 Output cur_sh Output;
    sh2.batch <- broadcast_into sh2 Batch cur_sh Batch;

  | Broadcast (`Compose, sh1, sh2) ->
    (** [sh2] is the value or the function that gets applied first: [cur_sh(x) = sh1(sh2(x))].
       I.e. [cur.I = sh2.I, cur.O = sh1.O, sh2.O = sh1.I]. *)
    cur_sh.input <- broadcast_into cur_sh AxisKey.Input sh2 AxisKey.Input;
    cur_sh.output <- broadcast_into cur_sh AxisKey.Output sh1 AxisKey.Output;
    (if is_unknown cur_sh.batch then
      let up_labels = update_labels cur_sh Batch sh1 Batch in
      cur_sh.axis_labels <- up_labels;
      let up_labels = update_labels cur_sh Batch sh2 Batch in
      cur_sh.axis_labels <- up_labels;
      cur_sh.batch <- broadcast_dims sh1 sh2 AxisKey.Batch up_labels sh1.batch sh2.batch
     else (
       cur_sh.batch <- broadcast_into cur_sh Batch sh1 Batch;
       cur_sh.batch <- broadcast_into cur_sh Batch sh2 Batch;
     ));
    
    sh1.input <- broadcast_into sh1 Input sh2 Output;
    sh1.output <- broadcast_into sh1 Output cur_sh Output;
    sh1.batch <- broadcast_into sh1 Batch cur_sh Batch;
    sh2.input <- broadcast_into sh2 Input cur_sh Input;
    sh2.output <- broadcast_into sh2 Output sh1 Input;
    sh2.batch <- broadcast_into sh2 Batch cur_sh Batch;

    (* Always re-derive the output shape, to have the latest information. *)
    if not @@ is_not_deduced sh1.deduce_output_from_input then
      sh1.output <- deduce_dims sh2.input sh1.deduce_output_from_input

  | Broadcast (`Einsum spec, sh1, sh2) ->
    (* FIXME: NOT IMPLEMENTED *)
    ignore (spec, sh1, sh2); failwith "Not implemented yet"

(** Uses the matrix convention of putting the input axes last. *)
let to_dims (sh: t): int array =
  let b_dims = match sh.batch with
    | Unknown -> raise @@ Shape_error ("Batch dimensions still unknown", sh, sh)
    | Inferred dims | Given dims | Fixed dims -> Array.of_list dims in
  let i_dims = match sh.input with
    | Unknown -> raise @@ Shape_error ("Input dimensions still unknown", sh, sh)
    | Inferred dims | Given dims | Fixed dims -> Array.of_list dims in
  let o_dims = match sh.output with
    | Unknown -> raise @@ Shape_error ("Output dimensions still unknown", sh, sh)
    | Inferred dims | Given dims | Fixed dims -> Array.of_list dims in
  Array.concat [b_dims; o_dims; i_dims]

type symbol = Symbol of int [@@deriving compare, sexp, variants]
let unique_id = ref 0
let get_symbol() = Int.incr unique_id; Symbol !unique_id

(** An index into a single axis for doing computations over multiple [Shape]-derived [Ndarray]s. *)
type axis_index =
| Fixed_idx of int
(** The specific position along an axis. *)
| Iterator of symbol [@@deriving compare, sexp, variants]
(** The given member of the [product_space] corresponding to some [product_iterators]. *)
  
(** All the information relevant for [Ndarray] code generation contained in a completed [update_step]. *)
type projections = {
  product_space: int array;
  (** The product space dimensions (concatentation of the relevant batch, output, input axes) with
      the same semantics as [to_dims], that an operation should parallelize (map-reduce) over. *)
  product_iterators: symbol array;
  (** The product space iterators (concatentation of the relevant batch, output, input axes)
      for iterating over the [product_space] axes, where same axes are at same array indices. *)
  project_lhs: axis_index array;
  (** A projection that takes an [product_space]-bound index and produces an index into the result of
      an operation. *)
  project_rhs1: axis_index array;
  (** A projection that takes an [product_space]-bound index and produces an index into the (first)
      argument of an operation. *)
  project_rhs2: axis_index array option;
  (** A projection that takes an [product_space]-bound index and produces an index into the second
      argument of a binary operation. *)
}

(** Projections for iterating over a terminal [Ndarray], or for a pointwise unary operator. *)
let terminal_projections sh =
  let product_space = to_dims sh in
  let product_iterators = Array.map product_space ~f:(fun _ -> get_symbol()) in
  let project_lhs = Array.map product_iterators ~f:iterator in
  { product_space; product_iterators; project_lhs; project_rhs1=project_lhs; project_rhs2=None; }

(** Computes the indexing into subformulas given the shape information of a formula. The processing
    mirrors [propagate_shapes], but [derive_projections] should only be invoked when the shapes
    are inferred already. *)
let derive_projections (shapes: update_step) : projections =
  (* Broadcasts symmetrically to iterate all axes. *)
  let broadcast_dims sh1_dims sh2_dims =
    let broad_dim = function
    | d1, d2 when d1 = d2 -> d1, get_symbol()
    | 1, d | d, 1 -> d, get_symbol()
    | _ -> assert false in
    let rec broad_back_dims (accu_dims, accu_idcs as accu) = function
    | [], [] -> accu
    | dims, [] | [], dims ->
      List.rev_append dims accu_dims, List.rev_map_append dims accu_idcs ~f:(fun _ -> get_symbol())
    | d1::dims1, d2::dims2 ->
      let d, idx = broad_dim (d1, d2) in
      broad_back_dims (d::accu_dims, idx::accu_idcs) (dims1, dims2) in
    match sh1_dims, sh2_dims with
      | Unknown, Unknown -> [], []
      | (Inferred dims | Given dims| Fixed dims), Unknown
      | Unknown, (Inferred dims | Given dims | Fixed dims) ->
        dims, List.map dims ~f:(fun _ -> get_symbol())
      | (Inferred dims1 | Given dims1 | Fixed dims1), (Inferred dims2 | Given dims2 | Fixed dims2) ->
        broad_back_dims ([], []) (List.rev dims1, List.rev dims2) in
  let broadcast_sh sh1 kind1 sh2 kind2 =
    broadcast_dims (dims_of_kind kind1 sh1) (dims_of_kind kind2 sh2) in
  (* The first arg is "into" we build the projection for, the second arg is the context. *)
  let broadcast_into_dims product_idcs sh1_dims sh2_dims =
    let broad_dim idx = function
      (* It is less error-prone to handle 1 as Fixed_idx -- less dependence on what sh2 is. *)
    | 1, _d -> Fixed_idx 0
    | _ -> Iterator idx in
    let rec broad_back_dims accu_idcs = function
    | [], [], [] -> accu_idcs
    | _idcs, [], _dims -> accu_idcs
    | idcs, _dims, [] -> List.rev_map_append idcs accu_idcs ~f:iterator
    | idx::idcs, d1::dims1, d2::dims2 ->
      broad_back_dims (broad_dim idx (d1, d2)::accu_idcs) (idcs, dims1, dims2)
    | _ -> assert false in
    match sh1_dims, sh2_dims with
      | Unknown, Unknown ->
        assert (0 = List.length product_idcs); 
        []
      | (Inferred dims | Given dims| Fixed dims), Unknown
      | Unknown, (Inferred dims | Given dims | Fixed dims) ->
        assert (List.length dims = List.length product_idcs);
        List.map product_idcs ~f:iterator
      | (Inferred dims1 | Given dims1 | Fixed dims1), (Inferred dims2 | Given dims2 | Fixed dims2) ->
        broad_back_dims [] (List.rev product_idcs, List.rev dims1, List.rev dims2) in
  let broadcast_into product_idcs sh1 kind1 sh2 kind2 =
    broadcast_into_dims product_idcs (dims_of_kind kind1 sh1) (dims_of_kind kind2 sh2) in
  let cur_sh = shapes.shape in
  (* For binary cases, we cannot rely on [cur_sh] containing all axes, since in principle it could
     have been restricted by an initial [Given] setting to efficiently implement map-reduce. *)
  match shapes.logic with
  | Terminal -> terminal_projections cur_sh
  | Transpose (`Transpose, sh) ->
    let product_inp, iters_inp = broadcast_sh cur_sh Input sh Output in
    let lhs_input = broadcast_into iters_inp cur_sh Input sh Output in
    let product_out, iters_out = broadcast_sh cur_sh Output sh Input in
    let lhs_output = broadcast_into iters_out cur_sh Output sh Input in
    let product_bch, iters_bch = broadcast_sh cur_sh Batch sh Batch in
    let lhs_batch = broadcast_into iters_bch cur_sh Batch sh Batch in
    let rhs_input = broadcast_into iters_out sh Input cur_sh Output in
    let rhs_output = broadcast_into iters_inp sh Output cur_sh Input in
    let rhs_batch = broadcast_into iters_bch sh Batch cur_sh Batch in
    let product_space =
      Array.of_list @@ List.concat [product_bch; product_out; product_inp] in
    let product_iterators =
      Array.of_list @@ List.concat [iters_bch; iters_out; iters_inp] in
    let project_lhs =
      Array.of_list @@ List.concat [lhs_batch; lhs_output; lhs_input] in
    let project_rhs1 =
      Array.of_list @@ List.concat [rhs_batch; rhs_output; rhs_input] in    
    { product_space; product_iterators; project_lhs; project_rhs1; project_rhs2 = None }

  | Transpose (`Pointwise, sh) ->
    let product_inp, iters_inp = broadcast_sh cur_sh Input sh Input in
    let lhs_input = broadcast_into iters_inp cur_sh Input sh Input in
    let product_out, iters_out = broadcast_sh cur_sh Output sh Output in
    let lhs_output = broadcast_into iters_out cur_sh Output sh Output in
    let product_bch, iters_bch = broadcast_sh cur_sh Batch sh Batch in
    let lhs_batch = broadcast_into iters_bch cur_sh Batch sh Batch in
    let rhs_input = broadcast_into iters_out sh Input cur_sh Input in
    let rhs_output = broadcast_into iters_inp sh Output cur_sh Output in
    let rhs_batch = broadcast_into iters_bch sh Batch cur_sh Batch in
    let product_space =
      Array.of_list @@ List.concat [product_bch; product_out; product_inp] in
    let product_iterators =
      Array.of_list @@ List.concat [iters_bch; iters_out; iters_inp] in
    let project_lhs =
      Array.of_list @@ List.concat [lhs_batch; lhs_output; lhs_input] in
    let project_rhs1 =
      Array.of_list @@ List.concat [rhs_batch; rhs_output; rhs_input] in    
    { product_space; product_iterators; project_lhs; project_rhs1; project_rhs2 = None }
    
  | Transpose (`Permute einsum, sh) -> 
    (* FIXME: NOT IMPLEMENTED *)
    ignore (einsum, sh); failwith "Not implemented yet"

  | Broadcast (`Pointwise, sh1, sh2) ->
    let product_inp, iters_inp = broadcast_sh sh1 Input sh2 Input in
    let lhs1_input = broadcast_into iters_inp cur_sh Input sh1 Input in
    let product_out, iters_out = broadcast_sh sh1 Output sh2 Output in
    let lhs1_output = broadcast_into iters_out cur_sh Output sh1 Output in
    let product_bch, iters_bch = broadcast_sh sh1 Batch sh2 Batch in
    let lhs1_batch = broadcast_into iters_bch cur_sh Batch sh1 Batch in
    let rhs1_input = broadcast_into iters_inp sh1 Input cur_sh Input in
    let rhs1_output = broadcast_into iters_out sh1 Output cur_sh Output in
    let rhs1_batch = broadcast_into iters_bch sh1 Batch sh2 Batch in
    let lhs2_input = broadcast_into iters_inp cur_sh Input sh2 Input in
    let lhs2_output = broadcast_into iters_out cur_sh Output sh2 Output in
    let lhs2_batch = broadcast_into iters_bch cur_sh Batch sh2 Batch in
    let rhs2_input = broadcast_into iters_inp sh2 Input cur_sh Input in
    let rhs2_output = broadcast_into iters_out sh2 Output cur_sh Output in
    let rhs2_batch = broadcast_into iters_bch sh2 Batch sh1 Batch in
    let product_space =
      Array.of_list @@ List.concat [product_bch; product_out; product_inp] in
    let product_iterators =
      Array.of_list @@ List.concat [iters_bch; iters_out; iters_inp] in
    let project_lhs =
      Array.of_list @@ List.concat [lhs1_batch; lhs1_output; lhs1_input] in
    let project_lhs_verify =
      Array.of_list @@ List.concat [lhs2_batch; lhs2_output; lhs2_input] in
    assert (Array.equal (fun a b -> compare_axis_index a b = 0) project_lhs project_lhs_verify);
    let project_rhs1 =
      Array.of_list @@ List.concat [rhs1_batch; rhs1_output; rhs1_input] in    
    let project_rhs2 =
      Some (Array.of_list @@ List.concat [rhs2_batch; rhs2_output; rhs2_input]) in    
    { product_space; product_iterators; project_lhs; project_rhs1; project_rhs2 }

  | Broadcast (`Compose, sh1, sh2) ->
    (** [sh2] is the value or the function that gets applied first: [cur_sh(x) = sh1(sh2(x))].
       I.e. [cur.I = sh2.I, cur.O = sh1.O, sh2.O = sh1.I]. *)
    let product_inp, iters_inp = broadcast_sh cur_sh Input sh2 Input in
    let lhs_input = broadcast_into iters_inp cur_sh Input sh2 Input in
    let product_out, iters_out = broadcast_sh cur_sh Output sh1 Output in
    let lhs_output = broadcast_into iters_out cur_sh Output sh1 Output in
    let product_bch, iters_bch = broadcast_sh sh1 Batch sh2 Batch in
    let lhs1_batch = broadcast_into iters_bch cur_sh Batch sh1 Batch in
    let lhs2_batch = broadcast_into iters_bch cur_sh Batch sh2 Batch in
    assert (List.equal (fun a b -> compare_axis_index a b = 0) lhs1_batch lhs2_batch);

    let product_hid, iters_hid = broadcast_sh sh1 Input sh2 Output in
    let rhs1_input = broadcast_into iters_hid sh1 Input sh2 Output in
    let rhs1_output = broadcast_into iters_out sh1 Output cur_sh Output in
    let rhs1_batch = broadcast_into iters_bch sh1 Batch sh2 Batch in
    let rhs2_input = broadcast_into iters_inp sh2 Input cur_sh Input in
    let rhs2_output = broadcast_into iters_hid sh2 Output sh1 Input in
    let rhs2_batch = broadcast_into iters_bch sh2 Batch sh1 Batch in
    let product_space =
      Array.of_list @@ List.concat [product_bch; product_out; product_hid; product_inp] in
    let product_iterators =
      Array.of_list @@ List.concat [iters_bch; iters_out; iters_hid; iters_inp] in
    let project_lhs =
      Array.of_list @@ List.concat [lhs1_batch; lhs_output; lhs_input] in
    let project_rhs1 =
      Array.of_list @@ List.concat [rhs1_batch; rhs1_output; rhs1_input] in    
    let project_rhs2 =
      Some (Array.of_list @@ List.concat [rhs2_batch; rhs2_output; rhs2_input]) in    
    { product_space; product_iterators; project_lhs; project_rhs1; project_rhs2 }

  | Broadcast (`Einsum spec, sh1, sh2) ->
    (* FIXME: NOT IMPLEMENTED *)
    ignore (spec, sh1, sh2); failwith "Not implemented yet"

let backprop1 projections = {
  projections with project_lhs = projections.project_rhs1; project_rhs1 = projections.project_lhs;
}

let backprop2 projections =
  match projections.project_rhs2 with
  | None -> invalid_arg "Shape.backprop2: unary shapes (project_rhs2 is None)"
  | Some project_rhs2 -> 
    { projections with project_lhs = project_rhs2; project_rhs2 = Some projections.project_lhs }

let backprop_unary projections = {
  projections with project_lhs = projections.project_rhs1; project_rhs1 = projections.project_lhs;
                   project_rhs2 = Some projections.project_lhs;
}

let derive_index iterators projection =
  let sym_to_i =
    Array.mapi iterators ~f:(fun i (Symbol s) -> s, i) |> Array.to_list |> Map.of_alist_exn (module Int) in
  let positions = Array.map projection ~f:(
    function
    | Fixed_idx i -> i
    | Iterator (Symbol s) -> Map.find_exn sym_to_i s
  ) in
  fun product -> Array.map positions ~f:(fun p -> product.(p))

(* ********** User API below ********** *)


(** Parses a labels specification.

    * If [spec] contains any of: [' '; ','; '('; ')'], these characters are used as label separators.
    Otherwise, every character is a label.
    * If [spec] does not contain ["|"] nor ["->"], each label is of the kind [Output].
    * If [spec] doesn't contain ["|"], labels to the left of ["->"] are [Input] and to the right [Output].
    * Labels to the left of ["|"] are [Batch], and between ["|"] and ["->"] are [Input]. *)
let axis_labels_of_spec spec: axis_labels =
  if List.exists ~f:(String.contains spec) [' '; ','; '('; ')'] then
    (* FIXME: NOT IMPLEMENTED *)
    failwith "Multicharacter axis labels are not implemented yet"
  else
    let batch_spec, spec =
      match String.substr_index spec ~pattern:"|" with
      | Some end_bch -> String.sub ~pos:0 ~len:end_bch spec,
                        String.sub ~pos:(end_bch+1) ~len:(String.length spec - end_bch - 1) spec
      | None -> "", spec in
    let input_spec, output_spec =
      match String.substr_index spec ~pattern:"->" with
      | Some end_inp -> String.sub ~pos:0 ~len:end_inp spec,
                        String.sub ~pos:(end_inp+2) ~len:(String.length spec - end_inp - 2) spec
      | None -> "", spec in
    let batch_labels = String.foldi batch_spec ~init:(Map.empty (module AxisKey))
        ~f:(fun from_start labels label -> Map.add_exn labels 
               ~key:AxisKey.{in_axes=Batch; from_end=String.length batch_spec - from_start}
               ~data:(String.of_char label)) in
    let input_labels = String.foldi input_spec ~init:(Map.empty (module AxisKey))
        ~f:(fun from_start labels label -> Map.add_exn labels 
               ~key:AxisKey.{in_axes=Input; from_end=String.length input_spec - from_start}
               ~data:(String.of_char label)) in
    let output_labels = String.foldi output_spec ~init:(Map.empty (module AxisKey))
        ~f:(fun from_start labels label -> Map.add_exn labels 
               ~key:AxisKey.{in_axes=Output; from_end=String.length output_spec - from_start}
               ~data:(String.of_char label)) in
    match Map.append ~lower_part:input_labels ~upper_part:output_labels with
    | `Ok m -> (match Map.append ~lower_part:batch_labels ~upper_part:m with `Ok r -> r | _ -> assert false)
    | _ -> assert false

  (* TODO: implement [einsum_of_spec] using a ["spec;spec=>spec"] syntax. *)

(** Given a fully-inferred shape, maps axes to their corresponding positions in an index using the
    [Shape.to_dims] semantics. *)
let axis_keys_to_idcs (sh: t): int axis_map =
  let b_dims = match sh.batch with
    | Unknown -> raise @@ Shape_error ("Batch dimensions still unknown", sh, sh)
    | Inferred dims | Given dims | Fixed dims ->
      (* Enumerate axes backwards. *)
      Array.of_list_mapi dims ~f:(fun i _ -> AxisKey.{ in_axes=Batch; from_end=i + 1 }) in
  let i_dims = match sh.input with
    | Unknown -> raise @@ Shape_error ("Input dimensions still unknown", sh, sh)
    | Inferred dims | Given dims | Fixed dims ->
      Array.of_list_mapi dims ~f:(fun i _ -> AxisKey.{ in_axes=Input; from_end=i + 1 }) in
  let o_dims = match sh.output with
    | Unknown -> raise @@ Shape_error ("Output dimensions still unknown", sh, sh)
    | Inferred dims | Given dims | Fixed dims ->
      Array.of_list_mapi dims ~f:(fun i _ -> AxisKey.{ in_axes=Output; from_end=i + 1 }) in
  let idcs = Array.concat [i_dims; o_dims; b_dims] in
  Array.rev_inplace idcs;
  Map.of_alist_exn (module AxisKey) @@ Array.to_list @@ Array.mapi idcs ~f:(fun i key -> key, i)

(** Converts an axes-keyed map into an array of values using the [Shape.to_dims] semantics of axes.
    If the map is incomplete, the result might be invalid: gaps in the array are filled with an arbitrary
    one of the provided values. *)
let axis_map_to_dims_index (type a) (idcs: a axis_map): a array =
  let _, witness = Map.min_elt_exn idcs in
  let bch_axes, other = Map.partition_mapi idcs ~f:(
    fun ~key:{in_axes; _} ~data -> if AxisKey.is_batch in_axes then Either.First data else Either.Second data) in
  let inp_axes, out_axes = Map.partition_mapi other ~f:(
    fun ~key:{in_axes; _} ~data -> if AxisKey.is_input in_axes then Either.First data else Either.Second data) in
  let bch_axes = Map.to_alist bch_axes |> List.map ~f:(fun ({from_end=i; _}, v) -> i, v) in
  let bch_size = List.fold bch_axes ~init:0 ~f:(fun accu (i,_) -> max i accu) in
  let bch = Array.create ~len:bch_size witness in
  List.iter bch_axes ~f:(fun (i,v) -> bch.(bch_size - i) <- v);
  let inp_axes = Map.to_alist inp_axes |> List.map ~f:(fun ({from_end=i; _}, v) -> i, v) in
  let inp_size = List.fold inp_axes ~init:0 ~f:(fun accu (i,_) -> max i accu) in
  let inp = Array.create ~len:inp_size witness in
  List.iter inp_axes ~f:(fun (i,v) -> inp.(inp_size - i) <- v);
  let out_axes = Map.to_alist out_axes |> List.map ~f:(fun ({from_end=i; _}, v) -> i, v) in
  let out_size = List.fold out_axes ~init:0 ~f:(fun accu (i,_) -> max i accu) in
  let out = Array.create ~len:out_size witness in
  List.iter out_axes ~f:(fun (i,v) -> out.(out_size - i) <- v);
 Array.concat [bch; out; inp]

(** Specification of a terminal [Formula.t]'s shape. The [string] occurrences refer to [axis_labels]
    specs. *)
type term_spec =
  [ `Unknown
  (** The shape will need to be fully inferred. *)
  | `Constant of int list * string
  (** [`Constant (output_dims, labels)]
      A constant shape has no batch nor input dimensions, only output dimensions. *)
  | `Data of int list * int list * string
  (** [`Data (batch_dims, output_dims, labels)]
      A data shape does not have input dimensions. *)
  | `Params of int list *  int list * string
  (** [`Params (input_dims, output_dims, labels)]
      A parameters shape with fixed dimensionality. Parameters do not have batch dimensions. *)
  | `Unknown_batch_data of int list * string
  (** [`Unknown_batch_data (output_dims, labels)]
      A data shape where the batch dimensions are left up to inference. *)
  | `Deduced_params of deduce_dims
    (** Parameters with inferred dimensionality. Use cases:
        [`Deduced_params `Not_deduced] -- the shape will need to be fully inferred (no batch dims).
        [`Deduced_params `Preserve] -- a hidden layer preserving the dimensionality.
        [`Deduced_params (`Scale 2.0)] -- an expansion hidden layer doubling the dimensionality.
        [`Deduced_params (`Scale 0.5)] -- an bottleneck hidden layer halving the dimensionality.
        Note that scalar axes (1D) are not scaled, for compatibility with broadcasting. *)
  ] [@@deriving compare, sexp]

let of_term_spec : term_spec -> t = function
  | `Unknown ->
    { batch=Unknown; input=Unknown; output=Unknown;
      axis_labels=Map.empty (module AxisKey);
      deduce_output_from_input=`Not_deduced }
  | `Constant (dims, labels_spec) ->
    { batch=Given []; input=Given []; output=Given dims;
      axis_labels=axis_labels_of_spec labels_spec;
      deduce_output_from_input=`Not_deduced }
  | `Data (batch_dims, dims, labels_spec) ->
    { batch=Given batch_dims; input=Given []; output=Given dims;
      axis_labels=axis_labels_of_spec labels_spec;
      deduce_output_from_input=`Not_deduced }
  | `Params (input_dims, output_dims, labels_spec) ->
    { batch=Given []; input=Given input_dims; output=Given output_dims;
      axis_labels=axis_labels_of_spec labels_spec;
      deduce_output_from_input=`Not_deduced }
  | `Unknown_batch_data (dims, labels_spec) ->
    { batch=Unknown; input=Given []; output=Given dims;
      axis_labels=axis_labels_of_spec labels_spec;
      deduce_output_from_input=`Not_deduced }
  | `Deduced_params deduce_output_from_input ->
    { batch=Given []; input=Unknown; output=Unknown;
      axis_labels=Map.empty (module AxisKey);
      deduce_output_from_input }
  
let to_dims_code (sh: t): int array Codelib.code =
  let dims = Array.map (to_dims sh) ~f:(Lifts.Lift_int.lift) in
  Lifts.lift_array dims

let to_string_hum sh =
  let dims_to_string kind =
    let dims = list_of_dims @@ dims_of_kind kind sh in
    let n_dims = List.length dims in
    String.concat ~sep:"," @@ List.mapi dims ~f:(fun i d ->
        let key = AxisKey.{in_axes=kind; from_end=n_dims - i} in
        let label = match Map.find sh.axis_labels key with None -> ""
         | Some l -> l^":" in
        label^Int.to_string d) in
  let batch_dims = dims_to_string Batch in
  let input_dims = dims_to_string Input in
  let output_dims = dims_to_string Output in
  if String.is_empty batch_dims && String.is_empty input_dims then output_dims
  else if String.is_empty batch_dims then input_dims^"->"^output_dims
  else if String.is_empty input_dims then batch_dims^"|"^output_dims
  else batch_dims^"|"^input_dims^"->"^output_dims