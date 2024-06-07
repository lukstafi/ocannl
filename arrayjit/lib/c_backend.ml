open Base
module Lazy = Utils.Lazy
module Debug_runtime = Utils.Debug_runtime

[%%global_debug_log_level Nothing]
[%%global_debug_log_level_from_env_var "OCANNL_LOG_LEVEL"]

let name = "c"
let optimization_level = ref 3

type config = [ `Physical_devices_only | `For_parallel_copying | `Most_parallel_devices ]
[@@deriving equal, sexp, variants]
(** Currently unused, backend behaves as if [config] is always [`Physical_devices_only]. *)

type mem_properties =
  | Local_only  (** The array is only needed for a local computation, is allocated on the stack. *)
  | From_context  (** The array has a copy allocated per-cpu-device, may or may not exist on the host. *)
  | Constant_from_host  (** The array is read directly from the host. *)
[@@deriving sexp, equal, compare, variants]

module Tn = Tnode

type ctx_arrays = Ndarray.t Map.M(Tn).t [@@deriving sexp_of]
type context = { label : string; arrays : ctx_arrays } [@@deriving sexp_of]

let ctx_arrays context = context.arrays
let unsafe_cleanup ?(unsafe_shutdown = false) () = ignore unsafe_shutdown

let is_initialized, initialize =
  let initialized = ref false in
  ( (fun () -> !initialized),
    fun () ->
      initialized := true;
      unsafe_cleanup () )

let finalize _ctx = ()

let init ~label =
  let result = { label; arrays = Map.empty (module Tn) } in
  Core.Gc.Expert.add_finalizer_exn result finalize;
  result

type tn_info = {
  tn : Tn.t;  (** The original array. *)
  mutable ptr : string;
      (** Pointer to the first value of the associated array.
          - if [mem = Constant_from_host], the pointer to the first element of the hosted [Ndarray],
          - if [mem = From_context], either a pointer to [Ndarray] from [context.arrays] when [~shared:false],
            or the function parameter when [~shared:true],
          - if [mem = Local_only], the address of the on-the-stack array. *)
  mem : mem_properties;
  dims : int array;
  size_in_elems : int;
  size_in_bytes : int;
  prec : Ops.prec;
  zero_initialized : bool;
}
[@@deriving sexp_of]

type info_nodes = {
  traced_store : (Low_level.traced_store[@sexp.opaque]);
  nodes : (Tn.t, tn_info) Hashtbl.t;
  used_tensors : Hash_set.M(Tn).t;
  get_ident : Tn.t -> string;
}
[@@deriving sexp_of]

type param_source = Log_file_name | Param_ptr of Tn.t | Static_idx of Indexing.static_symbol
[@@deriving sexp_of]

(* open Ctypes *)
(* open Foreign *)

type procedure = {
  info : info_nodes;
  bindings : Indexing.unit_bindings;
  name : string;
  result : (Dl.library[@sexp.opaque]);
  opt_ctx_arrays : Ndarray.t Map.M(Tn).t option;
  (* params : param_source list; *)
}
[@@deriving sexp_of]

type ctx_nodes = Ctx_arrays of Ndarray.t Map.M(Tn).t ref | Param_ptrs of (string * param_source) list ref
[@@deriving sexp_of]

(* https://github.com/yallop/ocaml-ctypes/blob/master/src/ctypes-foreign/dl.mli
   https://github.com/ahrefs/ocannl/blob/1eb5209772b759f00a0cb8a39e51c4ddae78aee6/lib/exec_as_OCaml.ml *)

let pp_zero_out ppf node = Stdlib.Format.fprintf ppf "@[<2>memset(%s, 0, %d)" node.ptr node.size_in_bytes

let get_c_ptr prec nd =
  let f arr = Ops.ptr_to_string (Ctypes.bigarray_start Ctypes_static.Genarray arr) prec in
  Ndarray.(map { f } nd)

let is_builtin_op = function Ops.Add | Sub | Mul | Div -> true | ToPowOf | Relu_gate | Arg2 | Arg1 -> false

let node_debug_name node =
  let memloc = if Utils.settings.debug_memory_locations then "@" ^ node.ptr else "" in
  Tn.name node.tn ^ memloc

(* let pp_semi ppf () = Stdlib.Format.fprintf ppf ";@ " *)
let pp_comma ppf () = Stdlib.Format.fprintf ppf ",@ "

(* let pp_symbol ppf sym = Stdlib.Format.fprintf ppf "%s" @@ Indexing.symbol_ident sym *)
let pp_index ppf sym = Stdlib.Format.fprintf ppf "%s" @@ Indexing.symbol_ident sym

let pp_index_axis ppf = function
  | Indexing.Iterator it -> pp_index ppf it
  | Fixed_idx i -> Stdlib.Format.fprintf ppf "%d" i

let pp_array_offset ppf (idcs, dims) =
  let open Stdlib.Format in
  assert (not @@ Array.is_empty idcs);
  for _ = 0 to Array.length idcs - 3 do
    fprintf ppf "@[<1>("
  done;
  for i = 0 to Array.length idcs - 1 do
    let dim = dims.(i) in
    if i = 0 then fprintf ppf "%a" pp_index_axis idcs.(i)
    else if i = Array.length idcs - 1 then fprintf ppf " * %d +@ %a" dim pp_index_axis idcs.(i)
    else fprintf ppf " * %d +@ %a@])" dim pp_index_axis idcs.(i)
  done

let array_offset_to_string (idcs, dims) =
  let b = Buffer.create 32 in
  let ppf = Stdlib.Format.formatter_of_buffer b in
  pp_array_offset ppf (idcs, dims);
  Stdlib.Format.pp_print_flush ppf ();
  Buffer.contents b

(* let compute_array_offset ~idcs ~dims = Array.fold2_exn idcs dims ~init:0 ~f:(fun offset idx dim -> idx +
   (offset * dim)) *)

let%debug_sexp prepare_node ~(traced_store : Low_level.traced_store) info ctx_nodes tn =
  Hash_set.add info.used_tensors tn;
  let default () =
    (* let tn = Low_level.get_node traced_store v in *)
    (* TODO: We will need tn to perform more refined optimizations. *)
    let dims = Lazy.force tn.dims in
    let size_in_elems = Array.fold ~init:1 ~f:( * ) dims in
    let prec = tn.prec in
    let size_in_bytes = size_in_elems * Ops.prec_in_bytes prec in
    let is_on_host = Tn.is_hosted_force tn 33 in
    let is_materialized = Tn.is_materialized_force tn 331 in
    let is_constant = Tn.is_hosted_force ~specifically:Constant tn 332 in
    assert (Bool.(Option.is_some (Lazy.force tn.array) = is_on_host));
    (* FIXME: difference plain C vs. CUDA? *)
    (* let num_typ = Ops.cuda_typ_of_prec prec in *)
    let traced = Low_level.(get_node traced_store tn) in
    let mem =
      if not is_materialized then Local_only
      else if is_constant && traced.read_only then Constant_from_host
      else From_context
    in
    let ident = info.get_ident tn in
    let ptr =
      match (mem, ctx_nodes) with
      | From_context, Ctx_arrays ctx_arrays -> (
          match Map.find !ctx_arrays tn with
          | None ->
              let data =
                Ndarray.create_array tn.Tn.prec ~dims @@ Constant_fill { values = [| 0. |]; strict = false }
              in
              ctx_arrays := Map.add_exn !ctx_arrays ~key:tn ~data;
              get_c_ptr prec data
          | Some data -> get_c_ptr prec data)
      | From_context, Param_ptrs ptrs ->
          ptrs := (name, Param_ptr tn) :: !ptrs;
          ident
      | Constant_from_host, _ -> get_c_ptr prec @@ Option.value_exn @@ Lazy.force tn.array
      | Local_only, _ -> ident
    in
    let backend_info = sexp_of_mem_properties mem in
    if Utils.settings.with_debug_level > 0 then
      [%log
        "creating",
          (tn.id : int),
          Tn.label tn,
          "mem",
          (backend_info : Sexp.t),
          "prec",
          (prec : Ops.prec),
          "on-host",
          (is_on_host : bool),
          "is-global",
          (Option.is_some global : bool)];
    if not @@ Utils.sexp_mem ~elem:backend_info tn.backend_info then
      tn.backend_info <- Utils.sexp_append ~elem:backend_info tn.backend_info;
    let zero_initialized = (Hashtbl.find_exn traced_store tn).Low_level.zero_initialized in
    { tn; ptr; mem; dims; size_in_bytes; size_in_elems; prec; zero_initialized }
  in
  Hashtbl.find_or_add info.nodes tn ~default

let compile_main ~traced_store info ppf llc : unit =
  let open Stdlib.Format in
  let get_node = Hashtbl.find_exn info.nodes in
  let rec pp_ll ppf c : unit =
    match c with
    | Low_level.Noop -> ()
    | Seq (c1, c2) ->
        (* Note: no separator. Filter out some entries known to not generate code to avoid whitespace. *)
        fprintf ppf "@[<v 0>%a@]" (pp_print_list pp_ll)
          (List.filter [ c1; c2 ] ~f:(function
            | Noop -> false
            | Zero_out ptr -> not Low_level.(get_node traced_store ptr).zero_initialized
            | _ -> true))
    | For_loop { index = i; from_; to_; body; trace_it = _ } ->
        fprintf ppf "@[<2>for (unsigned int@ %a = %d;@ %a <= %d;@ ++%a) {@ %a@]@ }@," pp_index i from_
          pp_index i to_ pp_index i pp_ll body
    | Zero_out array ->
        if Hashtbl.mem info.nodes array then
          failwith
            ("exec_as_cuda: Non-initialization zeroing-out NOT IMPLEMENTED YET: " ^ Sexp.to_string_hum
            @@ [%sexp_of: Tn.t] array);
        let traced = Low_level.(get_node traced_store array) in
        assert traced.zero_initialized
        (* The initialization will be emitted by get_array. *)
    | Set { tn; idcs; llv; debug } ->
        let ident = info.get_ident tn in
        let node = get_node tn in
        let loop_f = pp_float tn.prec in
        let loop_debug_f = debug_float tn.prec in
        let num_closing_braces = pp_top_locals ppf llv in
        (* No idea why adding any cut hint at the end of the assign line breaks formatting! *)
        fprintf ppf "@[<2>%s[@,%a] =@ %a;@]@ " ident pp_array_offset (idcs, node.dims) loop_f llv;
        (if Utils.settings.debug_log_from_routines then
           let v_code, v_idcs = loop_debug_f llv in
           let pp_args =
             pp_print_list @@ fun ppf -> function
             | `Accessor idx ->
                 pp_comma ppf ();
                 pp_array_offset ppf idx
             | `Value v ->
                 pp_comma ppf ();
                 pp_print_string ppf v
           in
           let offset = (idcs, node.dims) in
           let debug_line = "# " ^ String.substr_replace_all debug ~pattern:"\n" ~with_:"$" ^ "\\n" in
           fprintf ppf
             "@ @[<2>if @[<2>(threadIdx.x == 0 && blockIdx.x == 0@]) {@ printf(\"%%d: %s\", log_id);@ \
              printf(@[<h>\"%%d: %s[%%u] = %%f = %s\\n\"@], log_id,@ %a,@ %s[%a]%a);@ @]}"
             debug_line ident v_code pp_array_offset offset ident pp_array_offset offset pp_args v_idcs);
        for _ = 1 to num_closing_braces do
          fprintf ppf "@]@ }@,"
        done
    | Comment message ->
        if Utils.settings.debug_log_from_routines then
          fprintf ppf
            "@[<2>if @[<2>(threadIdx.x == 0 && blockIdx.x == 0@]) {@ printf(@[<h>\"%%d: COMMENT: %s\\n\", \
             log_id@]);@ @]}"
            (String.substr_replace_all ~pattern:"%" ~with_:"%%" message)
        else fprintf ppf "/* %s */@ " message
    | Staged_compilation callback -> callback ()
    | Set_local (Low_level.{ scope_id; tn = { prec; _ } }, value) ->
        let num_closing_braces = pp_top_locals ppf value in
        fprintf ppf "@[<2>v%d =@ %a;@]" scope_id (pp_float prec) value;
        for _ = 1 to num_closing_braces do
          fprintf ppf "@]@ }@,"
        done
  and pp_top_locals ppf (vcomp : Low_level.float_t) : int =
    match vcomp with
    | Local_scope { id = { scope_id = i; tn = { prec; _ } }; body; orig_indices = _ } ->
        let num_typ = Ops.cuda_typ_of_prec prec in
        (* Arrays are initialized to 0 by default. However, there is typically an explicit initialization for
           virtual nodes. *)
        fprintf ppf "@[<2>{@ %s v%d = 0;@ " num_typ i;
        pp_ll ppf body;
        pp_print_space ppf ();
        1
    | Get_local _ | Get_global _ | Get _ | Constant _ | Embed_index _ -> 0
    | Binop (Arg1, v1, _v2) -> pp_top_locals ppf v1
    | Binop (Arg2, _v1, v2) -> pp_top_locals ppf v2
    | Binop (_, v1, v2) -> pp_top_locals ppf v1 + pp_top_locals ppf v2
    | Unop (_, v) -> pp_top_locals ppf v
  and pp_float prec ppf value =
    let num_typ = Ops.cuda_typ_of_prec prec in
    let loop = pp_float prec in
    match value with
    | Local_scope { id; _ } ->
        (* Embedding of Local_scope is done by pp_top_locals. *)
        loop ppf @@ Get_local id
    | Get_local id ->
        let get_typ = Ops.cuda_typ_of_prec id.tn.prec in
        if not @@ String.equal num_typ get_typ then fprintf ppf "(%s)" num_typ;
        fprintf ppf "v%d" id.scope_id
    | Get_global _ -> failwith "Exec_as_cuda: Get_global / FFI NOT IMPLEMENTED YET"
    | Get (tn, idcs) ->
        let ident = info.get_ident tn in
        let node = get_node tn in
        fprintf ppf "@[<2>%s[%a@]]" ident pp_array_offset (idcs, node.dims)
    | Constant c -> fprintf ppf "(%f)" c
    | Embed_index idx ->
        if not @@ List.exists ~f:(String.equal num_typ) [ "int"; "size_t" ] then fprintf ppf "(%s)" num_typ;
        pp_index_axis ppf idx
    | Binop (Arg1, v1, _v2) -> loop ppf v1
    | Binop (Arg2, _v1, v2) -> loop ppf v2
    | Binop (op, v1, v2) ->
        let prefix, infix, postfix = Ops.binop_C_syntax prec op in
        fprintf ppf "@[<1>%s%a%s@ %a@]%s" prefix loop v1 infix loop v2 postfix
    | Unop (Identity, v) -> loop ppf v
    | Unop (Relu, v) ->
        (* FIXME: don't recompute v *)
        fprintf ppf "@[<1>(%a > 0.0 ?@ %a : 0.0@])" loop v loop v
  and debug_float prec (value : Low_level.float_t) : string * 'a list =
    let num_typ = Ops.cuda_typ_of_prec prec in
    let loop = debug_float prec in
    match value with
    | Local_scope { id; _ } ->
        (* Not printing the inlined definition: (1) code complexity; (2) don't overload the debug logs. *)
        loop @@ Get_local id
    | Get_local id ->
        let get_typ = Ops.cuda_typ_of_prec id.tn.prec in
        let v =
          (if not @@ String.equal num_typ get_typ then "(" ^ num_typ ^ ")" else "")
          ^ "v" ^ Int.to_string id.scope_id
        in
        (v ^ "{=%f}", [ `Value v ])
    | Get_global _ -> failwith "Exec_as_cuda: Get_global / FFI NOT IMPLEMENTED YET"
    | Get (tn, idcs) ->
        let ident = info.get_ident tn in
        let node = get_node tn in
        let v = sprintf "@[<2>%s[%s@]]" ident (array_offset_to_string (idcs, node.dims)) in
        (ident ^ "[%u]{=%f}", [ `Accessor (idcs, node.dims); `Value v ])
    | Constant c -> (Float.to_string c, [])
    | Embed_index (Fixed_idx i) -> (Int.to_string i, [])
    | Embed_index (Iterator s) -> (Indexing.symbol_ident s, [])
    | Binop (Arg1, v1, _v2) -> loop v1
    | Binop (Arg2, _v1, v2) -> loop v2
    | Binop (op, v1, v2) ->
        let prefix, infix, postfix = Ops.binop_C_syntax prec op in
        let v1, idcs1 = loop v1 in
        let v2, idcs2 = loop v2 in
        (String.concat [ prefix; v1; infix; " "; v2; postfix ], idcs1 @ idcs2)
    | Unop (Identity, v) -> loop v
    | Unop (Relu, v) ->
        let v, idcs = loop v in
        (String.concat [ "("; v; " > 0.0 ? "; v; " : 0.0)" ], idcs @ idcs)
  in
  pp_ll ppf llc

let%track_sexp compile_proc ~name ~get_ident ppf idx_params Low_level.{ traced_store; llc } =
  let open Stdlib.Format in
  let info =
    {
      nodes = Hashtbl.create (module Tn);
      used_tensors = Hash_set.create (module Tn);
      traced_store;
      get_ident;
    }
  in
  let arrays = Hash_set.to_list info.used_tensors in
  let params =
    List.filter_map arrays ~f:(fun tn ->
        let node = Hashtbl.find_exn info.nodes tn in
        if Utils.settings.with_debug_level > 0 then
          [%log "array-used:", (tn : Tn.t), Tn.label tn, (node.mem : mem_properties)];
        match node.mem with
        | Local_only -> None
        | From_context -> Some (Ops.cuda_typ_of_prec node.prec ^ " *" ^ info.get_ident tn)
        | Constant_from_host -> None)
  in
  let idx_params =
    List.map idx_params ~f:(fun { Indexing.static_symbol; _ } -> "int " ^ Indexing.symbol_ident static_symbol)
  in
  let log_id = if Utils.settings.debug_log_from_routines then [ "int log_id" ] else [] in
  fprintf ppf "extern \"C\" __global__ void %s(%a) {@." name (pp_print_list ~pp_sep:pp_comma pp_print_string)
  @@ log_id @ idx_params @ params;
  fprintf ppf "/* FIXME: single-threaded for now. */@.if (threadIdx.x != 0 || blockIdx.x != 0) { return; }@ ";
  let local_decls =
    List.filter_map arrays ~f:(fun tn ->
        let node = Hashtbl.find_exn info.nodes tn in
        match node.mem with
        | Local_only ->
            Some
              (Ops.cuda_typ_of_prec node.prec ^ " " ^ info.get_ident tn ^ "["
             ^ Int.to_string node.size_in_elems
              ^ if (Hashtbl.find_exn traced_store tn).zero_initialized then "] = {0};" else "];")
        | _ -> None)
  in
  fprintf ppf "/* Local declarations. */@.";
  pp_print_list ~pp_sep:pp_print_space pp_print_string ppf local_decls;
  fprintf ppf "/* Main logic. */@.";
  compile_main ~traced_store info ppf llc;
  fprintf ppf "@.}@.";
  info, params

let header_sep =
  let open Re in
  compile (seq [ str " "; opt any; str "="; str " " ])

let%track_sexp compile ~(name : string) ~opt_ctx_arrays bindings (compiled : Low_level.optimized) =
  (* if Option.is_none !root_ctx then initialize (); *)
  (* let opt_ctx_arrays = if Map.is_empty ctx_arrays then None else Some ctx_arrays in *)
  let get_ident = Low_level.get_ident_within_code [| compiled.llc |] in
  let idx_params = Indexing.bound_symbols bindings in
  let f_name, (info, _params) = Utils.pp_file ~name (fun ppf -> compile_proc ~name ~get_ident ppf idx_params) compiled in
  let log_fname = f_name ^ ".log" in
  let libname = f_name ^ ".so" in
  let cmdline = Printf.sprintf "cc %s -O%d -o %s --shared >> %s 2>&1" f_name !optimization_level libname log_fname in
  let rc = Stdlib.Sys.command cmdline in
  (* FIXME: don't busy wait *)
  while not @@ Stdlib.Sys.file_exists log_fname do
    ()
  done;
  let result = Dl.dlopen ~filename:libname ~flags:[] in
  { info; result; bindings; name; opt_ctx_arrays (* ; params *) }

let%track_sexp compile_batch ~names:_ ~opt_ctx_arrays bindings
    (_lowereds : Low_level.optimized option array) =
  (* if Option.is_none !root_ctx then initialize (); *)
    (*
   {[
  let funcs =
    Array.map2_exn names lowereds
      ~f:(Option.map2 ~f:(fun name lowered -> compile_proc ~name ~opt_ctx_arrays ctx bindings lowered))
  in
  (if Utils.settings.output_debug_files_in_run_directory then
     let f_name =
       String.(
         strip ~drop:(equal_char '_')
         @@ common_prefix (Array.to_list @@ Array.concat_map ~f:Option.to_array names))
       ^ "-c-debug.c"
     in
     Context.dump_to_file ctx ~update_locs:true f_name);
  let result = Context.compile ctx in
  Context.release ctx;
  Array.map2_exn names funcs
    ~f:
      (Option.map2 ~f:(fun name (info, ctx_arrays, params) ->
           let opt_ctx_arrays = if Map.is_empty ctx_arrays then None else Some ctx_arrays in
           { info; result; bindings; name; opt_ctx_arrays; params = List.map ~f:snd params }))
  ]} *)
failwith "NOT IMPLEMENTED YET"

let%track_sexp link_compiled (old_context : context) (code : procedure) : context * _ * _ * string =
  let label : string = old_context.label in
  let name : string = code.name in
  let arrays : Ndarray.t Base.Map.M(Tn).t =
    match code with
    | { opt_ctx_arrays = Some arrays; _ } -> arrays
    | { params; _ } ->
        List.fold params ~init:old_context.arrays ~f:(fun ctx_arrays -> function
          | Param_ptr tn ->
              let f = function
                | Some arr -> arr
                | None ->
                    Ndarray.create_array tn.Tn.prec ~dims:(Lazy.force tn.dims)
                    @@ Constant_fill { values = [| 0. |]; strict = false }
              in
              Map.update ctx_arrays tn ~f
          | _ -> ctx_arrays)
  in
  let context = { label; arrays; result = Some code.result } in
  let log_file_name = [%string "debug-%{label}-%{code.name}.log"] in
  let run_variadic =
    [%log_level
      Nothing;
      let rec link :
            'a 'b 'idcs.
            'idcs Indexing.bindings ->
            param_source list ->
            ('a -> 'b) Ctypes.fn ->
            ('a -> 'b, 'idcs, 'p1, 'p2) Indexing.variadic =
       fun (type a b idcs) (binds : idcs Indexing.bindings) params (cs : (a -> b) Ctypes.fn) ->
        match (binds, params) with
        | Empty, [] -> Indexing.Result (Result.code code.result name cs)
        | Bind _, [] -> invalid_arg "C_backend.link: too few static index params"
        | Bind (_, bs), Static_idx _ :: ps -> Param_idx (ref 0, link bs ps Ctypes.(int @-> cs))
        | Empty, Static_idx _ :: _ -> invalid_arg "C_backend.link: too many static index params"
        | bs, Log_file_name :: ps -> Param_1 (ref (Some log_file_name), link bs ps Ctypes.(string @-> cs))
        | bs, Param_ptr tn :: ps ->
            let nd = match Map.find arrays tn with Some nd -> nd | None -> assert false in
            (* let f ba = Ctypes.bigarray_start Ctypes_static.Genarray ba in let c_ptr = Ndarray.(map { f }
               nd) in *)
            let c_ptr = Ndarray.get_voidptr nd in
            Param_2 (ref (Some c_ptr), link bs ps Ctypes.(ptr void @-> cs))
      in
      (* Folding by [link] above reverses the input order. Important: [code.bindings] are traversed in the
         wrong order but that's OK because [link] only uses them to check the number of indices. *)
      link code.bindings (List.rev code.params) Ctypes.(void @-> returning void)]
  in
  let%diagn_rt_sexp work () : unit =
    [%log_result name];
    Indexing.apply run_variadic ();
    if Utils.settings.debug_log_from_routines then (
      Utils.log_trace_tree _debug_runtime (Stdio.In_channel.read_lines log_file_name);
      Stdlib.Sys.remove log_file_name)
  in
  ( context,
    Indexing.lowered_bindings code.bindings run_variadic,
    Tn.{ description = "executes " ^ code.name ^ " on " ^ context.label; work },
    name )

let from_host ?rt (context : context) (tn : Tn.t) : unit =
  Option.iter (Map.find context.arrays tn) ~f:(fun c_arr ->
      match tn.Tn.array with
      | (lazy (Some h_arr)) ->
          Ndarray.map2 { f2 = Ndarray.A.blit } h_arr c_arr;
          if Utils.settings.with_debug_level > 0 then
            let module Debug_runtime =
              (val Option.value_or_thunk rt ~default:(fun () ->
                       (module Debug_runtime : Minidebug_runtime.Debug_runtime)))
            in
            [%diagn_sexp
              [%log_entry
                "from_host " ^ Tn.get_debug_name tn;
                [%log "copied", Tn.label tn, Tn.name tn, "from host"];
                if Utils.settings.with_debug_level > 1 then
                  [%log_printbox
                    let indices = Array.init (Array.length @@ Lazy.force tn.dims) ~f:(fun i -> i - 5) in
                    Ndarray.render_array ~indices c_arr]]]
      | (lazy None) ->
          [%diagn_sexp
            [%log_entry
              "from_host empty " ^ Tn.get_debug_name tn;
              [%log "nothing to copy", Tn.label tn, Tn.name tn, "from host"]]];
          ())

let to_host ?rt (context : context) (tn : Tn.t) : unit =
  Option.iter (Map.find context.arrays tn) ~f:(fun c_arr ->
      match tn.Tn.array with
      | (lazy (Some h_arr)) ->
          Ndarray.map2 { f2 = Ndarray.A.blit } c_arr h_arr;
          if Utils.settings.with_debug_level > 0 then
            let module Debug_runtime =
              (val Option.value_or_thunk rt ~default:(fun () ->
                       (module Debug_runtime : Minidebug_runtime.Debug_runtime)))
            in
            [%diagn_sexp
              [%log_entry
                "to_host " ^ Tn.get_debug_name tn;
                [%log "copied", Tn.label tn, Tn.name tn, "to host"];
                if Utils.settings.with_debug_level > 1 then
                  [%log_printbox
                    let indices = Array.init (Array.length @@ Lazy.force tn.dims) ~f:(fun i -> i - 5) in
                    Ndarray.render_array ~indices h_arr]]]
      | (lazy None) ->
          [%diagn_sexp
            [%log_entry
              "to_host empty " ^ Tn.get_debug_name tn;
              [%log "nothing to copy", Tn.label tn, Tn.name tn, "to host"]]];
          ())

let device_to_device ?(rt : (module Minidebug_runtime.Debug_runtime) option) tn ~into_merge_buffer ~dst ~src =
  Option.iter (Map.find src.arrays tn) ~f:(fun s_arr ->
      Option.iter (Map.find dst.arrays tn) ~f:(fun d_arr ->
          if into_merge_buffer then failwith "NOT IMPLEMENTED YET"
          else Ndarray.map2 { f2 = Ndarray.A.blit } s_arr d_arr;
          if Utils.settings.with_debug_level > 0 then
            let module Debug_runtime =
              (val Option.value_or_thunk rt ~default:(fun () -> (module Debug_runtime)))
            in
            [%diagn_sexp
              [%log_entry
                "device_to_device " ^ Tn.get_debug_name tn;
                [%log
                  "copied",
                    Tn.label tn,
                    Tn.name tn,
                    "using merge buffer",
                    (into_merge_buffer : bool),
                    "destination",
                    dst.label,
                    "source",
                    src.label];
                if Utils.settings.with_debug_level > 1 then
                  [%log_printbox
                    let indices = Array.init (Array.length @@ Lazy.force tn.dims) ~f:(fun i -> i - 5) in
                    Ndarray.render_array ~indices d_arr]]]))

let physical_merge_buffers = false
