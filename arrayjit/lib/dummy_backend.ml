open Base
module Debug_runtime = Utils.Debug_runtime
module LA = Lazy_array

type context = { label : string; arrays : Sexp.t ref Map.M(LA).t; mutable state : string }
[@@deriving sexp_of]

let backend_state = ref ""

let unsafe_cleanup ?(unsafe_shutdown = false) () =
  if unsafe_shutdown then backend_state := "Shut down" else backend_state := "Initialized"

let is_initialized, initialize =
  let initialized = ref false in
  ( (fun () -> !initialized),
    fun () ->
      initialized := true;
      unsafe_cleanup () )

let finalize ctx = ctx.state <- "Finalized"

let init ~label =
  let result = { label; arrays = Map.empty (module LA); state = "Initialized" } in
  Core.Gc.Expert.add_finalizer_exn result finalize;
  result

let prec_is_double = function Ops.Double_prec _ -> true | _ -> false
let is_builtin_op = function Ops.Add | Sub | Mul | Div -> true | ToPowOf | Relu_gate | Arg2 | Arg1 -> false

let updates (llc : Low_level.t) =
  let emp = Map.empty (module LA) in
  let non = Set.empty (module LA) in
  let merge (gets1, env1) (gets2, env2) = (Set.union gets1 gets2, Utils.map_merge ~f:Set.union env1 env2) in
  let rec loop = function
    | Low_level.Noop -> (non, emp)
    | Low_level.Comment _ -> (non, emp)
    | Low_level.Staged_compilation _ -> (non, emp)
    | Low_level.Seq (s1, s2) -> merge (loop s1) (loop s2)
    | Low_level.For_loop { index = _; from_ = _; to_ = _; body; trace_it = _ } -> loop body
    | Low_level.Zero_out a -> (non, Map.singleton (module LA) a non)
    | Low_level.Set (a, _, v) | Low_level.Set_local ({ nd = a; scope_id = _ }, v) ->
        let gets, env = accessors v in
        (non, Utils.map_merge ~f:Set.union (Map.singleton (module LA) a gets) env)
  and accessors v =
    match v with
    | Low_level.Local_scope { id = { nd = a; scope_id = _ }; prec = _; body; orig_indices = _ } ->
        let gets, env = loop body in
        (Set.singleton (module LA) a, Utils.map_merge ~f:Set.union (Map.singleton (module LA) a gets) env)
    | Low_level.Get_local { nd = a; scope_id = _ } -> (Set.singleton (module LA) a, emp)
    | Low_level.Get_global (_, _) -> (non, emp)
    | Low_level.Get (a, _) -> (Set.singleton (module LA) a, emp)
    | Low_level.Binop (_, v1, v2) -> merge (accessors v1) (accessors v2)
    | Low_level.Unop (_, v) -> accessors v
    | Low_level.Constant _ -> (non, emp)
    | Low_level.Embed_index _ -> (non, emp)
  in
  loop llc

let jit old_context ~name ?verbose:_ bindings (_traced_store, compiled) =
  let module Debug_runtime =
    (val Minidebug_runtime.debug_file (* ~split_files_after:(1 lsl 16) *)
           ~for_append:false
           ~hyperlink:"./" (* ~hyperlink:"vscode://file//wsl.localhost/ubuntu23/home/lukstafi/ocannl/" *)
           ~values_first_mode:true
           ~backend:(`Markdown PrintBox_md.Config.(foldable_trees default))
         (* ~backend:(`Html PrintBox_html.Config.(tree_summary true default))  *)
         @@ "debug-"
         ^ old_context.label)
  in
  if String.is_empty !backend_state then initialize ();
  let _gets, sets = updates compiled in
  let arrays =
    Map.fold sets ~init:old_context.arrays ~f:(fun ~key ~data:_ arrays ->
        Map.update arrays key ~f:(function Some v -> v | None -> ref (Sexp.List [])))
  in
  let context = { old_context with arrays } in
  let symbols = Indexing.bound_symbols bindings in
  let jitted_bindings = List.map symbols ~f:(fun s -> (s, ref 0)) in
  let%track_sexp run () =
    Map.iteri sets ~f:(fun ~key ~data ->
        let args = Set.to_list data |> List.map ~f:(fun la -> la.backend_info) in
        key.backend_info <- Sexp.(List (Atom name :: args));
        Debug_runtime.log_value_sexp
          ~descr:[%string {|%{name} @ %{context.label}: %{String.concat ~sep:"." key.label} :=|}]
          ~entry_id:__entry_id ~is_result:false key.backend_info)
  in
  (context, jitted_bindings, run)

let%track_sexp from_host context la =
  match Map.find context.arrays la with
  | None -> false
  | Some logs ->
      (logs := Sexp.(List [ Atom "from_host"; la.backend_info ]));
      Debug_runtime.log_value_sexp
        ~descr:[%string {|from_host %{String.concat ~sep:"." la.label}: %{context.label} :=|}]
        ~entry_id:__entry_id ~is_result:false !logs;
      true

let%track_sexp to_host (context : context) la =
  match Map.find context.arrays la with
  | None -> false
  | Some logs ->
      la.backend_info <- Sexp.(List [ Atom "to_host"; !logs ]);
      Debug_runtime.log_value_sexp
        ~descr:[%string {|to_host %{String.concat ~sep:"." la.label} := %{context.label}|}]
        ~entry_id:__entry_id ~is_result:false la.backend_info;
      true

(*
   let merge_from ?(name_suffix = "") (context : context) ~dst ~accum ~src bindings =
     let body idcs = Low_level.(Set (dst, idcs, Binop (accum, Get (dst, idcs), Get (src, idcs)))) in
     let llc = Low_level.loop_over_dims (Lazy.force dst.dims) ~body in
     let name = [%string "merge_into_%{dst.Lazy_array.id#Int}%{name_suffix}"] in
     jit context ~name ~verbose:false bindings (Low_level.compile_proc ~name [] llc) *)

let%track_sexp merge ?name_suffix la ~dst ~accum:_ ~src bindings =
  match (Map.find src.arrays la, Map.find dst.arrays la) with
  | None, _ | _, None -> None
  | Some src_info, Some dst_info ->
      let module Debug_runtime =
        (val Minidebug_runtime.debug_file (* ~split_files_after:(1 lsl 16) *)
               ~for_append:false
               ~hyperlink:"./" (* ~hyperlink:"vscode://file//wsl.localhost/ubuntu23/home/lukstafi/ocannl/" *)
               ~values_first_mode:true
               ~backend:(`Markdown PrintBox_md.Config.(foldable_trees default))
             (* ~backend:(`Html PrintBox_html.Config.(tree_summary true default))  *)
             @@ "debug-"
             ^ dst.label)
      in
      let symbols = Indexing.bound_symbols bindings in
      let jitted_bindings = List.map symbols ~f:(fun s -> (s, ref 0)) in
      let run () =
        let name = "merge_from_" ^ Option.value name_suffix ~default:"" in
        let elem = Sexp.(List [ Atom name; !src_info ]) in
        dst_info := Utils.sexp_append !dst_info ~elem;
        Debug_runtime.log_value_sexp
          ~descr:[%string {|merge %{String.concat ~sep:"." la.label}: %{dst.label} := %{src.label}|}]
          ~entry_id:__entry_id ~is_result:false !dst_info
      in
      Some (dst, jitted_bindings, run)
