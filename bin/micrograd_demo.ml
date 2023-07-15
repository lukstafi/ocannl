open Base
open Ocannl
module FDSL = Operation.FDSL
module NFDSL = Operation.NFDSL
module CDSL = Code.CDSL
module SDSL = Session.SDSL

let () = SDSL.set_executor Cuda

let () =
  let open SDSL.O in
  SDSL.drop_all_sessions ();
  Code.with_debug := true;
  Code.keep_files_in_run_directory := true;
  Random.init 0;
  let len = 200 in
  let batch = 20 in
  let epochs = 50 in
  let noise () = Random.float_range (-0.1) 0.1 in
  let moons_flat =
    Array.concat_map (Array.create ~len ())
      ~f:
        Float.(
          fun () ->
            let i = Random.int len in
            let v = of_int i * pi / of_int len in
            let c = cos v and s = sin v in
            [| c + noise (); s + noise (); 1.0 - c + noise (); 0.5 - s + noise () |])
  in
  let moons_flat =
    FDSL.init_const ~l:"moons_flat" ~b:[ CDSL.frozen epochs; CDSL.dim batch ] ~o:[ CDSL.dim 2 ] moons_flat
  in
  let moons_classes = Array.init (len * 2) ~f:(fun i -> if i % 2 = 0 then 1. else -1.) in
  let moons_classes =
    FDSL.init_const ~l:"moons_classes" ~b:[ CDSL.frozen epochs; CDSL.dim batch ] ~o:[ CDSL.dim 1 ] moons_classes
  in
  let%nn_op mlp x = "b3" 1 + ("w3" * !/("b2" 16 + ("w2" * !/("b1" 16 + ("w1" * x))))) in
  let steps = epochs * 2 * len / batch in
  let%nn_dt session_step ~o:1 = n =+ 1 in
  let%nn_dt minus_lr ~o:1 = n =: -0.1 *. (!..steps - session_step) /. !..steps in
  SDSL.minus_learning_rate := Some minus_lr;
  let%nn_op moons_input = moons_flat @.| session_step in
  let%nn_op moons_class = moons_classes @.| session_step in
  let losses = ref [] in
  let log_losses = ref [] in
  let learning_rates = ref [] in
  let%nn_op margin_loss = !/(1 - (moons_class *. mlp moons_input)) in
  let%nn_op ssq w = (w **. 2) ++ "...|...->... => 0" in
  let reg_loss = List.map ~f:ssq [ w1; w2; w3; b1; b2; b3 ] |> List.reduce_exn ~f:FDSL.O.( + ) in
  let%nn_op total_loss = ((margin_loss ++ "...|... => 0") /. !..batch) + (0.0001 *. reg_loss) in
  SDSL.everything_on_host_or_inlined ();
  for _step = 1 to steps do
    SDSL.refresh_session ();
    learning_rates := ~-.(minus_lr.@[0]) :: !learning_rates;
    losses := total_loss.@[0] :: !losses;
    log_losses := Float.log total_loss.@[0] :: !log_losses
  done;
  Code.with_debug := false;
  Code.keep_files_in_run_directory := false;
  let points = SDSL.value_2d_points ~xdim:0 ~ydim:1 moons_flat in
  let classes = SDSL.value_1d_points ~xdim:0 moons_classes in
  let points1, points2 = Array.partitioni_tf points ~f:Float.(fun i _ -> classes.(i) > 0.) in
  SDSL.close_session ();
  let%nn_op point = [ 0; 0 ] in
  let mlp_result = mlp point in
  SDSL.refresh_session ~with_backprop:false ();
  let callback (x, y) =
    SDSL.set_values point [| x; y |];
    SDSL.refresh_session ~with_backprop:false ();
    Float.(mlp_result.@[0] >= 0.)
  in
  let plot_moons =
    let open PrintBox_utils in
    plot ~size:(120, 40) ~x_label:"ixes" ~y_label:"ygreks"
      [
        Scatterplot { points = points1; pixel = "#" };
        Scatterplot { points = points2; pixel = "%" };
        Boundary_map { pixel_false = "."; pixel_true = "*"; callback };
      ]
  in
  Stdio.printf "Half-moons scatterplot and decision boundary:\n%!";
  PrintBox_text.output Stdio.stdout plot_moons;
  Stdio.printf "Loss:\n%!";
  let plot_loss =
    let open PrintBox_utils in
    plot ~size:(120, 30) ~x_label:"step" ~y_label:"loss"
      [ Line_plot { points = Array.of_list_rev !losses; pixel = "-" } ]
  in
  PrintBox_text.output Stdio.stdout plot_loss;
  
  Stdio.printf "Log-loss, for better visibility:\n%!";
  let plot_loss =
    let open PrintBox_utils in
    plot ~size:(120, 30) ~x_label:"step" ~y_label:"log loss"
      [ Line_plot { points = Array.of_list_rev !log_losses; pixel = "-" } ]
  in
  PrintBox_text.output Stdio.stdout plot_loss;
  
  Stdio.printf "\nLearning rate:\n%!";
  let plot_lr =
    let open PrintBox_utils in
    plot ~size:(120, 30) ~x_label:"step" ~y_label:"learning rate"
      [ Line_plot { points = Array.of_list_rev !learning_rates; pixel = "-" } ]
  in
  PrintBox_text.output Stdio.stdout plot_lr
