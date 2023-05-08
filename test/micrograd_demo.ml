open Base
open Ocannl
module FDSL = Operation.FDSL
module NFDSL = Operation.NFDSL
module CDSL = Code.CDSL
module SDSL = Session.SDSL

let () = SDSL.set_executor Gccjit

let%expect_test "Micrograd README basic example" =
  SDSL.drop_all_sessions ();
  Random.init 0;
  let%nn_op c = "a" (* [ -4 ] *) + "b" (* [ 2 ] *) in
  let%nn_op d = (a *. b) + (b **. 3) in
  let%nn_op c = c + c + 1 in
  let%nn_op c = c + 1 + c + ~-a in
  let%nn_op d = d + (d *. 2) + !/(b + a) in
  let%nn_op d = d + (3 *. d) + !/(b - a) in
  let%nn_op e = c - d in
  let%nn_op f = e *. e in
  let%nn_op g = f /. 2 in
  let%nn_op g = g + (10. /. f) in
  SDSL.refresh_session ();
  SDSL.print_formula ~with_code:false ~with_grad:false `Default @@ g;
  [%expect
    {|
    ┌──────────────────────┐
    │[49]: g <+> shape 0:1 │
    │┌┬─────────┐          │
    │││axis 0   │          │
    │├┼─────────┼───────── │
    │││ 2.47e+1 │          │
    │└┴─────────┘          │
    └──────────────────────┘ |}];
  SDSL.print_formula ~with_code:false ~with_grad:true `Default @@ a;
  [%expect
    {|
    ┌───────────────────┐
    │[1]: <a> shape 0:1 │
    │┌┬──────────┐      │
    │││axis 0    │      │
    │├┼──────────┼───── │
    │││ -4.00e+0 │      │
    │└┴──────────┘      │
    └───────────────────┘
    ┌─────────────────────────────┐
    │[1]: <a> shape 0:1  Gradient │
    │┌┬─────────┐                 │
    │││axis 0   │                 │
    │├┼─────────┼──────────────── │
    │││ 1.39e+2 │                 │
    │└┴─────────┘                 │
    └─────────────────────────────┘ |}];
  SDSL.print_formula ~with_code:false ~with_grad:true `Default @@ b;
  [%expect
    {|
    ┌───────────────────┐
    │[2]: <b> shape 0:1 │
    │┌┬─────────┐       │
    │││axis 0   │       │
    │├┼─────────┼────── │
    │││ 2.00e+0 │       │
    │└┴─────────┘       │
    └───────────────────┘
    ┌─────────────────────────────┐
    │[2]: <b> shape 0:1  Gradient │
    │┌┬─────────┐                 │
    │││axis 0   │                 │
    │├┼─────────┼──────────────── │
    │││ 6.46e+2 │                 │
    │└┴─────────┘                 │
    └─────────────────────────────┘ |}]

let%expect_test "Micrograd half-moons example" =
  let open SDSL.O in
  SDSL.drop_all_sessions ();
  Random.init 0;
  let len = 200 in
  let batch = 10 in
  let epochs = 40 in
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
  let moons_flat = FDSL.init_const ~l:"moons_flat" ~b:[ Dim epochs; Dim batch ] ~o:[ Dim 2 ] moons_flat in
  let moons_classes = Array.init (len * 2) ~f:(fun i -> if i % 2 = 0 then 1. else -1.) in
  let moons_classes = FDSL.init_const ~l:"moons_classes" ~b:[ Dim epochs; Dim batch ] ~o:[ Dim 1 ] moons_classes in
  let%nn_op mlp x = "b3" 1 + ("w3" * !/("b2" 16 + ("w2" * !/("b1" 16 + ("w1" * x))))) in
  let steps = epochs * 2 * len / batch in
  let%nn_dt session_step ~o:1 = n =+ 1 in
  let%nn_dt minus_lr ~o:1 = n =: -0.1 *. (!..steps - session_step) /. !..steps in
  SDSL.minus_learning_rate := Some minus_lr;
  let%nn_op moons_input = moons_flat @.| session_step in
  let%nn_op moons_class = moons_classes @.| session_step in
  let points1 = ref [] in
  let points2 = ref [] in
  let losses = ref [] in
  let log_losses = ref [] in
  let learning_rates = ref [] in
  let%nn_op margin_loss = !/(1 - (moons_class *. mlp moons_input)) in
  let%nn_op ssq w = (w **. 2) ++ "...|...->... => 0" in
  let reg_loss = List.map ~f:ssq [ w1; w2; w3; b1; b2; b3 ] |> List.reduce_exn ~f:FDSL.O.( + ) in
  let%nn_op total_loss = ((margin_loss ++ "...|... => 0") /. !..batch) + (0.0001 *. reg_loss) in
  for _step = 1 to steps do
    SDSL.refresh_session ();
    let points = SDSL.value_2d_points ~xdim:0 ~ydim:1 moons_input in
    let classes = SDSL.value_1d_points ~xdim:0 moons_class in
    let npoints1, npoints2 = Array.partitioni_tf points ~f:Float.(fun i _ -> classes.(i) > 0.) in
    points1 := npoints1 :: !points1;
    points2 := npoints2 :: !points2;
    learning_rates := ~-.(minus_lr.@[0]) :: !learning_rates;
    losses := total_loss.@[0] :: !losses;
    log_losses := Float.log total_loss.@[0] :: !log_losses
  done;
  SDSL.close_session ();
  (* FIMXE: *)
  let%nn_op point = (* [ 0; 0 ] *) "point" 2 in
  let mlp_result = mlp point in
  SDSL.refresh_session ();
  let callback (x, y) =
    SDSL.set_values point [| x; y |];
    SDSL.refresh_session ();
    Float.(mlp_result.@[0] >= 0.)
  in
  let plot_moons =
    let open PrintBox_utils in
    plot ~size:(120, 40) ~x_label:"ixes" ~y_label:"ygreks"
      [
        Scatterplot { points = Array.concat !points1; pixel = "#" };
        Scatterplot { points = Array.concat !points2; pixel = "%" };
        Boundary_map { pixel_false = "."; pixel_true = "*"; callback };
      ]
  in
  Stdio.printf "Half-moons scatterplot and decision boundary:\n%!";
  PrintBox_text.output Stdio.stdout plot_moons;
  [%expect
    {|
    Half-moons scatterplot and decision boundary:
     1.083e+0 │************************************#***********************************************************************************
              │**********************************#**#*******#*###**********************************************************************
              │*****************************************##***#**#**#*******************************************************************
              │***********************#**###**#******#*#####*#***###****##*************************************************************
              │***********************##**##***#****#*#******##********#***#***********************************************************
              │*************************#####*#***********#*#***####**#*****#*********************************************************.
              │********************#***#**************************#**#***#**#***#**************************************************....
              │**********#****#*##****#***#*******************************#**#***************************************************......
              │**************##*###*****************************************#****###*******************************************........
              │**************#*###*****************************************#*******#*****************************************..........
              │***********#*****************************...**********************##*#**************************************............
              │********#*****#***********************.........*******************#**#**##*#*******************************.............
              │******#***#************************...............***************#***#***********************************...............
              │*******#***##*******************.....................****************#***#******************************..........%.....
              │******#*##**#****************...........................****************##*****************************...............%.
              │****##*#*#****************..................%............**************#***#**#**********************.............%%...%
              │**#*####****************..............%..%%%..............*****************#************************.................%%.
    y         │**#**#*#*#************..................%...%..............****************#**#********************..............%......
    g         │##***##**************................%......................*************##*##*#*****************.......................
    r         │*******#*************..................%..%.%................************###**##****************....................%%%.
    e         │*********************.................%%.%%..%................*************####*#*************......................%...
    k         │***#****************...................%.%.%.%%................***********###**#*************................%.%........
    s         │********************..................%..%.%..%.................***********#****************.................%....%%%...
              │##*#***************......................%.%.....................***********##************....................%.%.%%....
              │*****##***********......................%.......%..................**********#***********...................%%%%%.%.%...
              │**##*#************......................%...%.......................*******************.........................%%......
              │#****************...........................%.........................*********#*****.........................%..%%.....
              │****************........................%..%............................***********........................%.....%......
              │****************............................%.%.%%%..%....................*******..............................%........
              │***************....................................%..........................*..........................%..%.%.........
              │***************..............................%%%%.................................................%.%...................
              │**************................................%.................................................%.%.%...%%%.............
              │*************.....................................%%%.....%..%..............................%.%.....%%.%.%..............
              │*************........................................%.%.%.%....................................%%.%%%..................
              │************............................................%....%..%%..%...............%%..%...............%...............
              │************..............................................%%.......%..%...%%...........%..%..%%%%.......................
              │***********................................................%....%...%.......%..%........%.%%....%.%.....................
              │**********...............................................%.....%%..%%.%%.%..%....%..%.%....%.%..........................
              │**********......................................................%%....%%%...%%%........%...%............................
     -5.946e-1│**********...........................................................%.......%..%.....%.................................
    ──────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
              │-1.071e+0                                                                                                       2.093e+0
              │                                                          ixes |}];
  Stdio.printf "Loss:\n%!";
  let plot_loss =
    let open PrintBox_utils in
    plot ~size:(120, 30) ~x_label:"step" ~y_label:"loss"
      [ Line_plot { points = Array.of_list_rev !losses; pixel = "-" } ]
  in
  PrintBox_text.output Stdio.stdout plot_loss;
  [%expect
    {|
    Loss:
     3.078e+1│-
             │
             │
             │
             │
             │
             │
             │
             │
             │
             │
             │
             │
    l        │
    o        │
    s        │
    s        │
             │
             │
             │
             │
             │-
             │
             │
             │
             │-
             │-
             │-
             │----
     1.312e-3│------------------------------------------------------------------------------------------------------------------------
    ─────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
             │0.000e+0                                                                                                        1.599e+3
             │                                                          step |}];
  Stdio.printf "Log-loss, for better visibility:\n%!";
  let plot_loss =
    let open PrintBox_utils in
    plot ~size:(120, 30) ~x_label:"step" ~y_label:"log loss"
      [ Line_plot { points = Array.of_list_rev !log_losses; pixel = "-" } ]
  in
  PrintBox_text.output Stdio.stdout plot_loss;
  [%expect
    {|
    Log-loss, for better visibility:
     3.427e+0 │-
              │
              │
              │
              │-
              │
              │-
              │-
              │ - -
              │-
              │----
    l         │ --- -- -- --  -
    o         │------------- -- -- -- -- -- -- -- --  -
    g         │ - -- ---------------------------------- --  -  -
              │- ------ -- -- -- -- -- -- -- -- ----------------
    l         │  -- -- ------------------ -- -- -- -- --------- -- -   -
    o         │  -------- -- -------- ----- --------- -- ----- --------
    s         │ -   -  -   -      -----  ----   - ------ -- ----- - -   --  -  -
    s         │ ---    -        -  -  -  -   - -  -  -- -- --- ----- -  -      -  -  -  -     -           -
              │         - -  --    -     -  -  -- -     --- -  - -     --  --     --    -  -     -  -  -     -  -  -  -  -  -  -  -  -
              │      -    -  -  -  -  -        -  -  -     -- ---  ---- - -  -        -       -
              │ - - -           -   - -- --       -  -     --   ---  --  -- --              -  -  -    --  -
              │     -                          -   -         -       --  -  -   --  --   -          --        -  -     -
              │    -   -   -     -        -          -        - --      - -  ---  -       -  -     -  -    -        -
              │   -  -            -  -       -      - - -       - -     -  -- -- -      -    -                -  -    -   -     -
              │          --   -             --       -         -      -       -            -    -            -      -     -  -
              │             -                          --          -       -     -   -                  --     -     -  -          -  -
              │                        -   -                - -       -  -    -     --          -   -  -                       --     -
              │              -                    -                         - -           -  -  -                      --  -  -
     -6.636e+0│ -- -- -------- - -- --- -- -- -----------------------------------------------------------------------------------------
    ──────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
              │0.000e+0                                                                                                        1.599e+3
              │                                                          step |}];
  Stdio.printf "\nLearning rate:\n%!";
  let plot_lr =
    let open PrintBox_utils in
    plot ~size:(120, 30) ~x_label:"step" ~y_label:"learning rate"
      [ Line_plot { points = Array.of_list_rev !learning_rates; pixel = "-" } ]
  in
  PrintBox_text.output Stdio.stdout plot_lr;
  [%expect
    {|
    Learning rate:
     9.994e-2│-
             │-----
             │    -----
             │        -----
             │            -----
             │                -----
             │                    -----
             │                        -----
    l        │                            ------
    e        │                                 -----
    a        │                                     -----
    r        │                                         -----
    n        │                                             -----
    i        │                                                 -----
    n        │                                                     -----
    g        │                                                         ------
             │                                                              -----
    r        │                                                                  -----
    a        │                                                                      -----
    t        │                                                                          -----
    e        │                                                                              -----
             │                                                                                  -----
             │                                                                                      -----
             │                                                                                           -----
             │                                                                                               -----
             │                                                                                                   -----
             │                                                                                                       -----
             │                                                                                                           -----
             │                                                                                                               -----
     0.000e+0│                                                                                                                   -----
    ─────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
             │0.000e+0                                                                                                        1.599e+3
             │                                                          step |}]
