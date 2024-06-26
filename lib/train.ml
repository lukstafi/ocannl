open Base
module Tn = Arrayjit.Tnode
module Nd = Arrayjit.Ndarray
module NTDSL = Operation.NTDSL
module Asgns = Arrayjit.Assignments
module Idx = Arrayjit.Indexing
module Utils = Arrayjit.Utils
module Rand = Arrayjit.Rand.Lib

module type Backend_type = Arrayjit.Backends.Backend

module Debug_runtime = Arrayjit.Utils.Debug_runtime

[%%global_debug_log_level Nothing]
[%%global_debug_log_level_from_env_var "OCANNL_LOG_LEVEL"]

module CDSL = struct
  let single = Arrayjit.Ops.single
  let double = Arrayjit.Ops.double
  let virtualize_settings = Arrayjit.Low_level.virtualize_settings

  let enable_all_debugs ?(debug_logs = false) ?(hosted_only = true) () =
    Utils.settings.with_debug_level <- max 1 @@ Utils.settings.with_debug_level;
    Utils.settings.output_debug_files_in_run_directory <- true;
    if hosted_only then virtualize_settings.enable_device_only <- false;
    if debug_logs then Utils.settings.debug_log_from_routines <- true

  let disable_all_debugs ?(restore_defaults = false) () =
    Utils.settings.debug_log_from_routines <- false;
    Utils.settings.with_debug_level <- 0;
    Utils.settings.output_debug_files_in_run_directory <- false;
    if restore_defaults then virtualize_settings.enable_device_only <- true
end

module IDX = struct
  let empty = Idx.Empty
  let get_static_symbol = Idx.get_static_symbol
  let find_exn = Idx.find_exn
end

let debug_rt = (module Debug_runtime : Minidebug_runtime.Debug_runtime)
let run jitted = Tn.run debug_rt jitted.Arrayjit.Backend_types.schedule

(** Reinitializes a backend selected via a global [backend] flag. *)
let fresh_backend ?backend_name ?(config = Arrayjit.Backend_types.Physical_devices_only) () =
  let module B = Arrayjit.Backends in
  let module BT = Arrayjit.Backend_types in
  let backend =
    match
      Option.value_or_thunk backend_name ~default:(fun () ->
          Arrayjit.Utils.get_global_arg ~arg_name:"backend" ~default:"cc")
      |> String.lowercase
    with
    | "cc" -> (module B.Cc_backend : B.Backend)
    | "gccjit" -> (module B.Gccjit_backend : B.Backend)
    | "cuda" -> (module B.Cuda_backend : B.Backend)
    | backend -> invalid_arg [%string "Train.fresh_backend: unknown backend %{backend}"]
  in
  B.reinitialize backend config;
  backend

let is_param t =
  match t with { Tensor.children = []; diff = Some _; _ } -> not @@ Tn.known_not_param t.value | _ -> false

let get_params t =
  let rec loop accu { Tensor.subtensor = t; _ } =
    List.fold t.children ~init:(if is_param t then Set.add accu t else accu) ~f:loop
  in
  loop (Set.empty (module Tensor)) { subtensor = t; embedded = true }

let save_params t =
  let file_name =
    Option.value_or_thunk ~default:(fun () -> invalid_arg "Train.save_params: root tensor is not named")
    @@ Tn.ident_label t.Tensor.value
  in
  let with_name p =
    let v = p.Tensor.value in
    ( v,
      Option.value_or_thunk ~default:(fun () ->
          invalid_arg @@ "Train.save_params: parameter is not named: " ^ Tn.name v ^ " " ^ Tn.label v)
      @@ Tn.ident_label v )
  in
  let with_names = get_params t |> Set.elements |> List.map ~f:with_name in
  let out_file = Npy.Npz.open_out file_name in
  List.iter with_names ~f:(fun (v, name) ->
      let f arr = Npy.Npz.write out_file name arr in
      Nd.map { f } @@ Option.value_exn ~here:[%here] @@ Lazy.force v.array)

let restore_params t =
  let file_name =
    Option.value_or_thunk ~default:(fun () -> invalid_arg "Train.restore_params: root tensor is not named")
    @@ Tn.ident_label t.Tensor.value
  in
  let with_name p =
    let v = p.Tensor.value in
    ( v,
      Option.value_or_thunk ~default:(fun () ->
          invalid_arg @@ "Train.restore_params: parameter is not named: " ^ Tn.name v ^ " " ^ Tn.label v)
      @@ Tn.ident_label v )
  in
  let with_names = get_params t |> Set.elements |> List.map ~f:with_name in
  let in_file = Npy.Npz.open_in file_name in
  List.iter with_names ~f:(fun (v, name) ->
      let f arr = Npy.Npz.restore in_file name arr in
      Nd.map { f } @@ Option.value_exn ~here:[%here] @@ Lazy.force v.array)

let set_on_host memtype (a : Tn.t) = Tn.update_memory_mode a (Hosted memtype) 27
let set_materialized (a : Tn.t) = Tn.update_memory_mode a Materialized 28

let set_hosted (a : Tn.t) =
  if Tn.known_constant a then Tn.update_memory_mode a (Hosted Constant) 41
  else Tn.update_memory_mode a (Hosted Changed_on_devices) 41

let label_suffix label =
  Option.value ~default:"unknown"
  @@ List.find ~f:(String.for_all ~f:(fun c -> Char.is_alphanum c || equal_char '_' c))
  @@ List.rev label

(** Sets the tensor's value as "fully on host", returns the tensor's forward code with a label-derived
    comment. *)
let forward ?(disable_rootness_check = false) t =
  let fwd = if disable_rootness_check then t.Tensor.forward else Tensor.consume_forward_code t in
  set_hosted t.Tensor.value;
  let label = label_suffix t.Tensor.value.label in
  Asgns.Block_comment (label ^ " fwd", fwd)

type updaten = {
  loss : Tensor.t;
  label : string;
  params : (Tensor.t, Tensor.comparator_witness) Base.Set.t;
  fwd_bprop : Asgns.t;
}

(** Returns the tensor's forward, zeroing gradients, and backprop code wrapped with label-derived comments.
    Sets the tensor's value as "fully on host". If [setup_for_parallel] is true (false by default), sets the
    parameters and their gradients as "non-local" (on-device). *)
let grad_update ?(disable_rootness_check = false) ?(setup_for_parallel = false) loss =
  set_hosted loss.Tensor.value;
  let params = get_params loss in
  if setup_for_parallel then
    Set.iter params ~f:(fun p -> set_materialized (Option.value_exn ~here:[%here] p.diff).grad);
  let label = label_suffix loss.value.label in
  let fwd = if disable_rootness_check then loss.Tensor.forward else Tensor.consume_forward_code loss in
  let fwd_bprop =
    match loss.Tensor.diff with
    | Some diff ->
        let zero_grads, bprop =
          if disable_rootness_check then (diff.zero_grads, diff.backprop)
          else Tensor.consume_backprop_code loss
        in
        (* Note: the %cd syntax for [loss.grad] does not modify roots. *)
        let%cd init_grad = loss.grad =: 1 in
        Asgns.(
          Block_comment
            ( label ^ " gradient update",
              sequential
                [
                  Block_comment (label ^ " fwd", fwd);
                  Block_comment (label ^ " zero grads", zero_grads);
                  init_grad;
                  Block_comment (label ^ " bprop", bprop);
                ] ))
    | None -> raise @@ Tensor.Session_error ("Train.grad_update: tensor is not differentiable", Some loss)
  in
  { loss; label; params; fwd_bprop }

(** See: https://github.com/tinygrad/tinygrad/blob/master/tinygrad/nn/optim.py *)
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

let sgd_update ~learning_rate ?momentum ?weight_decay ?nesterov l =
  let code =
    l.params |> Set.to_list
    |> List.map ~f:(sgd_one ~learning_rate ?momentum ?weight_decay ?nesterov)
    |> Asgns.sequential
  in
  Asgns.Block_comment (l.label ^ " sgd update", code)

(** All and only bindings with associated ranges are iterated, with the binding's initial value lost. Bindings
    without ranges remain at their initial values. *)
let%track_sexp sequential_loop ~f lowered_bindings =
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
  loop lowered_bindings

(** Distributes iterated indices to workers in a round-robin fashion. All and only bindings with associated
    ranges are iterated, with the binding's initial value lost. Bindings without ranges remain at their
    initial values. [sync] is called after each round of calling all workers, and at the end if needed, with
    the number of workers called during the round. *)
let%track_sexp round_robin fs parallel_jitbs jitbs ~sync : unit =
  let num_devices : int = Array.length fs in
  assert (Array.length parallel_jitbs = num_devices);
  let pos = ref 0 in
  let rec loop = function
    | [] ->
        fs.(!pos % num_devices) ();
        Int.incr pos;
        if !pos % num_devices = 0 then sync num_devices
    | ({ Idx.static_range = None; static_symbol = _ }, _) :: more -> loop more
    | (({ Idx.static_range = Some range; static_symbol = _ } as s), idx)
      :: ({ Idx.static_range = None; static_symbol = _ }, _)
      :: more
    | (({ Idx.static_range = Some range; static_symbol = _ } as s), idx) :: more ->
        for i = 0 to range - 1 do
          idx := i;
          if List.is_empty more then Idx.find_exn parallel_jitbs.(!pos % num_devices) s := i
          else Array.iter parallel_jitbs ~f:(fun jb -> Idx.find_exn jb s := i);
          loop more
        done
  in
  loop jitbs;
  if !pos % num_devices <> 0 then sync (!pos % num_devices)

let%track_sexp round_robin_dry_run ~num_devices jitbs ~dry_sync : unit =
  let pos = ref 0 in
  let rec loop = function
    | [] ->
        Int.incr pos;
        if !pos % num_devices = 0 then dry_sync num_devices
    | ({ Idx.static_range = None; static_symbol = _ }, _) :: more -> loop more
    | ({ Idx.static_range = Some range; static_symbol = _ }, idx)
      :: ({ Idx.static_range = None; static_symbol = _ }, _)
      :: more
    | ({ Idx.static_range = Some range; static_symbol = _ }, idx) :: more ->
        for i = 0 to range - 1 do
          idx := i;
          loop more
        done
  in
  loop jitbs;
  if !pos % num_devices <> 0 then dry_sync (!pos % num_devices)

let set_virtual (a : Tn.t) = Tn.update_memory_mode a Virtual 29

let every_non_literal_on_host =
  Tensor.iter_embedded_arrays ~f:(fun a ->
      if Tn.mode_is_unspecified a && not (Tn.known_constant a) then set_hosted a)

let%debug_sexp all_host_to_device (type context) (module Backend : Backend_type with type context = context)
    context =
  let f tn = ignore (Backend.from_host context tn : bool) in
  Tensor.iter_embedded_arrays ~f

let%debug_sexp all_device_to_host (type context) (module Backend : Backend_type with type context = context)
    context =
  let f tn = ignore (Backend.to_host context tn : bool) in
  Tensor.iter_embedded_arrays ~f

(** Executes the jitted code and copies arrays embedded in the given tenosor from and to host, synchronizes
    before copying to host. If [looping] is provided, loops over bindings and executes the given function
    inside the loop after a run. All and only bindings with associated ranges are iterated, with the binding's
    initial value lost. Bindings without ranges remain at their initial values. *)
let%track_sexp sync_run ?looping (type context) (module Backend : Backend_type with type context = context)
    (routine : Backend.routine) t =
  all_host_to_device (module Backend) routine.context t;
  (match looping with
  | None -> Tn.run debug_rt routine.schedule
  | Some then_ ->
      let f () =
        Tn.run debug_rt routine.schedule;
        then_ ()
      in
      sequential_loop ~f routine.bindings);
  all_device_to_host (module Backend) routine.context t;
  Backend.await @@ Backend.get_ctx_device routine.context

module Lazy = Utils.Lazy

(** Performs one optimization step, potentially in parallel (if [grad_updates] are compiled for different
    devices). All jitted code must have the same bindings. Iterates over bindings with ranges, calling one of
    [grad_updates] in a round-robin fashion, and performs the following synchronization each time all
    [grad_updates] have been called:

    1. merges all gradients into the device of [grad_updates.(0)], 2. calls [sgd_update], 3. copies all
    parameters from the [grad_updates.(0)] device to the other devices, if needed, 4. calls [post_sync] with
    the number of devices synced since the previous sync.

    All and only bindings with associated ranges are iterated, with the binding's initial value lost. Bindings
    without ranges remain at their initial values. *)
let%track_sexp parallel_update (type context) (module Backend : Backend_type with type context = context)
    ~(grad_updates : Backend.routine array) ~(sgd_update : Backend.routine) ~post_sync updaten : unit -> unit
    =
  assert (not @@ Array.is_empty grad_updates);
  let num_devices : int = Array.length grad_updates in
  let bindings : Idx.static_symbol list = List.map ~f:fst sgd_update.bindings in
  let occupancies = Array.init num_devices ~f:(fun _ -> Array.create ~len:num_devices false) in
  (* to_, from positions correspond to the contexts (and devices) of grad_updates at the position. *)
  let dry_merge ~from ~to_ = occupancies.(from).(to_) <- true in
  let dry_sync devices_to_sync = Arrayjit.Utils.parallel_merge dry_merge devices_to_sync in
  round_robin_dry_run ~num_devices sgd_update.bindings ~dry_sync;
  [%debug_notrace
    assert (
      Array.for_all grad_updates ~f:(fun upd ->
          [%equal: Idx.static_symbol list] bindings @@ List.map ~f:fst upd.bindings))];
  let all_params = Set.to_array updaten.params in
  let ctxs = [%debug_notrace Array.map grad_updates ~f:(fun upd -> upd.context)] in
  let occupancy ~name:_ ~src_n = Array.exists ~f:Fn.id occupancies.(src_n) in
  let grad_merges =
    Array.map all_params ~f:(fun p ->
        [%cd
          ~~("merging gradient of" p);
          p.grad =+ p.grad.merge])
  in
  let grad_merges_to =
    Array.map ctxs ~f:(fun ctx ->
        snd @@ Backend.link_batch ctx @@ Backend.compile_batch ~shared:true ~occupancy Idx.Empty grad_merges)
  in
  (* We can cache scheduling, because merging and copying does not depend on static indexing. *)
  let loss_merge =
    Backend.(
      link sgd_update.context
      @@ compile Idx.Empty
           [%cd
             ~~("merging" updaten.loss);
             updaten.loss.value =+ updaten.loss.value.merge])
  in
  (* FIXME: need to iterate over params in the outer loop. *)
  let merge_grads ~(from : int) ~(to_ : int) : unit =
    (* FIXME: do we need to sync already? *)
    Backend.(await @@ get_ctx_device ctxs.(from));
    Array.iteri all_params ~f:(fun i p ->
        let grad_merge = Option.value_exn ~here:[%here] grad_merges_to.(to_).(i) in
        assert (
          Backend.device_to_device (Option.value_exn ~here:[%here] p.diff).grad ~into_merge_buffer:Copy
            ~dst:grad_merge.context ~src:ctxs.(from));
        (Tn.run debug_rt grad_merge.schedule : unit))
  in
  let merge_loss ~src =
    assert (Backend.device_to_device updaten.loss.value ~into_merge_buffer:Copy ~dst:loss_merge.context ~src);
    Tn.run debug_rt loss_merge.schedule
  in
  (* FIXME: missing backcopy. *)
  let needed_on_host = ref @@ Set.empty (module Tn) in
  let%track_sexp sync (devices_to_sync : int) : unit =
    Arrayjit.Utils.parallel_merge merge_grads devices_to_sync;
    Tn.run debug_rt sgd_update.schedule;
    (* We need to wait, because copying happens on other devices. *)
    Array.iteri ctxs ~f:(fun i src -> if i <> 0 then merge_loss ~src);
    Set.iter !needed_on_host ~f:(fun p -> assert (Backend.to_host sgd_update.context p));
    Backend.(await @@ get_ctx_device sgd_update.context);
    (* We will need to update params on all devices! Not only the ones that computed gradients. *)
    for to_ = 1 to num_devices - 1 do
      Array.iter all_params ~f:(fun p ->
          assert (
            Backend.device_to_device p.value ~into_merge_buffer:No ~dst:ctxs.(to_) ~src:sgd_update.context))
    done;
    post_sync ~num_synced_devices:devices_to_sync
  in
  let lowered_bindings = [%debug_notrace Array.map grad_updates ~f:(fun upd -> upd.bindings)] in
  let fs = [%debug_notrace Array.map grad_updates ~f:(fun upd () -> Tn.run debug_rt upd.schedule)] in
  fun () -> round_robin fs lowered_bindings sgd_update.bindings ~sync

let debug_name t = Tn.(debug_name ~id:t.Tensor.value.id ~label:t.value.label)

let get_all_suggested_devices (type device) ?max_num_devices
    (backend : (module Backend_type with type device = device)) : device array =
  let max_num_devices = Option.value max_num_devices ~default:Int.max_value_30_bits in
  let module Backend = (val backend : Backend_type with type device = device) in
  let num_physical = min max_num_devices @@ Backend.num_physical_devices () in
  let devices = Array.init num_physical ~f:(fun ordinal -> Backend.get_device ~ordinal) in
  Array.folding_mapi devices ~init:0 ~f:(fun ordinal num_collected physical ->
      let remaining_physical = num_physical - ordinal - 1 in
      let max_current = Backend.suggested_num_virtual_devices physical in
      let take_current = min max_current @@ (max_num_devices - remaining_physical) in
      ( num_collected + take_current,
        Array.init take_current ~f:(fun _subordinal -> Backend.new_virtual_device physical) ))
  |> Array.concat_map ~f:Fn.id

let example_train_loop ?(disable_rootness_check = false) ~seed ~batch_size ~init_lr ?lr_schedule
    ?max_num_devices ~data_len ~epochs ~inputs ~outputs ~model ~loss_fn ~weight_decay ?per_batch_callback
    ?per_epoch_callback (backend : (module Backend_type)) () =
  let module TDSL = Operation.TDSL in
  let module NTDSL = Operation.NTDSL in
  Rand.init seed;
  let module Backend = (val backend : Backend_type) in
  let devices = get_all_suggested_devices ?max_num_devices (module Backend) in
  let num_devices = Array.length devices in
  let minibatch_size = batch_size / num_devices in
  let n_batches = data_len / minibatch_size in
  let inputs = inputs ~b:[ n_batches; minibatch_size ] in
  let outputs = outputs ~b:[ n_batches; minibatch_size ] in
  let steps = epochs * n_batches in
  Utils.settings.fixed_state_for_init <- Some seed;
  let batch_n, bindings = IDX.get_static_symbol ~static_range:n_batches IDX.empty in
  let step_n, bindings = IDX.get_static_symbol bindings in
  let%op input = inputs @| batch_n in
  let%op expectation = outputs @| batch_n in
  let batch_losses = ref [] in
  let epoch_losses = ref [] in
  let learning_rates = ref [] in
  let%op loss_tensor = loss_fn ~output:(model input) ~expectation in
  let%op scalar_loss = (loss_tensor ++ "...|... => 0") /. !..batch_size in
  let update = grad_update ~disable_rootness_check ~setup_for_parallel:true scalar_loss in
  (* Define learning_rate after scalar_loss is compiled, to not trigger rootness sanitizer. *)
  let%op learning_rate =
    match lr_schedule with
    | None -> !.init_lr *. ((2 *. !..steps) - !@step_n) /. !..steps
    | Some schedule -> schedule ~batch_n ~step_n
  in
  set_hosted learning_rate.value;
  let sgd = sgd_update ~learning_rate ~weight_decay update in
  let contexts = Array.map devices ~f:Backend.init in
  let grad_update = Backend.compile ~shared:true bindings update.fwd_bprop in
  let grad_updates = Array.map contexts ~f:(fun ctx -> Backend.link ctx grad_update) in
  let sgd_update = Backend.(link grad_updates.(0).context @@ compile bindings sgd) in
  all_host_to_device (module Backend) sgd_update.context scalar_loss;
  all_host_to_device (module Backend) sgd_update.context learning_rate;
  let open Operation.At in
  let epoch_loss = ref 0. in
  let step_ref = IDX.find_exn sgd_update.bindings step_n in
  let batch_ref = IDX.find_exn sgd_update.bindings batch_n in
  let update =
    parallel_update
      (module Backend)
      ~grad_updates ~sgd_update update
      ~post_sync:(fun ~num_synced_devices ->
        step_ref := !step_ref + num_synced_devices;
        assert (Backend.to_host sgd_update.context learning_rate.value);
        (* scalar_loss is not in the sgd_update context. *)
        assert (Backend.to_host grad_updates.(0).context scalar_loss.value);
        Backend.(await @@ get_ctx_device grad_updates.(0).context);
        let batch_loss = scalar_loss.@[0] in
        epoch_loss := !epoch_loss +. batch_loss;
        batch_losses := batch_loss :: !batch_losses;
        Option.iter per_batch_callback ~f:(fun f ->
            f ~at_batch:!batch_ref ~at_step:!step_ref ~learning_rate:learning_rate.@[0] ~batch_loss
              ~epoch_loss:!epoch_loss))
  in
  for epoch = 0 to epochs - 1 do
    epoch_loss := 0.;
    update ();
    learning_rates := learning_rate.@[0] :: !learning_rates;
    epoch_losses := !epoch_loss :: !epoch_losses;
    Option.iter per_epoch_callback ~f:(fun f ->
        f ~at_step:!step_ref ~at_epoch:epoch ~learning_rate:learning_rate.@[0] ~epoch_loss:!epoch_loss)
  done;
  let%op model_result = model "infer" in
  let infer_fwd =
    if disable_rootness_check then model_result.Tensor.forward else Tensor.consume_forward_code model_result
  in
  set_on_host Volatile model_result.Tensor.value;
  (* By using sgd_update.context here, maybe we don't need to copy the parameters back to the host. *)
  let routine =
    Backend.(
      link sgd_update.context @@ compile IDX.empty @@ Block_comment (debug_name model_result, infer_fwd))
  in
  let infer_callback values =
    Tensor.set_values infer values;
    (* For the gccjit backend, infer is only on host, not on device. For cuda, this will be needed. *)
    assert (Backend.from_host routine.context infer.value);
    run routine;
    assert (Backend.to_host routine.context model_result.value);
    Backend.await devices.(0);
    Tensor.get_values model_result
  in
  (* Note: infer_callback is significantly less efficient than using the model via arrayjit. *)
  (inputs, outputs, model_result, infer_callback, !batch_losses, !epoch_losses, !learning_rates)

let%track_sexp forward_and_forget ?(disable_rootness_check = false) (type context)
    (module Backend : Backend_type with type context = context) ctx ?(bindings = IDX.empty) t =
  let routine = Backend.(link ctx @@ compile bindings @@ forward ~disable_rootness_check t) in
  if not disable_rootness_check then Tensor.remove_bprop_root t;
  sync_run (module Backend) routine t
