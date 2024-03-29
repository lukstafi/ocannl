(** The row type, shape inference related types and constraint solving. *)

open Base
module Utils = Arrayjit.Utils

module Dim_var = struct
  type t = { id : int; label : string option [@compare.ignore] [@equal.ignore] [@hash.ignore] }
  [@@deriving equal, hash, compare, sexp]

  include Comparator.Make (struct
    type nonrec t = t

    let compare = compare
    let sexp_of_t = sexp_of_t
  end)
end

type dim_var = Dim_var.t [@@deriving equal, hash, compare, sexp]
type dim_cmp = Dim_var.comparator_witness
type 'a dim_map = 'a Map.M(Dim_var).t [@@deriving equal, sexp]

let dim_map_empty = Map.empty (module Dim_var)

(** A single axis in a shape. *)
type dim = Var of dim_var | Dim of { d : int; label : string option; proj_id : int option }
[@@deriving equal, hash, compare, sexp, variants]

let uid = ref 0

let get_var ?label () : dim_var =
  Int.incr uid;
  { id = !uid; label }

let get_dim ~d ?label () = Dim { d; label; proj_id = None }

type 'a dim_hashtbl = 'a Hashtbl.M(Dim_var).t [@@deriving sexp]

let dim_hashtbl () = Hashtbl.create (module Dim_var)

let dim_to_string style = function
  | Dim { label = None; _ } when phys_equal style `Only_labels -> "_"
  | Dim { label = Some l; _ } when phys_equal style `Only_labels -> l
  | Dim { d; label = None; _ } -> Int.to_string d
  | Dim { d; label = Some l; _ } -> [%string "%{l}=%{d#Int}"]
  | Var { id; label = Some l } -> [%string "$%{id#Int}:%{l}"]
  | Var { id; label = None } -> "$" ^ Int.to_string id

module Row_var = struct
  type t = Row_var of int [@@deriving equal, hash, compare, sexp]

  include Comparator.Make (struct
    type nonrec t = t

    let compare = compare
    let sexp_of_t = sexp_of_t
  end)

  let get () =
    Int.incr uid;
    Row_var !uid
end

type row_var = Row_var.t [@@deriving equal, hash, compare, sexp]

let get_row_var = Row_var.get

(** A bcast specifies how axes of a single kind in a shape (i.e. the row) can adapt to other shapes. *)
type bcast =
  | Row_var of row_var  (** The row can be inferred to have more axes. *)
  | Broadcastable  (** The shape does not have more axes of this kind, but is "polymorphic". *)
[@@deriving equal, hash, compare, sexp, variants]

type kind = [ `Batch | `Input | `Output ] [@@deriving equal, compare, sexp, hash, variants]

module Row_id = struct
  type t = { sh_id : int; kind : kind } [@@deriving sexp, compare, equal, hash]

  include Comparator.Make (struct
    type nonrec t = t

    let compare = compare
    let sexp_of_t = sexp_of_t
  end)
end

type row_id = Row_id.t [@@deriving sexp, compare, equal, hash]
type row_cmp = Row_id.comparator_witness

let row_id ~sh_id ~kind = Row_id.{ sh_id; kind }

(* let row_map_empty = Map.empty (module Row_id) *)

type t = { dims : dim list; bcast : bcast; id : row_id } [@@deriving equal, hash, compare, sexp]
type row = t [@@deriving equal, sexp]

let dims_label_assoc dims =
  let f = function Var { label = Some l; _ } as d -> Some (l, d) | _ -> None in
  List.filter_map dims.dims ~f

(** An entry implements inequalities [cur >= v >= subr] and/or an equality [v = solved].
    [cur] and [subr] must be sorted using the [@@deriving compare] comparison. *)
type ('a, 'b) entry = Solved of 'b | Bounds of { cur : 'a list; subr : 'a list; lub : 'b option }
[@@deriving sexp]

type dim_env = (dim_var, dim) entry Map.M(Dim_var).t [@@deriving sexp]
type row_env = (row_var, t) entry Map.M(Row_var).t [@@deriving sexp]

type environment = { dim_env : dim_env; row_env : row_env } [@@deriving sexp]
(** Note that while we build up the partial sets of inequalities, the environment is not in solved form.
    It is only in resolved wrt. variables that are solved: [v -> e where Option.is_some e.solved]
    do not appear elsewhere in the environment. But once [finish_inference] is called, it becomes in
    solved form: variables later in the elimination order do not appear in entries for variables
    earlier in the elimination order. *)

type dims_constraint =
  | Unconstrained
  | Total_elems of int  (** The shape-kind, inclusive of the further row spec, has this many elements. *)
[@@deriving equal, hash, compare, sexp, variants]

type inequality =
  | Dim_eq of { d1 : dim; d2 : dim }
  | Row_eq of { r1 : t; r2 : t }
  | Dim_ineq of { cur : dim; subr : dim }
  | Row_ineq of { cur : t; subr : t }
  | Row_constr of { r : t; constr : dims_constraint }
  | Terminal_dim of dim
  | Terminal_row of t
[@@deriving compare, equal, sexp, variants]

module Idx = Arrayjit.Indexing

type error_trace = ..
type error_trace += Row_mismatch of t list | Dim_mismatch of dim list | Index_mismatch of Idx.axis_index list

let sexp_of_error_trace = function
  | Row_mismatch rs -> Sexp.List (Sexp.Atom "Row_mismatch" :: List.map rs ~f:sexp_of_t)
  | Dim_mismatch ds -> Sexp.List (Sexp.Atom "Dim_mismatch" :: List.map ds ~f:sexp_of_dim)
  | Index_mismatch idcs -> Sexp.List (Sexp.Atom "Index_mismatch" :: List.map idcs ~f:Idx.sexp_of_axis_index)
  | _ -> Sexp.Atom "<outdated version of sexp_of_error_trace>"

exception Shape_error of string * error_trace list [@@deriving sexp_of]

let dim_to_int_exn = function Dim { d; _ } -> d | Var _ -> invalid_arg "dim_to_int: dim still unknown"
let s_dim_one v ~value ~in_ = match in_ with Var v2 when equal_dim_var v v2 -> value | _ -> in_

let s_dim_one_in_entry v ~value in_ =
  match in_ with
  | Solved in_ -> ([], Solved (s_dim_one v ~value ~in_))
  | Bounds { cur; subr; lub } ->
      let find_v side = List.partition_tf side ~f:(equal_dim_var v) in
      let v_cur, cur = find_v cur in
      let v_subr, subr = find_v subr in
      let ineqs0 =
        match (v_subr, lub) with _ :: _, Some lub -> [ Dim_ineq { cur = lub; subr = value } ] | _ -> []
      in
      let ineqs1 =
        if List.is_empty v_subr then []
        else List.map cur ~f:(fun cur -> Dim_ineq { cur = Var cur; subr = value })
      in
      let ineqs2 =
        if List.is_empty v_cur then []
        else List.map subr ~f:(fun subr -> Dim_ineq { subr = Var subr; cur = value })
      in
      ( ineqs0 @ ineqs1 @ ineqs2,
        Bounds { cur; subr; lub = Option.map lub ~f:(fun in_ -> s_dim_one v ~value ~in_) } )

let s_dim_one_in_row v ~value in_ =
  { in_ with dims = List.map in_.dims ~f:(fun in_ -> s_dim_one v ~value ~in_) }

let s_dim_one_in_row_entry v ~value in_ =
  match in_ with
  | Solved in_ -> Solved (s_dim_one_in_row v ~value in_)
  | Bounds { cur; subr; lub } -> Bounds { cur; subr; lub = Option.map lub ~f:(s_dim_one_in_row v ~value) }

let rec subst_dim env = function
  | Dim _ as d -> d
  | Var v as default -> (
      match Map.find env.dim_env v with
      | Some (Solved (Var v2)) when equal_dim_var v v2 -> default
      | Some (Solved d) -> subst_dim env d
      | _ -> default)

let s_row_one v ~value:{ dims = more_dims; bcast; id = _ } ~in_ =
  match in_ with
  | { dims; bcast = Row_var v2; id } when equal_row_var v v2 -> { dims = more_dims @ dims; bcast; id }
  | _ -> in_

let row_of_var v id = { dims = []; bcast = Row_var v; id }

let s_row_one_in_entry v ~value in_ =
  match in_ with
  | Solved in_ -> ([], Solved (s_row_one v ~value ~in_))
  | Bounds { cur; subr; lub } ->
      (* TODO: audit code to ensure we don't lose the constraints associated with the bounds variables. *)
      let find_v side = List.partition_tf side ~f:(equal_row_var v) in
      let v_cur, cur = find_v cur in
      let v_subr, subr = find_v subr in
      let ineqs0 =
        match (v_subr, lub) with _ :: _, Some lub -> [ Row_ineq { cur = lub; subr = value } ] | _ -> []
      in
      let ineqs1 =
        if List.is_empty v_subr then []
        else List.map cur ~f:(fun cur -> Row_ineq { cur = row_of_var cur value.id; subr = value })
      in
      let ineqs2 =
        if List.is_empty v_cur then []
        else List.map subr ~f:(fun subr -> Row_ineq { subr = row_of_var subr value.id; cur = value })
      in
      ( ineqs0 @ ineqs1 @ ineqs2,
        Bounds { cur; subr; lub = Option.map lub ~f:(fun in_ -> s_row_one v ~value ~in_) } )

let rec subst_row (env : environment) ({ dims; bcast; id } : t) : t =
  let s_dims = List.map ~f:(subst_dim env) in
  let dims = s_dims dims in
  let default = { dims; bcast; id } in
  match bcast with
  | Broadcastable -> { dims; bcast; id }
  | Row_var v -> (
      match Map.find env.row_env v with
      | None | Some (Bounds _) -> default
      | Some (Solved { dims = []; bcast = Row_var v2; _ }) when equal_row_var v v2 -> default
      | Some (Solved ({ bcast = Row_var v2; _ } as r2)) when equal_row_var v v2 ->
          raise @@ Shape_error ("Infinite number of axes by self-reference", [ Row_mismatch [ default; r2 ] ])
      | Some (Solved { dims = more_dims; bcast; id = _ }) ->
          subst_row env { dims = s_dims more_dims @ dims; bcast; id })

let rec unify_dim (eq : dim * dim) (env : environment) : inequality list * environment =
  let dim1 : dim = subst_dim env @@ fst eq and dim2 : dim = subst_dim env @@ snd eq in
  match (dim1, dim2) with
  | Dim { label = Some l1; _ }, Dim { label = Some l2; _ } when not (String.equal l1 l2) ->
      raise @@ Shape_error ("solved dimensions for axis: different labels", [ Dim_mismatch [ dim1; dim2 ] ])
  | Dim { d = d1; _ }, Dim { d = d2; _ } when d1 = d2 -> ([], env)
  | Var v1, Var v2 when equal_dim_var v1 v2 -> ([], env)
  | Var v, dim2 | dim2, Var v ->
      let ineqs = ref [] in
      let f in_ =
        let more_ineqs, result = s_dim_one_in_entry v ~value:dim2 in_ in
        ineqs := more_ineqs @ !ineqs;
        result
      in
      let env =
        match Map.find env.dim_env v with
        | None ->
            let dim_env = Map.map env.dim_env ~f in
            {
              dim_env = Map.add_exn dim_env ~key:v ~data:(Solved dim2);
              row_env = Map.map env.row_env ~f:(s_dim_one_in_row_entry v ~value:dim2);
            }
        | Some (Solved _) -> assert false
        | Some (Bounds { cur; subr; lub }) ->
            let dim_env = Map.map env.dim_env ~f in
            List.iter cur ~f:(fun cur -> ineqs := Dim_ineq { cur = Var cur; subr = dim2 } :: !ineqs);
            List.iter subr ~f:(fun subr -> ineqs := Dim_ineq { subr = Var subr; cur = dim2 } :: !ineqs);
            Option.iter lub ~f:(fun lub -> ineqs := Dim_ineq { cur = lub; subr = dim2 } :: !ineqs);
            {
              dim_env = Map.update dim_env v ~f:(fun _ -> Solved dim2);
              row_env = Map.map env.row_env ~f:(s_dim_one_in_row_entry v ~value:dim2);
            }
      in
      let dim_eqs, ineqs =
        List.partition_map !ineqs ~f:(function Dim_eq { d1; d2 } -> First (d1, d2) | ineq -> Second ineq)
      in
      let f (ineqs, env) ds =
        let more_ineqs, env = unify_dim ds env in
        (more_ineqs @ ineqs, env)
      in
      List.fold ~init:(ineqs, env) dim_eqs ~f
  | dim1, dim2 ->
      (* Note: at the unify_dim stage, it's strict equality (no broadcasting). *)
      raise @@ Shape_error ("solved dimensions for axis: mismatch", [ Dim_mismatch [ dim1; dim2 ] ])

let drop_from_end l n = List.rev @@ List.drop (List.rev l) n
let take_from_end (l : dim list) (n : int) : dim list = List.rev @@ List.take (List.rev l) n

module Debug_runtime = Utils.Debug_runtime

[%%global_debug_log_level_from_env_var "OCANNL_LOG_LEVEL"]

let apply_constraint ~finish r constr env =
  match constr with
  | Unconstrained -> ([], env)
  | Total_elems n -> (
      match r with
      | { dims; bcast = Row_var _; _ } when finish -> (
          let vars, nonvars = List.partition_tf dims ~f:is_var in
          let known = List.fold nonvars ~init:1 ~f:(fun n d -> n * dim_to_int_exn d) in
          let rem = n / known in
          if rem = 0 then raise @@ Shape_error ("Total_elems constraint failed", [ Row_mismatch [ r ] ])
          else if rem = 1 then ([], env)
          else
            match vars with
            | [] ->
                let dim = get_dim ~d:rem () in
                ([ Row_eq { r1 = r; r2 = { dims = [ dim ]; bcast = Broadcastable; id = r.id } } ], env)
            | Var v :: _ -> ([ Dim_eq { d1 = Var v; d2 = get_dim ~d:rem () } ], env)
            | Dim _ :: _ -> assert false)
      | { bcast = Row_var _; _ } -> ([ Row_constr { r; constr } ], env (* Wait for more shape inference. *))
      | { dims; bcast = Broadcastable; _ } -> (
          let vars, nonvars = List.partition_tf dims ~f:is_var in
          let known = List.fold nonvars ~init:1 ~f:(fun n d -> n * dim_to_int_exn d) in
          let rem = n / known in
          if rem = 0 then raise @@ Shape_error ("Total_elems constraint failed", [ Row_mismatch [ r ] ])
          else
            match vars with
            | [] ->
                if rem = 1 then ([], env)
                else raise @@ Shape_error ("Total_elems constraint failed", [ Row_mismatch [ r ] ])
            | [ Var v ] -> ([ Dim_eq { d1 = Var v; d2 = get_dim ~d:rem () } ], env)
            | Var v :: _ when finish -> ([ Dim_eq { d1 = Var v; d2 = get_dim ~d:rem () } ], env)
            | Var _ :: _ -> ([ Row_constr { r; constr } ], env (* Wait for more shape inference. *))
            | Dim _ :: _ -> assert false))

(* Equate two rows, no broadcasting. Does not resolve inequalities. *)
let rec unify_row (eq : t * t) (env : environment) : inequality list * environment =
  let rec solve (ineqs, env) = function
    | Dim_eq { d1; d2 } ->
        let more_ineqs, env = unify_dim (d1, d2) env in
        List.fold ~init:(ineqs, env) more_ineqs ~f:solve
    | Row_eq { r1; r2 } ->
        let more_ineqs, env = unify_row (r1, r2) env in
        (more_ineqs @ ineqs, env)
    | (Dim_ineq _ | Row_ineq _ | Row_constr _ | Terminal_dim _ | Terminal_row _) as ineq ->
        (ineq :: ineqs, env)
  in
  let unify_prefix dims1 dims2 len =
    let dims1 = take_from_end dims1 len and dims2 = take_from_end dims2 len in
    List.fold ~init:([], env) ~f:(fun acc (d1, d2) -> solve acc (Dim_eq { d1; d2 }))
    @@ List.zip_exn dims1 dims2
  in
  let r1 : t = subst_row env @@ fst eq and r2 : t = subst_row env @@ snd eq in
  match (r1, r2) with
  | r1, r2 when equal_row r1 r2 -> ([], env)
  | { bcast = Row_var v1; dims = r1_dims; id = _ }, { bcast = Row_var v2; dims = r2_dims; id = _ }
    when equal_row_var v1 v2 ->
      let r1_len = List.length r1_dims and r2_len = List.length r2.dims in
      if r1_len = r2_len then unify_prefix r1_dims r2_dims r1_len
      else raise @@ Shape_error ("Infinite number of axes by self-reference", [ Row_mismatch [ r1; r2 ] ])
  | ({ bcast = Row_var v; dims = r1_dims; id } as r1), r2
  | r2, ({ bcast = Row_var v; dims = r1_dims; id } as r1) -> (
      let r1_len : int = List.length r1_dims and r2_len : int = List.length r2.dims in
      if r1_len > r2_len then
        if is_row_var r2.bcast then unify_row (r2, r1) env
        else raise @@ Shape_error ("Number of axes mismatch", [ Row_mismatch [ r1; r2 ] ])
      else
        let ineqs, env =
          try unify_prefix r1_dims r2.dims r1_len
          with Shape_error (s, trace) -> raise @@ Shape_error (s, Row_mismatch [ r1; r2 ] :: trace)
        in
        let occurs_check_error =
          Shape_error ("Infinite number of axes by self-reference", [ Row_mismatch [ r1; r2 ] ])
        in
        let value : row = { bcast = r2.bcast; dims = drop_from_end r2.dims r1_len; id } in
        (* From now on, we have no use for un-reduced r2 since we deal with the row variable. *)
        let r2 = value in
        let ineqs : inequality list ref = ref ineqs in
        let f in_ =
          let more_ineqs, result = s_row_one_in_entry v ~value in_ in
          ineqs := more_ineqs @ !ineqs;
          result
        in
        match Map.find env.row_env v with
        | None ->
            let row_env = Map.map env.row_env ~f in
            let env : environment =
              match r2.bcast with
              | Row_var v2 when equal_row_var v v2 ->
                  if List.is_empty value.dims then env else raise occurs_check_error
              | _ -> { env with row_env = Map.add_exn row_env ~key:v ~data:(Solved value) }
            in
            List.fold ~init:([], env) ~f:solve !ineqs
        | Some (Solved _) -> assert false
        | Some (Bounds { cur; subr; lub }) ->
            (* TODO: audit code to ensure we don't lose the constraints associated with the bounds variables. *)
            let row_env : row_env = Map.map env.row_env ~f in
            List.iter cur ~f:(fun cur ->
                ineqs := Row_ineq { cur = row_of_var cur value.id; subr = r2 } :: !ineqs);
            List.iter subr ~f:(fun subr ->
                ineqs := Row_ineq { subr = row_of_var subr value.id; cur = r2 } :: !ineqs);
            Option.iter lub ~f:(fun lub -> ineqs := Row_ineq { cur = lub; subr = r2 } :: !ineqs);
            let _debug_ineqs : inequality list = !ineqs in
            let env : environment = { env with row_env = Map.update row_env v ~f:(fun _ -> Solved value) } in
            List.fold ~init:([], env) ~f:solve !ineqs)
  | ( ({ bcast = Broadcastable; dims = dims1; id = _ } as r1),
      ({ bcast = Broadcastable; dims = dims2; id = _ } as r2) ) -> (
      match List.zip dims1 dims2 with
      | Unequal_lengths -> raise @@ Shape_error ("Mismatching number of axes", [ Row_mismatch [ r1; r2 ] ])
      | Ok eqs -> List.fold ~init:([], env) ~f:(fun acc (d1, d2) -> solve acc (Dim_eq { d1; d2 })) eqs)

let solve_dim_ineq ~(finish : bool) ~(cur : dim) ~(subr : dim) (env : environment) :
    inequality list * environment =
  let nonredundant ?(more = []) v vs =
    Utils.sorted_diff ~compare:compare_dim_var (List.dedup_and_sort ~compare:compare_dim_var (v :: vs)) more
  in
  match (cur, subr) with
  | cur, subr when equal_dim cur subr -> ([], env)
  | Dim { label = Some l1; _ }, Dim { label = Some l2; _ } when not (String.equal l1 l2) ->
      raise @@ Shape_error ("dimension comparison for axis: different labels", [ Dim_mismatch [ cur; subr ] ])
  | Dim { d = d1; _ }, Dim { d = d2; _ } when d1 = d2 -> ([], env)
  | _, Dim { d = 1; _ } -> ([], env)
  | (Dim { d = 1; _ } as cur), _ -> ([ Dim_eq { d1 = subr; d2 = cur } ], env)
  | Var v_cur, Var v_subr -> (
      match (Map.find env.dim_env v_cur, Map.find env.dim_env v_subr) with
      | Some (Bounds { cur = cur1; _ }), _ when List.mem ~equal:equal_dim_var cur1 v_subr ->
          ([ Dim_eq { d1 = cur; d2 = subr } ], env)
      | _, Some (Bounds { subr = subr2; _ }) when List.mem ~equal:equal_dim_var subr2 v_cur ->
          ([ Dim_eq { d1 = cur; d2 = subr } ], env)
      | Some (Bounds { subr = subr1; _ }), _ when List.mem ~equal:equal_dim_var subr1 v_subr -> ([], env)
      | _, Some (Bounds { cur = cur2; _ }) when List.mem ~equal:equal_dim_var cur2 v_cur -> ([], env)
      | None, None ->
          ( [],
            {
              env with
              dim_env =
                env.dim_env
                |> Map.add_exn ~key:v_cur ~data:(Bounds { lub = None; cur = []; subr = [ v_subr ] })
                |> Map.add_exn ~key:v_subr ~data:(Bounds { lub = None; cur = [ v_cur ]; subr = [] });
            } )
      | Some (Solved _), _ | _, Some (Solved _) -> assert false
      | Some (Bounds { cur = cur1; subr = subr1; lub = lub1 }), None ->
          ( Option.to_list lub1 |> List.map ~f:(fun cur -> Dim_ineq { cur; subr }),
            {
              env with
              dim_env =
                env.dim_env
                |> Fn.flip Map.update v_cur ~f:(fun _ ->
                       Bounds { lub = lub1; cur = cur1; subr = nonredundant v_subr subr1 })
                |> Map.add_exn ~key:v_subr ~data:(Bounds { lub = None; cur = [ v_cur ]; subr = [] });
            } )
      | ( Some (Bounds { cur = _; subr = [ subr1 ]; lub = None }),
          Some (Bounds { cur = [ cur2 ]; subr = _; lub = None }) )
        when finish && equal_dim_var v_subr subr1 && equal_dim_var v_cur cur2 ->
          ([ Dim_eq { d1 = subr; d2 = cur } ], env)
      | None, Some (Bounds { cur = cur2; subr = subr2; lub = lub2 }) ->
          ( [],
            {
              env with
              dim_env =
                env.dim_env
                |> Map.add_exn ~key:v_cur ~data:(Bounds { lub = None; cur = []; subr = [ v_subr ] })
                |> Fn.flip Map.update v_subr ~f:(fun _ ->
                       Bounds { lub = lub2; cur = nonredundant v_cur cur2; subr = subr2 });
            } )
      | ( Some (Bounds { cur = cur1; subr = subr1; lub = lub1 }),
          Some (Bounds { cur = cur2; subr = subr2; lub = lub2 }) ) ->
          ( Option.to_list lub1 |> List.map ~f:(fun cur -> Dim_ineq { cur; subr }),
            {
              env with
              dim_env =
                env.dim_env
                |> Fn.flip Map.update v_cur ~f:(fun _ ->
                       Bounds { lub = lub1; cur = cur1; subr = nonredundant ~more:subr2 v_subr subr1 })
                |> Fn.flip Map.update v_subr ~f:(fun _ ->
                       Bounds { lub = lub2; cur = nonredundant ~more:cur1 v_cur cur2; subr = subr2 });
            } ))
  | _, Var v_subr -> (
      match Map.find env.dim_env v_subr with
      | None ->
          ( [],
            {
              env with
              dim_env =
                Map.add_exn env.dim_env ~key:v_subr ~data:(Bounds { lub = Some cur; cur = []; subr = [] });
            } )
      | Some (Solved _) -> assert false
      | Some (Bounds { cur = cur2; subr = subr2; lub = Some lub2 }) ->
          let lub, lub_forcing =
            match (cur, lub2) with
            | Dim { d = d1; _ }, Dim { d = d2; _ } when d1 = d2 -> (cur, [])
            | Dim _, Dim _ (* when d1 <> d2 *) ->
                let lub = get_dim ~d:1 () in
                (lub, [ Dim_eq { d1 = subr; d2 = lub } ])
                (* raise
                   @@ Shape_error
                        ( "dimension comparison for axis: upper bound mismatch",
                          [ Dim_mismatch [ lub2; cur; subr ] ] ) *)
            | Var _, _ | _, Var _ -> assert false
          in
          ( lub_forcing,
            {
              env with
              dim_env =
                Map.update env.dim_env v_subr ~f:(fun _ ->
                    Bounds { lub = Some lub; cur = cur2; subr = subr2 });
            } )
      | Some (Bounds { cur = cur2; subr = subr2; lub = None }) ->
          ( List.map subr2 ~f:(fun v_subr -> Dim_ineq { cur; subr = Var v_subr }),
            {
              env with
              dim_env =
                Map.update env.dim_env v_subr ~f:(fun _ ->
                    Bounds { lub = Some cur; cur = cur2; subr = subr2 });
            } ))
  | Var _, Dim _ (* when d2 > 1 *) -> ([ Dim_eq { d1 = cur; d2 = subr } ], env)
  | Dim _, Dim _ ->
      raise @@ Shape_error ("dimension comparison for axis: mismatch", [ Dim_mismatch [ cur; subr ] ])

let global_template_cache = Hashtbl.Poly.create ()

let solve_row_ineq ~(finish : bool) ~(cur : t) ~(subr : t) (env : environment) : inequality list * environment
    =
  let nonredundant ?(more = []) v vs =
    Utils.sorted_diff ~compare:compare_row_var (List.dedup_and_sort ~compare:compare_row_var (v :: vs)) more
  in
  let r1_len = List.length cur.dims and r2_len = List.length subr.dims in
  let len = min r1_len r2_len in
  let prefix_ineqs =
    List.map2_exn
      ~f:(fun cur subr -> Dim_ineq { cur; subr })
      (take_from_end cur.dims len) (take_from_end subr.dims len)
  in
  let reduced { bcast; dims; id } = { bcast; dims = drop_from_end dims len; id } in
  match (cur, subr) with
  | cur, subr when equal_row cur subr -> ([], env)
  | { bcast = Row_var v_cur; _ }, { bcast = Row_var v_subr; _ }
    when r1_len = r2_len && equal_row_var v_cur v_subr ->
      (prefix_ineqs, env)
  | { bcast = Row_var v_cur; _ }, { bcast = Row_var v_subr; _ } when r1_len = r2_len -> (
      match (Map.find env.row_env v_cur, Map.find env.row_env v_subr) with
      | Some (Bounds { cur = cur1; _ }), _ when List.mem ~equal:equal_row_var cur1 v_subr ->
          (Row_eq { r1 = row_of_var v_subr subr.id; r2 = row_of_var v_cur cur.id } :: prefix_ineqs, env)
      | _, Some (Bounds { subr = subr2; _ }) when List.mem ~equal:equal_row_var subr2 v_cur ->
          (Row_eq { r1 = row_of_var v_subr subr.id; r2 = row_of_var v_cur cur.id } :: prefix_ineqs, env)
      | Some (Bounds { subr = [ subr1 ]; _ }), Some (Bounds { cur = [ cur2 ]; _ })
        when finish && equal_row_var subr1 v_subr && equal_row_var cur2 v_cur ->
          (Row_eq { r1 = row_of_var v_subr subr.id; r2 = row_of_var v_cur cur.id } :: prefix_ineqs, env)
      | Some (Bounds { subr = subr1; _ }), _ when List.mem ~equal:equal_row_var subr1 v_subr ->
          (prefix_ineqs, env)
      | _, Some (Bounds { cur = cur2; _ }) when List.mem ~equal:equal_row_var cur2 v_cur -> (prefix_ineqs, env)
      | None, None ->
          ( prefix_ineqs,
            {
              env with
              row_env =
                env.row_env
                |> Map.add_exn ~key:v_cur ~data:(Bounds { cur = []; subr = [ v_subr ]; lub = None })
                |> Map.add_exn ~key:v_subr ~data:(Bounds { cur = [ v_cur ]; subr = []; lub = None });
            } )
      | Some (Bounds { cur = cur1; subr = subr1; lub = lub1 }), None ->
          ( prefix_ineqs,
            {
              env with
              row_env =
                env.row_env
                |> Fn.flip Map.update v_cur ~f:(fun _ ->
                       Bounds { cur = cur1; subr = nonredundant v_subr subr1; lub = lub1 })
                |> Map.add_exn ~key:v_subr ~data:(Bounds { cur = [ v_cur ]; subr = []; lub = None });
            } )
      | None, Some (Bounds { cur = cur2; subr = subr2; lub = lub2 }) ->
          ( prefix_ineqs,
            {
              env with
              row_env =
                env.row_env
                |> Fn.flip Map.update v_subr ~f:(fun _ ->
                       Bounds { cur = nonredundant v_cur cur2; subr = subr2; lub = lub2 })
                |> Map.add_exn ~key:v_cur ~data:(Bounds { cur = []; subr = [ v_subr ]; lub = None });
            } )
      | ( Some (Bounds { cur = cur1; subr = subr1; lub = lub1 }),
          Some (Bounds { cur = cur2; subr = subr2; lub = lub2 }) ) ->
          ( prefix_ineqs,
            {
              env with
              row_env =
                env.row_env
                |> Fn.flip Map.update v_cur ~f:(fun _ ->
                       Bounds { cur = cur1; subr = nonredundant v_subr subr1; lub = lub1 })
                |> Fn.flip Map.update v_subr ~f:(fun _ ->
                       Bounds { cur = nonredundant v_cur cur2; subr = subr2; lub = lub2 });
            } )
      | Some (Solved _), _ | _, Some (Solved _) -> assert false)
  | { bcast = Row_var v_cur; dims; _ }, _ when r1_len < r2_len ->
      let more_dims : dim list = Array.(to_list @@ init (r2_len - r1_len) ~f:(fun _ -> Var (get_var ()))) in
      (* The key of the template cache reflects that v_cur will end up substituted by
         {dims=more_dims; bcast=Row_var templ_v}.
         TODO: should we cache more_dims also? *)
      let templ_v : row_var =
        Hashtbl.find_or_add global_template_cache (v_cur, r2_len - r1_len) ~default:get_row_var
      in
      let template : t = { dims = more_dims @ dims; bcast = Row_var templ_v; id = cur.id } in
      (* FIXME: We shouldn't need to add any dimension inequalities, because they'll be captured by
         the extra row inequalities! *)
      let subr_dims : dim list = List.take subr.dims (r2_len - r1_len) in
      ( Row_eq { r1 = cur; r2 = template }
        :: Row_ineq { cur = template; subr }
        :: List.map2_exn more_dims subr_dims ~f:(fun cur subr -> Dim_ineq { cur; subr })
        @ prefix_ineqs,
        env )
  | { bcast = Broadcastable; _ }, _ when r1_len < r2_len ->
      raise @@ Shape_error ("Too many axes", [ Row_mismatch [ cur; subr ] ])
  | _, { bcast = Row_var v_subr; _ } when r2_len <= r1_len -> (
      let r_cur = reduced cur in
      match Map.find env.row_env v_subr with
      | None ->
          ( prefix_ineqs,
            {
              env with
              row_env =
                Map.add_exn env.row_env ~key:v_subr ~data:(Bounds { cur = []; subr = []; lub = Some r_cur });
            } )
      | Some (Bounds { cur = cur2; subr = subr2; lub = None }) ->
          ( prefix_ineqs,
            {
              env with
              row_env =
                env.row_env
                |> Fn.flip Map.update v_subr ~f:(fun _ ->
                       Bounds { cur = cur2; subr = subr2; lub = Some r_cur });
            } )
      | Some (Bounds { cur = cur2; subr = subr2; lub = Some lub2 }) ->
          let len1 = List.length r_cur.dims and len2 = List.length lub2.dims in
          let lub_len = min len1 len2 in
          let lub_is_cur = len1 < len2 || (len1 = len2 && is_broadcastable cur.bcast) in
          let lub_id = if lub_is_cur then r_cur.id else lub2.id in
          (* TODO: we lose connection here with the other bound if both have row variables. *)
          let lub_bcast = if lub_is_cur then r_cur.bcast else lub2.bcast in
          let lub_dims =
            List.map2_exn (take_from_end r_cur.dims lub_len) (take_from_end lub2.dims lub_len)
              ~f:(fun d1 d2 ->
                match (d1, d2) with
                | Dim { d = 1; _ }, _ -> d1
                | _, Dim { d = 1; _ } -> d2
                | Dim { d = d1; _ }, Dim { d = d2; _ } when d1 <> d2 -> get_dim ~d:1 ()
                | Var _, _ -> d1
                | _, Var _ -> d2
                | Dim _, Dim _ -> d1)
          in
          let lub = { dims = lub_dims; bcast = lub_bcast; id = lub_id } in
          let force_lub =
            if finish && (not @@ is_row_var lub_bcast) then
              [ Row_eq { r1 = row_of_var v_subr subr.id; r2 = lub } ]
            else []
          in
          ( prefix_ineqs @ force_lub,
            {
              env with
              row_env =
                env.row_env
                |> Fn.flip Map.update v_subr ~f:(fun _ -> Bounds { cur = cur2; subr = subr2; lub = Some lub });
            } )
      | Some (Solved _) -> assert false)
  | _, { bcast = Broadcastable; _ } when r2_len <= r1_len -> (prefix_ineqs, env)
  | { bcast = Row_var _ | Broadcastable; _ }, { bcast = Row_var _ | Broadcastable; _ } -> assert false

let close_dim_terminal (env : environment) (dim : dim) : inequality list * environment =
  match dim with
  | Dim _ -> ([], env)
  | Var v -> (
      match Map.find env.dim_env v with
      | Some (Solved _) -> assert false
      | None | Some (Bounds { lub = None; _ }) -> (* needs more inference *) ([ Terminal_dim dim ], env)
      | Some (Bounds { lub = Some lub; _ }) -> ([ Dim_eq { d1 = dim; d2 = lub } ], env))

let close_row_terminal (env : environment) ({ dims; bcast; id } as _r : row) : inequality list * environment =
  let prefix = List.map dims ~f:(fun d -> Terminal_dim d) in
  match bcast with
  | Broadcastable -> (prefix, env)
  | Row_var v -> (
      let rem : row = row_of_var v id in
      match Map.find env.row_env v with
      | Some (Bounds { lub = None; _ }) | None -> (* needs more inference *) (Terminal_row rem :: prefix, env)
      | Some (Solved _) -> assert false
      | Some (Bounds { lub = Some lub; _ }) -> (Row_eq { r1 = row_of_var v id; r2 = lub } :: prefix, env))

let finalize_dim (env : environment) (dim : dim) : inequality list =
  match subst_dim env dim with Dim _ -> [] | Var _ -> [ Dim_eq { d1 = dim; d2 = get_dim ~d:1 () } ]

let finalize_row (env : environment) (r : row) : inequality list =
  let { dims; bcast; id } = subst_row env r in
  let prefix = List.concat_map dims ~f:(finalize_dim env) in
  match bcast with
  | Broadcastable -> prefix
  | Row_var v -> Row_eq { r1 = row_of_var v id; r2 = { dims = []; bcast = Broadcastable; id } } :: prefix

let empty_env = { dim_env = Map.empty (module Dim_var); row_env = Map.empty (module Row_var) }

let solve_inequalities ~(finish : bool) (ineqs : inequality list) (env : environment) :
    inequality list * environment =
  let rec solve (ineqs : inequality list) (env : environment) : inequality list * environment =
    let f (ineqs, env) = function
      | Dim_eq { d1; d2 } ->
          (* Substituted inside unify_dim. *)
          let more_ineqs, env = unify_dim (d1, d2) env in
          (more_ineqs @ ineqs, env)
      | Row_eq { r1; r2 } ->
          (* Substituted inside unify_row. *)
          let more_ineqs, env = unify_row (r1, r2) env in
          (more_ineqs @ ineqs, env)
      | Dim_ineq { cur; subr } ->
          let cur = subst_dim env cur and subr = subst_dim env subr in
          let more_ineqs, env = solve_dim_ineq ~finish ~cur ~subr env in
          (more_ineqs @ ineqs, env)
      | Row_ineq { cur; subr } ->
          let cur = subst_row env cur and subr = subst_row env subr in
          let more_ineqs, env = solve_row_ineq ~finish ~cur ~subr env in
          (more_ineqs @ ineqs, env)
      | Row_constr { r; constr } ->
          let r = subst_row env r in
          let more_ineqs, env = apply_constraint ~finish r constr env in
          (more_ineqs @ ineqs, env)
      | Terminal_dim d when finish ->
          let more_ineqs, env = close_dim_terminal env @@ subst_dim env d in
          (more_ineqs @ ineqs, env)
      | Terminal_row r when finish ->
          let more_ineqs, env = close_row_terminal env @@ subst_row env r in
          (more_ineqs @ ineqs, env)
      | Terminal_dim _ (* when not finish *) -> (ineqs, env)
      | Terminal_row _ (* when not finish *) -> (ineqs, env)
    in
    let ineqs', env = List.fold ineqs ~init:([], env) ~f in
    let ineqs' = List.rev ineqs' in
    let all_constr = List.for_all ~f:(fun b -> is_row_constr b || is_terminal_row b || is_terminal_dim b) in
    if
      List.is_empty ineqs'
      || (all_constr ineqs' && all_constr ineqs && List.length ineqs' >= List.length ineqs)
    then (ineqs', env)
    else solve ineqs' env
  in
  solve ineqs env

let rec row_to_labels env =
  let rec f = function
    | Dim { label = Some l; _ } -> l
    | Dim { label = None; _ } -> ""
    | Var v -> (
        match Map.find env.dim_env v with
        | None | Some (Bounds _) -> Option.value v.label ~default:""
        | Some (Solved dim) -> f dim)
  in
  function
  | { dims; bcast = Row_var v; id } -> (
      match Map.find env.row_env v with
      | None | Some (Bounds _) -> Array.of_list_map dims ~f
      | Some (Solved row2) -> row_to_labels env { dims = row2.dims @ dims; bcast = row2.bcast; id })
  | { dims; bcast = Broadcastable; id = _ } -> Array.of_list_map dims ~f

(** *** Projection inference *** *)

let fresh_proj =
  let uid = ref 0 in
  fun () ->
    Int.incr uid;
    !uid

let fresh_row_proj r =
  let fresh_dim = function
    | Dim { d; label; proj_id = _ } -> Dim { d; label; proj_id = Some (fresh_proj ()) }
    | Var _ as d -> d
  in
  { r with dims = List.map r.dims ~f:fresh_dim }

(* let update_proj_classes pid1 pid2 proj_classes = Utils.union_add ~equal:Int.equal proj_classes pid1 pid2 *)

type proj = Var of dim_var | Proj of { proj_id : int; d : int } | Solved of Idx.axis_index
[@@deriving compare, equal, sexp]

type error_trace += Projection_mismatch of proj list

let sexp_of_error_trace = function
  | Projection_mismatch ps -> Sexp.List (Sexp.Atom "Projection_mismatch" :: List.map ps ~f:sexp_of_proj)
  | error_trace -> sexp_of_error_trace error_trace

type proj_to_index = Idx.axis_index Map.M(Int).t [@@deriving sexp]
type proj_classes = int Map.M(Int).t [@@deriving sexp]

type proj_env = {
  proj_to_index : proj_to_index;
  proj_classes : proj_classes;
  product_dim : int Map.M(Int).t;
  non_product : Set.M(Int).t;
}
[@@deriving sexp]

type proj_equation =
  | Proj_eq of proj * proj  (** Two projections are the same, e.g. two axes share the same iterator. *)
  | Iterated of proj
      (** The projection needs to be an iterator even if an axis is not matched with another axis,
          e.g. for broadcasted-to axes of a tensor assigned a constant. *)
[@@deriving compare, equal, sexp]

let get_proj_equations (inequalities : inequality list) proj_axis_env (env : environment) : proj_equation list
    =
  let to_proj : dim -> proj = function
    | Var v when Map.mem proj_axis_env v -> Solved (Map.find_exn proj_axis_env v)
    | Dim { proj_id = Some proj_id; d; label = _ } -> Proj { proj_id; d }
    | d -> (
        match subst_dim env d with
        | Dim { proj_id = Some proj_id; d; label = _ } -> Proj { proj_id; d }
        | Dim { proj_id = None; d; _ } -> Proj { proj_id = fresh_proj (); d }
        | Var v when Map.mem proj_axis_env v -> Solved (Map.find_exn proj_axis_env v)
        | Var v -> Var v)
  in
  let rec expand_dims = function
    | { dims; bcast = Row_var v; _ } when Map.mem env.row_env v -> (
        match Map.find_exn env.row_env v with
        | Solved r ->
            let more_dims = expand_dims r in
            more_dims @ dims
        | _ -> dims)
    | { dims; _ } -> dims
  in
  let match_rows with_broadcasting r1 r2 =
    let dims1 = expand_dims r1 and dims2 = expand_dims r2 in
    let len1 = List.length dims1 in
    let len = min len1 (List.length dims2) in
    let extras =
      if with_broadcasting then List.map ~f:(fun d -> Iterated (to_proj d)) @@ List.take dims1 (len1 - len)
      else []
    in
    extras
    @ (List.zip_exn (take_from_end dims1 len) (take_from_end dims2 len)
      |> List.map ~f:(fun (d1, d2) -> Proj_eq (to_proj d1, to_proj d2)))
  in
  let f = function
    | Dim_ineq { cur = _; subr = Dim { d = 1; proj_id = Some proj_id; _ } } ->
        [ Proj_eq (Proj { proj_id; d = 1 }, Solved (Fixed_idx 0)) ]
    | Dim_eq { d1; d2 } | Dim_ineq { cur = d1; subr = d2 } -> [ Proj_eq (to_proj d1, to_proj d2) ]
    | Row_eq { r1; r2 } -> match_rows false r1 r2
    | Row_ineq { cur = r1; subr = r2 } ->
        match_rows true r1 r2
        |> List.concat_map ~f:(function
             | Proj_eq (proj1, (Proj { proj_id = _; d = 1 } as proj2)) ->
                 [ Iterated proj1; Proj_eq (proj2, Solved (Fixed_idx 0)) ]
             | eq -> [ eq ])
    | Row_constr _ | Terminal_dim _ | Terminal_row _ -> []
  in
  List.concat_map inequalities ~f

let solve_proj_equations (eqs : proj_equation list) : proj_env =
  let v_env = dim_hashtbl () in
  let p_solved = ref [] in
  let p_dims = ref [] in
  let proj_classes = ref @@ Map.empty (module Int) in
  let rec loop = function
    | Proj_eq (Proj { proj_id = p1; d }, Proj { proj_id = p2; _ }) when p1 = p2 ->
        p_dims := (p1, d) :: !p_dims
    | Proj_eq (Var v1, Var v2) when equal_dim_var v1 v2 -> ()
    | Proj_eq ((Proj { proj_id = p1; d = d1 } as proj1), (Proj { proj_id = p2; d = d2 } as proj2)) ->
        if d1 <> d2 then
          raise
          @@ Shape_error
               ("Conflicting dimensions for the same projection", [ Projection_mismatch [ proj1; proj2 ] ]);
        p_dims := (p1, d1) :: !p_dims;
        proj_classes := Utils.union_add ~equal:Int.equal !proj_classes p1 p2
    | Proj_eq (Proj p, Solved idx) | Proj_eq (Solved idx, Proj p) -> p_solved := (p.proj_id, idx) :: !p_solved
    | Proj_eq (Solved idx1, Solved idx2) when Idx.equal_axis_index idx1 idx2 -> ()
    | Proj_eq (Solved idx1, Solved idx2) ->
        raise
        @@ Shape_error ("Conflicting indices for the same axis/projection", [ Index_mismatch [ idx1; idx2 ] ])
    | Proj_eq (Var v, p) | Proj_eq (p, Var v) -> (
        match Hashtbl.find v_env v with
        | None -> Hashtbl.add_exn v_env ~key:v ~data:p
        | Some p2 -> loop (Proj_eq (p, p2)))
    | Iterated (Solved _) -> ()
    | Iterated (Proj { proj_id; d }) -> p_dims := (proj_id, d) :: !p_dims
    | Iterated (Var v) -> (
        match Hashtbl.find v_env v with
        | None ->
            let idx = Idx.(Iterator (get_symbol ())) in
            Hashtbl.add_exn v_env ~key:v ~data:(Solved idx)
        | Some (Var v2) -> loop (Iterated (Var v2))
        | Some (Solved _) -> ()
        | Some (Proj { proj_id; d }) -> p_dims := (proj_id, d) :: !p_dims)
  in
  List.iter eqs ~f:loop;
  let projs = ref @@ Map.empty (module Int) and non_product = ref @@ Set.empty (module Int) in
  List.iter !p_solved ~f:(fun (p, idx) ->
      let repr, _ = Utils.union_find ~equal:Int.equal !proj_classes ~key:p ~rank:0 in
      non_product := Set.add !non_product repr;
      Utils.mref_add projs ~key:repr ~data:idx ~or_:(fun idx2 ->
          if not @@ Idx.equal_axis_index idx idx2 then
            raise
            @@ Shape_error ("Multiple constraints on the same projection", [ Index_mismatch [ idx; idx2 ] ])));
  let product_dim = ref @@ Map.empty (module Int) in
  List.iter !p_dims ~f:(fun (p, d) ->
      let repr, _ = Utils.union_find ~equal:Int.equal !proj_classes ~key:p ~rank:0 in
      if Idx.iterated d && (not @@ Map.mem !projs repr) then
        Utils.mref_add product_dim ~key:repr ~data:d ~or_:(fun d2 ->
            if d <> d2 then
              raise
              @@ Shape_error
                   ( "Conflicting dimensions for the same projection",
                     [ Projection_mismatch [ Proj { proj_id = p; d }; Proj { proj_id = p; d = d2 } ] ] )));
  Map.iteri !product_dim ~f:(fun ~key:p ~data:_ ->
      let repr, _ = Utils.union_find ~equal:Int.equal !proj_classes ~key:p ~rank:0 in
      Utils.mref_add_missing projs repr ~f:(fun () -> Idx.(Iterator (get_symbol ()))));
  {
    proj_classes = !proj_classes;
    proj_to_index = !projs;
    product_dim = !product_dim;
    non_product = !non_product;
  }

let get_proj_index proj_env = function
  | Dim { d; _ } when not @@ Idx.iterated d -> Idx.Fixed_idx 0
  | Dim { proj_id = None; _ } -> assert false
  | Var v as dim ->
      raise
      @@ Shape_error
           ( "projection_of_solved_dims: still not fully inferred for variable "
             ^ Sexp.to_string_hum ([%sexp_of: dim_var] v),
             [ Dim_mismatch [ dim ] ] )
  | Dim { proj_id = Some proj_id; d; _ } -> (
      let repr, _ = Utils.union_find ~equal:Int.equal proj_env.proj_classes ~key:proj_id ~rank:0 in
      match Map.find proj_env.proj_to_index repr with
      | Some i -> i
      | None ->
          raise
          @@ Shape_error
               ( "projection_of_solved_dims: unknown projection",
                 [ Projection_mismatch [ Proj { proj_id; d } ] ] ))

let proj_repr proj_env p = fst @@ Utils.union_find ~equal:Int.equal proj_env.proj_classes ~key:p ~rank:0

let get_product_proj proj_env dim =
  match dim with
  | Dim { d; _ } when not @@ Idx.iterated d -> None
  | Dim { proj_id = Some proj_id; d; _ } ->
      let repr = proj_repr proj_env proj_id in
      if Map.mem proj_env.proj_to_index repr && (not @@ Set.mem proj_env.non_product repr) then Some (repr, d)
      else None
  | Dim { proj_id = None; _ } -> None
  | Var v ->
      raise
      @@ Shape_error
           ( "projection_of_solved_dims: still not fully inferred for variable "
             ^ Sexp.to_string_hum ([%sexp_of: dim_var] v),
             [ Dim_mismatch [ dim ] ] )

let proj_to_iterator proj_env p =
  match Map.find_exn proj_env.proj_to_index (proj_repr proj_env p) with Iterator s -> s | _ -> assert false
