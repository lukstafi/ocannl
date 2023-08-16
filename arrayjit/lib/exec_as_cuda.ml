open Base

let sync_threads_on_update = ref true

(* let session_context = *)

type sync_properties =
  | Thread_only  (** Thread-local tensor. *)
  | Block_only  (** Shared memory tensor. *)
  | Constant
      (** This tensor is accessed directly in the global memory but is not modified by the step update. *)
  | Thread_parallel
      (** Each thread computes a slice of the tensor, independently transferring to global memory. *)
  | Block_parallel  (** Each block computes a slice of the tensor. *)
  | Replicated
      (** Each thread operates on a local copy of the tensor, but only a single thread copies local-to-global. *)
  | Non_local  (** This tensor is accessed directly in the global memory, we did not manage to optimize it. *)
[@@deriving sexp, equal, compare, variants]

type mem_scope = Thread | Shared | Global [@@deriving sexp, equal, compare, variants]

type tensor = {
  hosted : (Ndarray.t[@sexp.opaque]) option;
      (** Pointer to the first value of the associated [Bigarray], if hosted. *)
  global : string option;  (** A global device array, if any. *)
  global_ptr : (Cudajit.deviceptr Lazy.t[@sexp.opaque]) option;
  local : string option;  (** Either a thread-local or shared (block-local) memory, if any. *)
  sync : sync_properties;
  run_scope : mem_scope;
  dims : Shape.dim array;
  host_dims : int array;
      (** Dimensions (shape) of the tensor as a whole, or an empty array if [hosted_ptr]
                              is [None]. *)
  (* device_dims : int array;  * Dimensions (shape) of the per-task slice of the tensor. *)
  host_size_in_bytes : int;  (** Size of the full host's tensor. *)
  global_size_in_bytes : int;  (** Size of the global memory slice of the tensor. *)
  global_length : int;  (** Number of elements in the global memory slice/portion of the tensor. *)
  shared_length : int;  (** Number of elements in the shared (per-block) portion of the tensor. *)
  thread_length : int;  (** Number of elements in the local (per-thread) portion of the tensor. *)
  host_offset : (unit -> int) option;
      (** The offset of the device slice wrt. to the beginning of the host, in number of elements. If [None],
          the device tensor is the full host tensor. *)
  global_is_slice_of_host : bool;
      (** If true, the global tensor is a slice of the host tensor. If false, an intermediate copy on host
          of the global tensor needs to be iterated to copy it to/from the full host tensor. *)
  num_typ : string;
      (** The type of the stored values: [char] (corresponds to precision [Byte]),
      [short] (precision [Half]), [float] (precision [Single]), [double] (precision [Double]). *)
  is_double : bool;
}
[@@deriving sexp_of]

(* let session_results = ref [] *)
let hoist_dynamic_indices = ref false

type session_state = {
  mutable ctx : Cudajit.context option;
  tensors : (Ndarray.ptr, tensor) Hashtbl.Poly.t;
  mutable last_module : Cudajit.module_ option;
}

let session_state = { ctx = None; tensors = Hashtbl.Poly.create (); last_module = None }
let pp_semi ppf () = Caml.Format.fprintf ppf ";@ "
let pp_comma ppf () = Caml.Format.fprintf ppf ",@ "
let pp_symbol ppf sym = Caml.Format.fprintf ppf "%s" @@ Shape.symbol_ident sym
let pp_index ppf sym = Caml.Format.fprintf ppf "%s" @@ Shape.symbol_ident sym

let pp_index_axis scope ppf =
  let open Shape in
  function
  | Iterator it -> (
      match scope with
      | Thread when sample_num_sym it || task_id_sym it -> Caml.Format.fprintf ppf "0"
      | Shared when task_id_sym it -> Caml.Format.fprintf ppf "0"
      | _ when sample_num_sym it -> Caml.Format.fprintf ppf "threadIdx.x"
      | _ when task_id_sym it -> Caml.Format.fprintf ppf "blockIdx.x"
      | _ -> pp_index ppf it)
  | Fixed_idx i -> Caml.Format.fprintf ppf "%d" i

let pp_array_offset scope ppf (idcs, dims) =
  let open Caml.Format in
  assert (not @@ Array.is_empty idcs);
  for _ = 0 to Array.length idcs - 3 do
    fprintf ppf "@[<1>("
  done;
  for i = 0 to Array.length idcs - 1 do
    let dim = dims.(i) in
    if i = 0 then fprintf ppf "%a" (pp_index_axis scope) idcs.(i)
    else if i = Array.length idcs - 1 then fprintf ppf " * %d +@ %a" dim (pp_index_axis scope) idcs.(i)
    else fprintf ppf " * %d +@ %a@])" dim (pp_index_axis scope) idcs.(i)
  done

let array_offset_to_string scope (idcs, dims) =
  let b = Buffer.create 32 in
  let ppf = Caml.Format.formatter_of_buffer b in
  pp_array_offset scope ppf (idcs, dims);
  Caml.Format.pp_print_flush ppf ();
  Buffer.contents b

let get_run_ptr tensor =
  match (tensor.global, tensor.local) with _, Some lv -> lv | Some rv, _ -> rv | None, None -> assert false

let prec_to_c_type = function
  | Ndarray.Void_prec -> "void"
  | Half_prec _ -> (* FIXME: *) "uint16"
  | Single_prec _ -> "float"
  | Double_prec _ -> "double"

let scope_of_sync = function
  | Thread_only | Thread_parallel -> Thread
  | Block_only | Block_parallel -> Shared
  | Constant | Non_local -> Global
  | Replicated -> Thread

let compute_array_offset ~idcs ~dims =
  Array.fold2_exn idcs dims ~init:0 ~f:(fun offset idx dim -> idx + (offset * dim))

let get_tensor ~traced_store ~num_threads:_ ~num_blocks ?force_sync ~jit_code ~dyn_env ~idcs ptr =
  let { tensors; _ } = session_state in
  Hashtbl.find_or_add tensors ptr ~default:(fun () ->
      let n = Code.get ptr.id in
      let tn = Code.(get_node traced_store ptr) in
      let host_size_in_bytes = Node.size_in_bytes n.node in
      let dims = Shape.to_dims n.annot.shape in
      let global_length = Array.fold ~init:1 ~f:( * ) dims in
      let arr = Option.value_exn @@ Code.get_tensor ptr in
      let hosted = if Array.is_empty @@ Ndarray.dims arr then None else Some arr in
      let global_size_in_bytes = global_length * Ndarray.precision_in_bytes arr in
      let thread_length = Array.fold ~init:1 ~f:( * ) dims in
      let shared_length = thread_length in
      let tensor prec is_double arr =
        let num_typ = prec_to_c_type prec in
        let is_block_parallel =
          Array.exists ~f:Shape.(function { special = Dedicated Task_id; _ } -> true | _ -> false)
          @@ Shape.to_dims n.annot.shape
        in
        let is_thread_parallel =
          Array.exists ~f:Shape.(function { special = Dedicated Sample_num; _ } -> true | _ -> false)
          @@ Shape.to_dims n.annot.shape
        in
        let can_be_replicated = tn.is_replicable in
        let computed_directly_across_blocks =
          List.exists tn.rhses
            ~f:(snd @@ Code.check_dedicated_dep Shape.Task_id ~cached_dedicated:(fun _ -> false))
        in
        (* tn.is_replicable is the negation of: computed (directly or) indirectly across blocks. *)
        let computed_directly_across_threads =
          List.exists tn.rhses
            ~f:(snd @@ Code.check_dedicated_dep Shape.Sample_num ~cached_dedicated:(fun _ -> false))
        in
        let sync : sync_properties =
          Option.value_or_thunk force_sync ~default:(fun () ->
              if
                Option.is_none hosted
                && (is_block_parallel || not computed_directly_across_blocks)
                && (is_thread_parallel || not computed_directly_across_threads)
              then Thread_only
              else if Option.is_none hosted && (is_block_parallel || not computed_directly_across_blocks) then
                Block_only
              else if (is_block_parallel || num_blocks <= 1) && is_thread_parallel then Thread_parallel
              else if is_block_parallel then Block_parallel
              else if Option.is_some hosted && tn.read_only then Constant
              else if can_be_replicated && not is_thread_parallel then Replicated
              else (
                if !Code.with_debug then
                  Caml.Format.printf "\nWARNING: Non-local sync for tensor: %a@ node: %a\n%!" Sexp.pp_hum
                    ([%sexp_of: Code.traced_tensor] tn)
                    Sexp.pp_hum
                    ([%sexp_of: Code.node] n);
                Non_local))
        in
        let has_global_mem = not (is_thread_only sync || is_block_only sync) in
        let has_local_mem = not (is_constant sync || is_non_local sync) in
        let run_scope = scope_of_sync sync in
        let global_ptr =
          Option.some_if has_global_mem
          @@
          match sync with
          | Constant ->
              lazy
                (let ptr, size =
                   (* Defer till after compilation, to access the compiled-into module. *)
                   Cudajit.module_get_global
                     (Option.value_exn session_state.last_module)
                     ~name:(Ndarray.ptr_name ptr)
                 in
                 assert (Unsigned.Size_t.to_int size = global_size_in_bytes);
                 ptr)
          | _ ->
              (* The general case does not require laziness, but it should be OK. *)
              lazy
                (if !Code.with_debug then
                   Stdio.printf "Exec_as_cuda.get_tensor: mem_alloc %s\n%!" (Ndarray.ptr_name ptr);
                 Cudajit.mem_alloc ~byte_size:global_size_in_bytes)
        in
        let global = Option.some_if has_global_mem @@ Ndarray.ptr_name ptr in
        let local = Option.some_if has_local_mem @@ Ndarray.ptr_name ptr ^ "_local" in
        let host_dims = Bigarray.Genarray.dims arr in
        let backend_info =
          (if Node.equal_data_kind ptr.field Value then "v:" else "g:")
          ^ (Sexp.to_string_hum @@ sexp_of_sync_properties sync)
          ^ ";"
        in
        if not @@ String.is_substring n.annot.backend_info ~substring:backend_info then
          n.annot.backend_info <- n.annot.backend_info ^ backend_info;
        {
          hosted;
          local;
          sync;
          run_scope;
          dims;
          host_dims;
          host_size_in_bytes;
          global_size_in_bytes;
          global_length;
          thread_length;
          shared_length;
          global_is_slice_of_host;
          host_offset;
          num_typ;
          is_double;
          global;
          global_ptr;
        }
      in
      let f big = tensor (Ndarray.get_prec arr) (Ndarray.is_double_prec_t arr) big in
      Ndarray.map { f } arr)

let jit_binop ~num_typ:_ ~is_double op =
  match op with
  | Low_level.Arg1 -> assert false
  | Arg2 -> assert false
  | Add -> ("(", " +", ")")
  | Mul -> ("(", " *", ")")
  | ToPowOf when is_double -> ("pow(", ",", ")")
  | ToPowOf -> ("powf(", ",", ")")
  | Relu_gate -> ("(", " > 0.0 ?", " : 0.0)")
(* "((int)(", "> 0.0) * ", ")" *)

let jit_code ~num_threads ~num_blocks ~traced_store ppf llc : unit =
  let open Caml.Format in
  let locals = ref Map.Poly.empty in
  let rec pp_ll ~dyn_env ppf c : unit =
    match c with
    | Code.Lines [||] -> ()
    | Lines lines ->
        (* Note: no separator. Filter out some entries known to not generate code to avoid whitespace. *)
        fprintf ppf "@[<v 0>%a@]"
          (pp_print_list (pp_ll ~dyn_env))
          (Array.to_list
          @@ Array.filter lines ~f:(function
               | Zero_out ptr -> not Code.(get_node traced_store ptr).zero_initialized
               | _ -> true))
    | For_loop { index = i; from_; to_; body; trace_it = _ } when Shape.task_id_sym i ->
        assert (from_ = 0);
        if not (!num_blocks = 1 || !num_blocks = to_ + 1) then
          invalid_arg [%string "Exec_as_cuda: parallel dims mismatch: %{!num_blocks#Int} vs. %{to_ + 1#Int}"];
        num_blocks := to_ + 1;
        (* Instead of binding the iterator, we will translate the iterator directly as blockIdx.x. *)
        (* fprintf ppf "@[<2>{@ unsigned int %a = blockIdx.x;@ " pp_index i; *)
        pp_ll ~dyn_env ppf body
        (* fprintf ppf "@]@ }@," *)
    | For_loop { index = i; from_; to_; body; trace_it = _ } when Shape.sample_num_sym i ->
        assert (from_ = 0);
        num_threads := to_ + 1;
        (* Instead of binding the iterator, we will translate the iterator directly as threadIdx.x. *)
        (* fprintf ppf "@[<2>{@ unsigned int %a = threadIdx.x;@ " pp_index i; *)
        pp_ll ~dyn_env ppf body
        (* fprintf ppf "@]@ }@," *)
    | For_loop { index = i; from_; to_; body; trace_it = _ } ->
        fprintf ppf "@[<2>for (unsigned int@ %a = %d;@ %a <= %d;@ ++%a) {@ %a@]@ }@," pp_index i from_
          pp_index i to_ pp_index i (pp_ll ~dyn_env) body
    | Rebalance (s, lines) ->
        pp_ll ~dyn_env ppf
        @@ Lines (Array.append (Option.to_array @@ Option.map s ~f:(fun s -> Code.Comment s)) lines)
    | Zero_out ptr ->
        if Hashtbl.mem session_state.tensors ptr then
          failwith
            ("exec_as_cuda: Non-initialization zeroing-out NOT IMPLEMENTED YET: " ^ Sexp.to_string_hum
            @@ [%sexp_of: Ndarray.ptr] ptr);
        let tn = Code.(get_node traced_store ptr) in
        assert tn.zero_initialized
        (* The initialization will be emitted by get_tensor. *)
    | Set (ptr, idcs, (Binop (op, Get (ptr2, idcs2), v2) as v))
      when Nd.equal_ptr ptr ptr2 && [%equal: Shape.axis_index array] idcs idcs2 ->
        let tensor =
          get_tensor ~traced_store ~num_threads:!num_threads ~num_blocks:!num_blocks
            ~jit_code:(pp_ll ~dyn_env) ~dyn_env ~idcs ptr
        in
        let old_locals = !locals in
        let loop_f = pp_float ~dyn_env ~num_typ:tensor.num_typ ~is_double:tensor.is_double in
        let loop_debug_f = debug_float ~dyn_env ~num_typ:tensor.num_typ ~is_double:tensor.is_double in
        let num_closing_braces = pp_top_locals ~dyn_env ppf v2 in
        (* Because of SIMD-like computation over warps, updates must be atomic, for both global
           and shared variables. *)
        if List.exists ~f:(equal_sync_properties tensor.sync) [ Block_only; Block_parallel ] then
          if Code.equal_binop op Add then
            fprintf ppf "atomicAdd@[<2>(%s + %a,@ %a@]);" (get_run_ptr tensor)
              (pp_array_offset tensor.run_scope) (idcs, tensor.dims) loop_f v2
          else
            failwith @@ "Exec_as_cuda: atomic updates only implemented for addition: "
            ^ Sexp.to_string_hum ([%sexp_of: Low_level.t] llc)
        else
          fprintf ppf "@[<2>%s@[<2>[%a@]] =@ %a;@]" (get_run_ptr tensor) (pp_array_offset tensor.run_scope)
            (idcs, tensor.dims) loop_f v;
        (if !Code.debug_verbose_trace then
           let v_code, v_idcs = loop_debug_f v in
           fprintf ppf
             "@ @[<2>if @[<2>(threadIdx.x == 0 && blockIdx.x == 0@]) {@ printf(@[<h>\"TRACE: %s[%%u] = %%f = \
              %s\\n\"@],@ %a,@ %s[%a]%a);@ @]}"
             (get_run_ptr tensor) v_code (pp_array_offset tensor.run_scope) (idcs, tensor.dims)
             (get_run_ptr tensor) (pp_array_offset tensor.run_scope) (idcs, tensor.dims)
             ( pp_print_list @@ fun ppf -> function
               | `Accessor (run_scope, idx) ->
                   pp_comma ppf ();
                   pp_array_offset run_scope ppf idx
               | `Value v ->
                   pp_comma ppf ();
                   pp_print_string ppf v )
             v_idcs);
        for _ = 1 to num_closing_braces do
          fprintf ppf "@]@ }@,"
        done;
        locals := old_locals
    | Set (ptr, idcs, v) ->
        let tensor =
          get_tensor ~traced_store ~num_threads:!num_threads ~num_blocks:!num_blocks
            ~jit_code:(pp_ll ~dyn_env) ~dyn_env ~idcs ptr
        in
        let old_locals = !locals in
        let loop_f = pp_float ~dyn_env ~num_typ:tensor.num_typ ~is_double:tensor.is_double in
        let loop_debug_f = debug_float ~dyn_env ~num_typ:tensor.num_typ ~is_double:tensor.is_double in
        let num_closing_braces = pp_top_locals ~dyn_env ppf v in
        (* No idea why adding any cut hint at the end of the assign line breaks formatting! *)
        fprintf ppf "@[<2>%s[@,%a] =@ %a;@]@ " (get_run_ptr tensor) (pp_array_offset tensor.run_scope)
          (idcs, tensor.dims) loop_f v;
        (if !Code.debug_verbose_trace then
           let v_code, v_idcs = loop_debug_f v in
           fprintf ppf
             "@ @[<2>if @[<2>(threadIdx.x == 0 && blockIdx.x == 0@]) {@ printf(@[<h>\"TRACE: %s[%%u] = %%f = \
              %s\\n\"@],@ %a,@ %s[%a]%a);@ @]}"
             (get_run_ptr tensor) v_code (pp_array_offset tensor.run_scope) (idcs, tensor.dims)
             (get_run_ptr tensor) (pp_array_offset tensor.run_scope) (idcs, tensor.dims)
             ( pp_print_list @@ fun ppf -> function
               | `Accessor (run_scope, idx) ->
                   pp_comma ppf ();
                   pp_array_offset run_scope ppf idx
               | `Value v ->
                   pp_comma ppf ();
                   pp_print_string ppf v )
             v_idcs);
        for _ = 1 to num_closing_braces do
          fprintf ppf "@]@ }@,"
        done;
        locals := old_locals
    | Dynamic_indices { tensor; tensor_idcs; dynamic_idcs; target_dims; body; slice = _ } ->
        jit_dynamic_indices ~dyn_env tensor ~tensor_idcs ~dynamic_idcs ~target_dims body
    | Comment message ->
        fprintf ppf "/* %s */@ " message;
        if !Code.debug_verbose_trace then
          fprintf ppf
            "@[<2>if @[<2>(threadIdx.x == 0 && blockIdx.x == 0@]) {@ printf(@[<h>\"TRACE: %s\\n\"@]);@ @]}"
            (String.substr_replace_all ~pattern:"%" ~with_:"%%" message)
    | Staged_compilation callback -> callback ()
    | Synchronize s -> invalid_arg @@ "Exec_as_cuda: Uneliminated synchronization: " ^ s
    | Set_local (({ scope_id; _ } as id), value) ->
        let num_typ, is_double = Map.find_exn !locals id in
        let old_locals = !locals in
        let num_closing_braces = pp_top_locals ~dyn_env ppf value in
        fprintf ppf "@[<2>v%d =@ %a;@]" scope_id ((pp_float ~dyn_env) ~num_typ ~is_double) value;
        for _ = 1 to num_closing_braces do
          fprintf ppf "@]@ }@,"
        done;
        locals := old_locals
  and pp_top_locals ~dyn_env ppf (vcomp : Low_level.float_t) : int =
    match vcomp with
    | Local_scope { id = { scope_id = i; _ } as id; prec; body; orig_indices = _ } ->
        let typ = prec_to_c_type prec in
        (* Tensors are initialized to 0 by default. However, there is typically an explicit
           initialization for virtual nodes. *)
        fprintf ppf "@[<2>{@ %s v%d = 0;@ " typ i;
        locals := Map.update !locals id ~f:(fun _ -> (typ, Ndarray.is_double_prec prec));
        pp_ll ~dyn_env ppf body;
        pp_print_space ppf ();
        1
    | Get_local _ | Get_global _ | Get _ | Constant _ -> 0
    | Binop (Arg1, v1, _v2) -> pp_top_locals ~dyn_env ppf v1
    | Binop (Arg2, _v1, v2) -> pp_top_locals ~dyn_env ppf v2
    | Binop (_, v1, v2) -> pp_top_locals ~dyn_env ppf v1 + pp_top_locals ~dyn_env ppf v2
    | Unop (_, v) -> pp_top_locals ~dyn_env ppf v
  and pp_float ~dyn_env ~num_typ ~is_double ppf value =
    let loop = pp_float ~dyn_env ~num_typ ~is_double in
    match value with
    | Local_scope { id; _ } ->
        (* Embedding of Local_scope is done by pp_top_locals. *)
        loop ppf @@ Get_local id
    | Get_local id ->
        let typ, _local_is_double = Map.find_exn !locals id in
        if not @@ String.equal num_typ typ then fprintf ppf "(%s)" num_typ;
        fprintf ppf "v%d" id.scope_id
    | Get_global _ -> failwith "Exec_as_cuda: Get_global / FFI NOT IMPLEMENTED YET"
    | Get (ptr, idcs) ->
        (* let host_idcs = lookup ~on_host:true idcs in *)
        let tensor =
          get_tensor ~traced_store ~num_threads:!num_threads ~num_blocks:!num_blocks
            ~jit_code:(pp_ll ~dyn_env) ~dyn_env ~idcs ptr
        in
        fprintf ppf "@[<2>%s[%a@]]" (get_run_ptr tensor) (pp_array_offset tensor.run_scope) (idcs, tensor.dims)
    | Constant c -> fprintf ppf "(%f)" c
    | Binop (Arg1, v1, _v2) -> loop ppf v1
    | Binop (Arg2, _v1, v2) -> loop ppf v2
    | Binop (op, v1, v2) ->
        let prefix, infix, postfix = jit_binop ~num_typ ~is_double op in
        fprintf ppf "@[<1>%s%a%s@ %a@]%s" prefix loop v1 infix loop v2 postfix
    | Unop (Identity, v) -> loop ppf v
    | Unop (Relu, v) ->
        (* FIXME: don't recompute v *)
        fprintf ppf "@[<1>(%a > 0.0 ?@ %a : 0.0@])" loop v loop v
  and debug_float ~dyn_env ~num_typ ~is_double (value : Low_level.float_t) : string * 'a list =
    let loop = debug_float ~dyn_env ~num_typ ~is_double in
    match value with
    | Local_scope { id; _ } ->
        (* Not printing the inlined definition: (1) code complexity; (2) don't overload the debug logs. *)
        loop @@ Get_local id
    | Get_local id ->
        let typ, _local_is_double = Map.find_exn !locals id in
        let v =
          (if not @@ String.equal num_typ typ then "(" ^ num_typ ^ ")" else "")
          ^ "v" ^ Int.to_string id.scope_id
        in
        (v ^ "{=%f}", [ `Value v ])
    | Get_global _ -> failwith "Exec_as_cuda: Get_global / FFI NOT IMPLEMENTED YET"
    | Get (ptr, idcs) ->
        (* let host_idcs = lookup ~on_host:true idcs in *)
        let tensor =
          get_tensor ~traced_store ~num_threads:!num_threads ~num_blocks:!num_blocks
            ~jit_code:(pp_ll ~dyn_env) ~dyn_env ~idcs ptr
        in
        let v =
          sprintf "@[<2>%s[%s@]]" (get_run_ptr tensor)
            (array_offset_to_string tensor.run_scope (idcs, tensor.dims))
        in
        (get_run_ptr tensor ^ "[%u]{=%f}", [ `Accessor (tensor.run_scope, (idcs, tensor.dims)); `Value v ])
    | Constant c -> (Float.to_string c, [])
    | Binop (Arg1, v1, _v2) -> loop v1
    | Binop (Arg2, _v1, v2) -> loop v2
    | Binop (op, v1, v2) ->
        let prefix, infix, postfix = jit_binop ~num_typ ~is_double op in
        let v1, idcs1 = loop v1 in
        let v2, idcs2 = loop v2 in
        (String.concat [ prefix; v1; infix; " "; v2; postfix ], idcs1 @ idcs2)
    | Unop (Identity, v) -> loop v
    | Unop (Relu, v) ->
        let v, idcs = loop v in
        (String.concat [ "("; v; " > 0.0 ? "; v; " : 0.0)" ], idcs @ idcs)
  and jit_dynamic_indices ~dyn_env ptr ~tensor_idcs ~dynamic_idcs ~target_dims body =
    (* let host_idcs = lookup ~on_host:true ~example_only:true tensor_idcs in *)
    let tensor =
      get_tensor ~traced_store ~num_threads:!num_threads ~num_blocks:!num_blocks ~jit_code:(pp_ll ~dyn_env)
        ~dyn_env ~idcs:tensor_idcs ptr
    in
    fprintf ppf "@[<2>{";
    let dyn_env =
      Array.foldi dynamic_idcs ~init:dyn_env ~f:(fun provider_dim dyn_env sym ->
          let target_dim = target_dims.(provider_dim).dim in
          fprintf ppf "@ unsigned int %a =@ (unsigned int)(%s[%a]) %% %d;" pp_symbol sym (get_run_ptr tensor)
            (pp_array_offset ~provider_dim tensor.run_scope)
            (tensor_idcs, tensor.dims) target_dim;
          Map.add_exn dyn_env ~key:sym ~data:(ptr, provider_dim, tensor_idcs, target_dim))
    in
    pp_print_space ppf ();
    pp_ll ~dyn_env ppf body;
    (* fprintf ppf "%a" (pp_ll ~dyn_env ~env) body; *)
    fprintf ppf "@]@ }@,"
  in
  pp_ll ~dyn_env:Code.empty_env ppf llc

let new_context ?(device_num = 0) () =
  let num_devices = Cudajit.device_get_count () in
  if num_devices <= device_num then None
  else
    let device = Cudajit.device_get ~ordinal:device_num in
    Some (Cudajit.ctx_create ~flags:0 device)

let cleanup_session () =
  if Option.is_none session_state.ctx then Cudajit.init ();
  Option.iter session_state.last_module ~f:Cudajit.module_unload;
  session_state.last_module <- None;
  Hashtbl.iter session_state.tensors ~f:(fun tensor ->
      Option.iter tensor.global_ptr ~f:(fun (lazy ptr) ->
          if not @@ is_constant tensor.sync then (
            if !Code.with_debug then
              Stdio.printf "Exec_as_cuda.cleanup_session: mem_free %s\n%!" (Option.value_exn tensor.global);
            Cudajit.mem_free ptr)));
  Hashtbl.clear session_state.tensors;
  Option.iter session_state.ctx ~f:Cudajit.ctx_destroy;
  (* For now we stick with device 0. *)
  session_state.ctx <- new_context ()

let error_message ~name:_ ~prefix:_ ?extra_error_msg:_ ~contents:_ _exc = ""

let jit_func ~name ?(verbose = false) (traced_store, llc) =
  let module Cu = Cudajit in
  Hashtbl.filter_inplace session_state.tensors ~f:(fun tensor -> not @@ is_constant tensor.sync);
  Option.iter session_state.last_module ~f:Cu.module_unload;
  session_state.last_module <- None;
  if Option.is_none session_state.ctx then (
    if verbose then Stdio.printf "Exec_as_cuda.jit: initializing the CUDA context\n%!";
    cleanup_session ());
  if Option.is_none session_state.ctx then invalid_arg "Exec_as_cuda: no device found";
  if verbose then Stdio.printf "Exec_as_cuda.jit: generating the .cu source\n%!";
  let b = Buffer.create 4096 in
  let ppf = Caml.Format.formatter_of_buffer b in
  let num_threads = ref 1 and num_blocks = ref 1 in
  jit_code ~num_threads ~num_blocks ~traced_store ppf llc;
  Caml.Format.pp_print_newline ppf ();
  let cu_body = Buffer.contents b in
  let tensors = Hashtbl.to_alist session_state.tensors in
  let params, args =
    List.unzip
    @@ List.filter_map tensors ~f:(fun (_, tn) ->
           match tn.sync with
           | Thread_only | Block_only | Constant -> None
           | _ -> Option.map tn.global ~f:(fun t_name -> (tn.num_typ ^ " *" ^ t_name, tn.global_ptr)))
  in
  (* TODO: optimize zero-initializations? E.g.
     https://stackoverflow.com/questions/23712558/how-do-i-best-initialize-a-local-memory-array-to-0 *)
  let constant_defs =
    List.filter_map tensors ~f:(fun (ptr, tn) ->
        match tn.sync with
        | Constant ->
            Option.map tn.global ~f:(fun t_name ->
                "__constant__ " ^ tn.num_typ ^ " " ^ t_name ^ "[" ^ Int.to_string tn.global_length
                ^ if Code.(get_node traced_store ptr).zero_initialized then "] = {0};" else "];")
        | _ -> None)
  in
  let shared_decls =
    List.filter_map tensors ~f:(fun (_, tn) ->
        match tn.sync with
        | Block_only | Block_parallel ->
            Option.map tn.local ~f:(fun t_name ->
                "__shared__ " ^ tn.num_typ ^ " " ^ t_name ^ "[" ^ Int.to_string tn.shared_length ^ "];")
        | _ -> None)
  in
  let thread_decls =
    List.filter_map tensors ~f:(fun (ptr, tn) ->
        match tn.sync with
        | Thread_only | Thread_parallel | Replicated ->
            Option.map tn.local ~f:(fun t_name ->
                tn.num_typ ^ " " ^ t_name ^ "[" ^ Int.to_string tn.thread_length
                ^ if Code.(get_node traced_store ptr).zero_initialized then "] = {0};" else "];")
        | _ -> None)
  in
  let inits =
    Array.of_list tensors
    |> Array.filter_map ~f:(fun (ptr, tn) ->
           let n = Code.get_node traced_store ptr in
           if not n.read_before_write then
             (* __shared__ variables cannot have initializers. *)
             if n.zero_initialized then
               match tn.sync with
               | Block_only | Block_parallel ->
                   Option.map tn.local ~f:(fun l_name ->
                       let b = Buffer.create 4096 in
                       let ppf = Caml.Format.formatter_of_buffer b in
                       let body idcs =
                         Code.Staged_compilation
                           (fun () ->
                             Caml.Format.fprintf ppf
                               "@[<2>if (threadIdx.x == 0) {@ @[<2>%s@[<1>[%a@]] =@ 0;@]@ @]}" l_name
                               (pp_array_offset tn.run_scope) (idcs, tn.dims))
                       in
                       let loops =
                         Code.((Lines [| loop_over_dims tn.dims ~body |] : Low_level.t))
                       in
                       jit_code ~num_threads ~num_blocks ~traced_store ppf loops;
                       Caml.Format.pp_print_newline ppf ();
                       Buffer.contents b)
               | _ -> None
             else None
           else
             match tn.run_scope with
             | Thread | Shared ->
                 Option.map2 tn.local tn.global ~f:(fun l_name g_name ->
                     let b = Buffer.create 4096 in
                     let ppf = Caml.Format.formatter_of_buffer b in
                     let body idcs =
                       Code.Staged_compilation
                         (fun () ->
                           Caml.Format.fprintf ppf "@[<2>%s@[<1>[%a@]] =@ %s@[<1>[%a@]];@]" l_name
                             (pp_array_offset tn.run_scope) (idcs, tn.dims) g_name (pp_array_offset Global)
                             (idcs, tn.dims))
                     in
                     let loops =
                       Code.((Lines [| loop_over_dims tn.dims ~body |] : Low_level.t))
                     in
                     jit_code ~num_threads ~num_blocks ~traced_store ppf loops;
                     Caml.Format.pp_print_newline ppf ();
                     Buffer.contents b)
             | _ -> None)
  in
  let finalizers =
    Array.of_list tensors
    |> Array.filter_map ~f:(fun (_, tn) ->
           match tn.run_scope with
           | Thread | Shared ->
               Option.map2 tn.local tn.global ~f:(fun l_name g_name ->
                   let b = Buffer.create 4096 in
                   let ppf = Caml.Format.formatter_of_buffer b in
                   let body idcs =
                     Code.Staged_compilation
                       (fun () ->
                         Caml.Format.fprintf ppf "@[<2>%s[%a] =@ %s[%a];@]" g_name (pp_array_offset Global)
                           (idcs, tn.dims) l_name (pp_array_offset tn.run_scope) (idcs, tn.dims))
                   in
                   let loops = Code.loop_over_dims tn.dims ~body in
                   if is_replicated tn.sync then
                     Caml.Format.fprintf ppf "@[<2>if @[<2>(threadIdx.x == 0 && blockIdx.x == 0@]) {@ %a@ @]}"
                       (jit_code ~num_threads ~num_blocks ~traced_store)
                       loops
                   else jit_code ~num_threads ~num_blocks ~traced_store ppf loops;
                   Caml.Format.pp_print_newline ppf ();
                   Buffer.contents b)
           | _ -> None)
  in
  let cu_src =
    [%string
      {|
%{if !Code.debug_verbose_trace then "__device__ int printf (const char * format, ... );" else ""}
%{String.concat ~sep:"\n" constant_defs}
extern "C" __global__ void %{name}(%{String.concat ~sep:", " params}) {
  /* Shared: block-local declarations. */
  %{String.concat ~sep:"\n  " shared_decls}
  
  /* Thread-local declarations. */
  %{String.concat ~sep:"\n  " thread_decls}

  /* Initialization: copy global-to-local and zero-initialize shared variables. */
  %{String.concat_array ~sep:"\n  "
    @@ Array.map inits ~f:(String.substr_replace_all ~pattern:"\n" ~with_:"\n  ")}
  __syncthreads();

  /* Main logic. */
  %{String.substr_replace_all cu_body ~pattern:"\n" ~with_:"\n  "}

  /* Finalization: copy local-to-global. */
  __syncthreads();
  %{String.concat_array ~sep:"\n  "
    @@ Array.map finalizers ~f:(String.substr_replace_all ~pattern:"\n" ~with_:"\n  ")}
}
|}]
  in
  (* Constants will be referred to via cuModuleGetGlobal. *)
  let f_name = name ^ "-cudajit-debug" in
  if !Code.with_debug && !Code.keep_files_in_run_directory then (
    let oc = Out_channel.open_text @@ f_name ^ ".cu" in
    Stdio.Out_channel.output_string oc cu_src;
    Stdio.Out_channel.flush oc;
    Stdio.Out_channel.close oc);
  if verbose then Stdio.printf "Exec_as_cuda.jit: compiling to PTX\n%!";
  let ptx = Cu.compile_to_ptx ~cu_src ~name ~options:[ "--use_fast_math" ] ~with_debug:!Code.with_debug in
  if !Code.with_debug && !Code.keep_files_in_run_directory then (
    let f_name = name ^ "-cudajit-debug" in
    let oc = Out_channel.open_text @@ f_name ^ ".ptx" in
    Stdio.Out_channel.output_string oc @@ Cudajit.string_from_ptx ptx;
    Stdio.Out_channel.flush oc;
    Stdio.Out_channel.close oc;
    let oc = Out_channel.open_text @@ f_name ^ ".cu_log" in
    Stdio.Out_channel.output_string oc @@ Option.value_exn ptx.log;
    Stdio.Out_channel.flush oc;
    Stdio.Out_channel.close oc);
  let module_ = Cu.module_load_data_ex ptx [] in
  session_state.last_module <- Some module_;
  let func = Cu.module_get_function module_ ~name in
  let args = List.map args ~f:(function Some (lazy p) -> Cu.Tensor p | None -> assert false) in
  if verbose then Stdio.printf "Exec_as_cuda.jit: compilation finished\n%!";
  fun () ->
    if verbose then Stdio.printf "Exec_as_cuda.jit: copying host-to-device and zeroing-out global memory\n%!";
    List.iter tensors ~f:(function
      | ptr, { hosted = Some ndarray; global_ptr = Some (lazy dst); host_offset; global_length; _ } ->
          let host_offset = Option.map host_offset ~f:(fun f -> f ()) in
          let tn = Code.(get_node traced_store ptr) in
          if tn.read_before_write then (
            let f src = Cu.memcpy_H_to_D ?host_offset ~length:global_length ~dst ~src () in
            if verbose && !Code.with_debug then
              Stdio.printf "Exec_as_cuda.jit: memcpy_H_to_D for %s, offset: %s, length: %d\n%!"
                (Ndarray.ptr_name ptr)
                (Sexp.to_string_hum @@ [%sexp_of: int option] host_offset)
                global_length;
            Ndarray.map { f } ndarray)
      | _ -> ());
    List.iter tensors ~f:(function
      | ptr, { global_ptr = Some (lazy device); global_size_in_bytes; _ } ->
          let tn = Code.(get_node traced_store ptr) in
          if tn.zero_initialized then Cu.memset_d8 device Unsigned.UChar.zero ~length:global_size_in_bytes
      | _ -> ());
    if verbose then Stdio.printf "Exec_as_cuda.jit: running the kernel\n%!";
    (* if !Code.debug_verbose_trace then Cu.ctx_set_limit CU_LIMIT_PRINTF_FIFO_SIZE 4096; *)
    Cu.launch_kernel func ~grid_dim_x:!num_blocks ~block_dim_x:!num_threads ~shared_mem_bytes:0 Cu.no_stream
      args;
    Cu.ctx_synchronize ();
    if verbose then Stdio.printf "Exec_as_cuda.jit: copying device-to-host\n%!";
    List.iter tensors ~f:(function
      | ptr, { hosted = Some ndarray; global_ptr = Some (lazy src); host_offset; global_length; _ } ->
          let host_offset = Option.map host_offset ~f:(fun f -> f ()) in
          let tn = Code.(get_node traced_store ptr) in
          if not tn.read_only then (
            let f dst = Cu.memcpy_D_to_H ?host_offset ~length:global_length ~dst ~src () in
            if verbose && !Code.with_debug then
              Stdio.printf "Exec_as_cuda.jit: memcpy_D_to_H for %s\n%!" (Ndarray.ptr_name ptr);
            Ndarray.map { f } ndarray)
      | _ -> ());
    if verbose then Stdio.printf "Exec_as_cuda.jit: kernel run finished\n%!"

let jit = jit_func