open Base
module LA = Arrayjit.Lazy_array
module NTDSL = Operation.NTDSL
module Asgns = Arrayjit.Assignments
module Idx = Arrayjit.Indexing

module type Backend_type = Arrayjit.Backends.Backend

module Debug_runtime = Arrayjit.Utils.Debug_runtime

(** Reinitializes a backend selected via a global [backend] flag. *)
let fresh_backend ?backend_name ?(verbose = true) () =
  let open Arrayjit.Backends in
  let backend =
    match
      Option.value_or_thunk backend_name ~default:(fun () ->
          Arrayjit.Utils.get_global_arg ~verbose ~arg_name:"backend" ~default:"gccjit")
      |> String.lowercase
    with
    | "gccjit" -> (module Gccjit_backend : Backend)
    | "cuda" -> (module Cuda_backend : Backend)
    | backend -> invalid_arg [%string "Train.fresh_backend: unknown backend %{backend}"]
  in
  reinitialize backend;
  backend

let literal_heuristic (a : LA.t) =
  try
    ignore (Float.of_string (List.hd_exn a.label) : float);
    true
  with _ -> false

let is_param t =
  match t with { Tensor.children = []; diff = Some _; _ } -> not @@ literal_heuristic t.value | _ -> false

let params t =
  let rec loop accu { Tensor.subtensor = t; _ } =
    List.fold t.children ~init:(if is_param t then Set.add accu t else accu) ~f:loop
  in
  loop (Set.empty (module Tensor)) { subtensor = t; embedded = true }

let set_on_host (a : LA.t) =
  if LA.is_true a.virtual_ then
    raise
    @@ Arrayjit.Ndarray.User_error
         [%string "Train.set_on_host: array #%{a.id#Int} %{LA.label a} is already virtual"];
  if Option.is_none a.virtual_ then a.virtual_ <- Some (false, 27);
  if LA.is_true a.device_only then
    raise
    @@ Arrayjit.Ndarray.User_error
         [%string "Train.set_on_host: array #%{a.id#Int} %{LA.label a} is already device-only"];
  a.device_only <- Some (false, 28)

(** Sets the tensor's value as "fully on host",
    returns the tensor's forward code with a label-derived comment. *)
let forward t =
  set_on_host t.Tensor.value;
  let label = Option.value ~default:"tensor" @@ List.last t.Tensor.value.label in
  Asgns.Block_comment (label ^ " fwd", t.forward)

(** Sets the tensor's value as "fully on host", returns the tensor's forward, zeroing gradients, and
    backprop code wrapped with label-derived comments. *)
let grad_update l =
  set_on_host l.Tensor.value;
  match l.Tensor.diff with
  | Some diff ->
      let%cd init_grad = l.grad =: 1 in
      let label = Option.value ~default:"tensor" @@ List.last l.value.label in
      Asgns.(
        Block_comment
          ( label ^ " gradient update",
            sequential
              [
                Block_comment (label ^ " fwd", l.forward);
                Block_comment (label ^ " zero grads", diff.zero_grads);
                init_grad;
                Block_comment (label ^ " bprop", diff.backprop);
              ] ))
  | None -> raise @@ Tensor.Session_error ("Train.backprop: tensor is not differentiable", Some l)

let label_suffix label = Option.value ~default:"unknown" @@ List.last label

(** See: {!https://github.com/tinygrad/tinygrad/blob/master/tinygrad/nn/optim.py}. *)
let sgd_one ~learning_rate ?(momentum = 0.0) ?(weight_decay = 0.0) ?(nesterov = false) p =
  if not @@ is_param p then raise @@ Tensor.Session_error ("Train.sgd_one: not a parameter", Some p);
  let pg = NTDSL.term ~label:("sgd_delta" :: p.value.label) () in
  let b = NTDSL.term ~label:("sgd_momentum" :: p.value.label) () in
  Asgns.Block_comment
    ( label_suffix p.value.label ^ " param sgd step",
      [%cd
        pg =: p.grad + (!.weight_decay *. p);
        if Float.(momentum > 0.0) then (
          b =: (!.momentum *. b) + pg;
          if nesterov then pg =+ !.momentum *. b else pg =: b);
        p =- learning_rate *. pg] )

let sgd_update ~learning_rate ?momentum ?weight_decay ?nesterov t =
  let code =
    params t |> Set.to_list
    |> List.map ~f:(sgd_one ~learning_rate ?momentum ?weight_decay ?nesterov)
    |> Asgns.sequential
  in
  Asgns.Block_comment (label_suffix t.value.label ^ " sgd update", code)

(** All and only bindings with associated ranges are iterated, with the binding's initial value lost.
    Bindings without ranges remain at their initial values. *)
let sequential_loop ~f jitted_bindings =
  let rec loop = function
    | [] -> f ()
    | ({ Idx.static_range = None; static_symbol = _ }, _) :: more -> loop more
    | ({ Idx.static_range = Some range; static_symbol = _ }, idx) :: more ->
        let old_idx = !idx in
        for i = 0 to range - 1 do
          idx := i;
          loop more
        done;
        idx := old_idx
  in
  loop jitted_bindings

(** Distributes iterated indices to workers in a round-robin fashion. All and only bindings with
    associated ranges are iterated, with the binding's initial value lost.
    Bindings without ranges remain at their initial values. [sync] is called after each round of calling
    all workers, and at the end if needed, with the number of workers called during the round. *)
let round_robin fs jitted_bindings bindings ~sync =
  let num_devices = Array.length fs in
  assert (Array.length jitted_bindings = num_devices);
  let pos = ref 0 in
  let rec loop = function
    | [] ->
        fs.(!pos % num_devices) ();
        Int.incr pos;
        if !pos % num_devices = 0 then sync num_devices
    | { Idx.static_range = None; static_symbol = _ } :: more -> loop more
    | ({ Idx.static_range = Some range; static_symbol = _ } as s)
      :: { Idx.static_range = None; static_symbol = _ }
      :: more
    | ({ Idx.static_range = Some range; static_symbol = _ } as s) :: more ->
        for i = 0 to range - 1 do
          if List.is_empty more then Idx.find_exn jitted_bindings.(!pos % num_devices) s := i
          else Array.iter jitted_bindings ~f:(fun jb -> Idx.find_exn jb s := i);
          loop more
        done
  in
  loop bindings;
  if !pos % num_devices <> 0 then sync (!pos % num_devices)

let set_virtual (a : LA.t) =
  if LA.is_false a.virtual_ then
    raise
    @@ Arrayjit.Ndarray.User_error
         [%string "Train.set_virtual: array #%{a.id#Int} %{LA.label a} is already non-virtual"];
  if Option.is_none a.virtual_ then a.virtual_ <- Some (true, 29)

let every_non_literal_on_host =
  Tensor.iter_embedded_arrays ~f:(fun a -> if not @@ literal_heuristic a then set_on_host a)

let all_host_to_device ?(verbose = false) (type context)
    (module Backend : Backend_type with type context = context) (context : context) =
  Tensor.iter_embedded_arrays ~f:(fun a ->
      let b = Backend.from_host context a in
      if verbose && b then
        Stdio.printf "Train.all_device_to_host: copied array %s (%s) from host to device %d.\n%!" (LA.name a)
          (LA.label a)
          (Backend.get_ctx_device context |> Backend.to_ordinal))

let all_device_to_host ?(verbose = false) (type context)
    (module Backend : Backend_type with type context = context) (context : context) =
  Tensor.iter_embedded_arrays ~f:(fun a ->
      let b = Backend.to_host context a in
      if verbose && b then
        Stdio.printf "Train.all_device_to_host: copied array %s (%s) from device %d to host.\n%!" (LA.name a)
          (LA.label a)
          (Backend.get_ctx_device context |> Backend.to_ordinal))

(** Executes the jitted code and copies arrays embedded in the given tenosor from and to host,
    synchronizes before copying to host. If [looping] is provided, loops over bindings and executes
    the given function inside the loop after a run. All and only bindings with associated ranges
    are iterated, with the binding's initial value lost. Bindings without ranges remain at their
    initial values. *)
let sync_run ?verbose ?looping (type context) (module Backend : Backend_type with type context = context)
    (jitted : Backend.jitted) t =
  all_host_to_device ?verbose (module Backend) jitted.context t;
  (match looping with
  | None -> jitted.run ()
  | Some then_ ->
      let f () =
        jitted.run ();
        then_ ()
      in
      sequential_loop ~f jitted.bindings);
  Backend.await @@ Backend.get_ctx_device jitted.context;
  all_device_to_host ?verbose (module Backend) jitted.context t

(** Performes one optimization step, potentially in parallel (if [grad_updates] are compiled for different
    devices). All jitted code must have the same bindings. Iterates over bindings with ranges, calling
    one of [grad_updates] in a round-robin fashion, and performs the following synchronization each time
    all [grad_updates] have been called: merges all gradients into the device of [grad_updates.(0)],
    calls [sgd_update], and copies all parameters from the [grad_updates.(0)] device to the other devices.

    All and only bindings with associated ranges are iterated, with the binding's initial value lost.
    Bindings without ranges remain at their initial values. *)
let parallel_update (type context) (module Backend : Backend_type with type context = context)
    ~(grad_updates : Backend.jitted array) ~(sgd_update : Backend.jitted) ~post_sync t =
  assert (not @@ Array.is_empty grad_updates);
  let num_devices = Array.length grad_updates in
  let bindings = List.map ~f:fst sgd_update.bindings in
  assert (
    Array.for_all grad_updates ~f:(fun upd ->
        [%equal: Idx.static_symbol list] bindings @@ List.map ~f:fst upd.bindings));
  let all_params = Set.to_list @@ params t in
  let param_vals = List.map all_params ~f:(fun t -> t.value) in
  let param_grads = List.filter_map all_params ~f:(fun t -> Option.map t.diff ~f:(fun d -> d.grad)) in
  let ctxs = Array.map grad_updates ~f:(fun upd -> upd.context) in
  let merges =
    Array.init (num_devices - 1) ~f:(fun to_ ->
        Array.init (num_devices - to_ (* - 1 ? *)) ~f:(fun delta ->
            let from = to_ + delta + 1 in
            List.filter_map param_grads ~f:(fun p ->
                Backend.merge ~name_suffix:"grad_merge" p ~dst:ctxs.(to_) ~accum:Arrayjit.Ops.Add
                  ~src:ctxs.(from))))
  in
  let merge ~from ~to_ = List.iter merges.(to_).(to_ - from - 1) ~f:(fun jitted -> jitted.run ()) in
  in
  (* let copy ~from ~to_ = List.iter copies.(to_).(from - to_ - 1) ~f:(fun jitted -> jitted.run ()) in *)
  let sync devices_to_sync =
    Arrayjit.Utils.parallel_merge merge devices_to_sync;
    sgd_update.run ();
    for from = 1 to devices_to_sync - 1 do
      List.iter copies.(from - 1) ~f:(fun jitted -> jitted.run ())
    done;
    post_sync ()
  in
  let jitted_bindings = Array.map grad_updates ~f:(fun upd -> upd.bindings) in
  let fs = Array.map grad_updates ~f:(fun upd -> upd.run) in
  round_robin fs jitted_bindings bindings ~sync
