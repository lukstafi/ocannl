open Base
open Ocannl

let test_executor = `OCaml

let%expect_test "Hello World" =
  Stdio.printf "Hello World!\n";
  [%expect {| Hello World! |}]

let%expect_test "Pointwise multiplication dims 1" =
  (* let open Operation.CLI in *)
  let open Session.CLI in
  drop_session();
  Random.init 0;
  set_executor test_executor;
  (* "Hey" is inferred to be a scalar.
     Note the pointwise multiplication means "hey" does not have any input axes. *)
  let%nn_mo y = 2 *. "hey" in
  let y_f = Network.unpack y in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Default @@ y_f;
  [%expect {|
    ┌────────────────────────┐
    │[3] (hey*.2): shape 0:1 │
    │┌┬─────────┐            │
    │││axis 0   │            │
    │├┼─────────┼─────────── │
    │││ 2.67e-1 │            │
    │└┴─────────┘            │
    └────────────────────────┘ |}]

let%expect_test "Matrix multiplication dims 1x1" =
  (* let open Operation.CLI in *)
  let open Session.CLI in
  drop_session();
  Random.init 0;
  set_executor test_executor;
  (* Hey is inferred to be a matrix. *)
  let%nn_mo y = 'q' 2.0 * "hey" + 'p' 1.0 in
  let y_f = Network.unpack y in
  (* Punning for ["hey"] above introduced the [hey] identifier. *)
  let hey_f = Network.unpack hey in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Default @@ hey_f;
  [%expect {|
    ┌────────────────────────────┐
    │[1] hey: shape q=1:1->p=0:1 │
    │┌────────┬─────────┐        │
    ││        │axis q=1 │        │
    │├────────┼─────────┼─────── │
    ││axis p=0│ 1.34e-1 │        │
    │└────────┴─────────┘        │
    └────────────────────────────┘ |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ y_f;
  [%expect {|
    ┌─────────────────────────────┐
    │[5] (1+(hey*2)): shape p=0:1 │
    │┌┬─────────┐                 │
    │││axis p=0 │                 │
    │├┼─────────┼──────────────── │
    │││ 1.27e+0 │                 │
    │└┴─────────┘                 │
    └─────────────────────────────┘ |}]

let%expect_test "Print constant tensor" =
  Session.drop_session();
  Random.init 0;
  (* let open Operation.CLI in *)
  let open Session.CLI in
  let%nn_mo hey = [1, 2, 3; 4, 5, 6] in
  let hey_f = Network.unpack hey in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ hey_f;
  [%expect {| [1.00, 2.00, 3.00; 4.00, 5.00, 6.00] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ hey_f;
  [%expect {|
    ┌─────────────────────────────────────────────────────────┐
    │[1] [1.00, 2.00, 3.00; 4.00, 5.00, 6.00]: shape 1:3->0:2 │
    │┌──────┬───────────────────────────┐                     │
    ││      │axis 1                     │                     │
    │├──────┼───────────────────────────┼──────────────────── │
    ││axis 0│ 1.00e+0  2.00e+0  3.00e+0 │                     │
    ││      │ 4.00e+0  5.00e+0  6.00e+0 │                     │
    │└──────┴───────────────────────────┘                     │
    └─────────────────────────────────────────────────────────┘ |}];
  let%nn_mo hoo = [| [1; 2; 3]; [4; 5; 6] |] in
  let hoo_f = Network.unpack hoo in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ hoo_f;
  [%expect {| [|[1.00; 2.00; 3.00]; [4.00; 5.00; 6.00]|] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ hoo_f;
  [%expect {|
    ┌──────────────────────────────────────────────────────────────┐
    │[2] [|[1.00; 2.00; 3.00]; [4.00; 5.00; 6.00]|]: shape 0:2|1:3 │
    │┌──────┬───────────────────────────┐                          │
    ││      │axis 1                     │                          │
    │├──────┼───────────────────────────┼───────────────────────── │
    ││axis 0│ 1.00e+0  2.00e+0  3.00e+0 │                          │
    ││      │ 4.00e+0  5.00e+0  6.00e+0 │                          │
    │└──────┴───────────────────────────┘                          │
    └──────────────────────────────────────────────────────────────┘ |}];
  let%nn_mo hey2 = [(1, 2, 3), (4, 5, 6); (7, 8, 9), (10, 11, 12); (13, 14, 15), (16, 17, 18);
                     (19, 20, 21), (22, 23, 24)] in
  let hey2_f = Network.unpack hey2 in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ hey2_f;
  [%expect {|
    [(1.00, 2.00, 3.00), (4.00, 5.00, 6.00);
      (7.00, 8.00, 9.00), (10.00, 11.00, 12.00);
      (13.00, 14.00, 15.00), (16.00, 17.00, 18.00);
      (19.00, 20.00, 21.00), (22.00, 23.00, 24.00)
    ] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ hey2_f;
  [%expect {|
    ┌────────────────────────────────────────────────────────────────┐
    │[3] c4x2x3: shape 1:2,2:3->0:4                                  │
    │┌──────┬───────────────────────────┬───────────────────────────┐│
    ││      │0 @ 1                      │1 @ 1                      ││
    ││      │axis 2                     │axis 2                     ││
    │├──────┼───────────────────────────┼───────────────────────────┤│
    ││axis 0│ 1.00e+0  2.00e+0  3.00e+0 │ 4.00e+0  5.00e+0  6.00e+0 ││
    ││      │ 7.00e+0  8.00e+0  9.00e+0 │ 1.00e+1  1.10e+1  1.20e+1 ││
    ││      │ 1.30e+1  1.40e+1  1.50e+1 │ 1.60e+1  1.70e+1  1.80e+1 ││
    ││      │ 1.90e+1  2.00e+1  2.10e+1 │ 2.20e+1  2.30e+1  2.40e+1 ││
    │└──────┴───────────────────────────┴───────────────────────────┘│
    └────────────────────────────────────────────────────────────────┘ |}];
  let%nn_mo hoo2 = [| [[1; 2; 3]; [4; 5; 6]]; [[7; 8; 9]; [10; 11; 12]]; [[13; 14; 15]; [16; 17; 18]];
                       [[19; 20; 21]; [22; 23; 24]] |] in
  let hoo2_f = Network.unpack hoo2 in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ hoo2_f;
  [%expect {|
    [|[[1.00; 2.00; 3.00]; [4.00; 5.00; 6.00]];
      [[7.00; 8.00; 9.00]; [10.00; 11.00; 12.00]];
      [[13.00; 14.00; 15.00]; [16.00; 17.00; 18.00]];
      [[19.00; 20.00; 21.00]; [22.00; 23.00; 24.00]]
    |] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ hoo2_f;
  [%expect {|
    ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
    │[4] c4x2x3: shape 0:4|1:2,2:3                                                                                           │
    │┌──────┬───────────────────────────┬───────────────────────────┬───────────────────────────┬───────────────────────────┐│
    ││      │0 @ 0                      │1 @ 0                      │2 @ 0                      │3 @ 0                      ││
    ││      │axis 2                     │axis 2                     │axis 2                     │axis 2                     ││
    │├──────┼───────────────────────────┼───────────────────────────┼───────────────────────────┼───────────────────────────┤│
    ││axis 1│ 1.00e+0  2.00e+0  3.00e+0 │ 7.00e+0  8.00e+0  9.00e+0 │ 1.30e+1  1.40e+1  1.50e+1 │ 1.90e+1  2.00e+1  2.10e+1 ││
    ││      │ 4.00e+0  5.00e+0  6.00e+0 │ 1.00e+1  1.10e+1  1.20e+1 │ 1.60e+1  1.70e+1  1.80e+1 │ 2.20e+1  2.30e+1  2.40e+1 ││
    │└──────┴───────────────────────────┴───────────────────────────┴───────────────────────────┴───────────────────────────┘│
    └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘ |}];
  let%nn_mo heyhoo = [| [|[1; 2; 3]; [4; 5; 6]|]; [|[7; 8; 9]; [10; 11; 12]|]; [|[13; 14; 15]; [16; 17; 18]|];
                       [|[19; 20; 21]; [22; 23; 24]|] |] in
  let heyhoo_f = Network.unpack heyhoo in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ heyhoo_f;
  [%expect {|
    [|[|[1.00; 2.00; 3.00]; [4.00; 5.00; 6.00]|];
      [|[7.00; 8.00; 9.00]; [10.00; 11.00; 12.00]|];
      [|[13.00; 14.00; 15.00]; [16.00; 17.00; 18.00]|];
      [|[19.00; 20.00; 21.00]; [22.00; 23.00; 24.00]|]
    |] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ heyhoo_f;
  [%expect {|
    ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
    │[5] c4x2x3: shape 0:4,1:2|2:3                                                                                           │
    │┌──────┬───────────────────────────┬───────────────────────────┬───────────────────────────┬───────────────────────────┐│
    ││      │0 @ 0                      │1 @ 0                      │2 @ 0                      │3 @ 0                      ││
    ││      │axis 2                     │axis 2                     │axis 2                     │axis 2                     ││
    │├──────┼───────────────────────────┼───────────────────────────┼───────────────────────────┼───────────────────────────┤│
    ││axis 1│ 1.00e+0  2.00e+0  3.00e+0 │ 7.00e+0  8.00e+0  9.00e+0 │ 1.30e+1  1.40e+1  1.50e+1 │ 1.90e+1  2.00e+1  2.10e+1 ││
    ││      │ 4.00e+0  5.00e+0  6.00e+0 │ 1.00e+1  1.10e+1  1.20e+1 │ 1.60e+1  1.70e+1  1.80e+1 │ 2.20e+1  2.30e+1  2.40e+1 ││
    │└──────┴───────────────────────────┴───────────────────────────┴───────────────────────────┴───────────────────────────┘│
    └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘ |}];
  let%nn_mo heyhoo2 = [| [|[[1; 31]; [2; 32]; [3; 33]]; [[4; 34]; [5; 35]; [6; 36]]|];
                          [|[[7; 37]; [8; 38]; [9; 39]]; [[10; 40]; [11; 41]; [12; 42]]|];
                          [|[[13; 43]; [14; 44]; [15; 45]]; [[16; 46]; [17; 47]; [18; 48]]|];
                          [|[[19; 49]; [20; 50]; [21; 51]]; [[22; 52]; [23; 53]; [24; 54]]|] |] in
  let heyhoo2_f = Network.unpack heyhoo2 in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ heyhoo2_f;
  [%expect {|
    [|
      [|[[1.00; 31.00]; [2.00; 32.00]; [3.00; 33.00]];
        [[4.00; 34.00]; [5.00; 35.00]; [6.00; 36.00]]|];
      [|[[7.00; 37.00]; [8.00; 38.00]; [9.00; 39.00]];
        [[10.00; 40.00]; [11.00; 41.00]; [12.00; 42.00]]|];
      [|[[13.00; 43.00]; [14.00; 44.00]; [15.00; 45.00]];
        [[16.00; 46.00]; [17.00; 47.00]; [18.00; 48.00]]|];
      [|[[19.00; 49.00]; [20.00; 50.00]; [21.00; 51.00]];
        [[22.00; 52.00]; [23.00; 53.00]; [24.00; 54.00]]|]
    |] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ heyhoo2_f;
  [%expect {|
    ┌──────────────────────────────────────────────┐
    │[6] c4x2x3x2: shape 0:4,1:2|2:3,3:2           │
    │┌──────┬──────────────────┬──────────────────┐│
    ││      │0 @ 1             │1 @ 1             ││
    ││      │axis 3            │axis 3            ││
    │├──────┼──────────────────┼──────────────────┤│
    ││0 @ 0 │ 1.00e+0  3.10e+1 │ 4.00e+0  3.40e+1 ││
    ││axis 2│ 2.00e+0  3.20e+1 │ 5.00e+0  3.50e+1 ││
    ││      │ 3.00e+0  3.30e+1 │ 6.00e+0  3.60e+1 ││
    │├──────┼──────────────────┼──────────────────┤│
    ││1 @ 0 │ 7.00e+0  3.70e+1 │ 1.00e+1  4.00e+1 ││
    ││axis 2│ 8.00e+0  3.80e+1 │ 1.10e+1  4.10e+1 ││
    ││      │ 9.00e+0  3.90e+1 │ 1.20e+1  4.20e+1 ││
    │├──────┼──────────────────┼──────────────────┤│
    ││2 @ 0 │ 1.30e+1  4.30e+1 │ 1.60e+1  4.60e+1 ││
    ││axis 2│ 1.40e+1  4.40e+1 │ 1.70e+1  4.70e+1 ││
    ││      │ 1.50e+1  4.50e+1 │ 1.80e+1  4.80e+1 ││
    │├──────┼──────────────────┼──────────────────┤│
    ││3 @ 0 │ 1.90e+1  4.90e+1 │ 2.20e+1  5.20e+1 ││
    ││axis 2│ 2.00e+1  5.00e+1 │ 2.30e+1  5.30e+1 ││
    ││      │ 2.10e+1  5.10e+1 │ 2.40e+1  5.40e+1 ││
    │└──────┴──────────────────┴──────────────────┘│
    └──────────────────────────────────────────────┘ |}];
  let%nn_mo heyhoo3 = [| [| [[[1; 31]; [2; 32]; [3; 33]]; [[4; 34]; [5; 35]; [6; 36]]];
                             [[[7; 37]; [8; 38]; [9; 39]]; [[10; 40]; [11; 41]; [12; 42]]] |];
                          [| [[[13; 43]; [14; 44]; [15; 45]]; [[16; 46]; [17; 47]; [18; 48]]];
                             [[[19; 49]; [20; 50]; [21; 51]]; [[22; 52]; [23; 53]; [24; 54]]] |] |] in
  let heyhoo3_f = Network.unpack heyhoo3 in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ heyhoo3_f;
  [%expect {|
    [|
      [|
        [[[1.00; 31.00]; [2.00; 32.00]; [3.00; 33.00]];
          [[4.00; 34.00]; [5.00; 35.00]; [6.00; 36.00]]];
        [[[7.00; 37.00]; [8.00; 38.00]; [9.00; 39.00]];
          [[10.00; 40.00]; [11.00; 41.00]; [12.00; 42.00]]]|];
      [|
        [[[13.00; 43.00]; [14.00; 44.00]; [15.00; 45.00]];
          [[16.00; 46.00]; [17.00; 47.00]; [18.00; 48.00]]];
        [[[19.00; 49.00]; [20.00; 50.00]; [21.00; 51.00]];
          [[22.00; 52.00]; [23.00; 53.00]; [24.00; 54.00]]]|]
    |] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ heyhoo3_f;
  [%expect {|
    ┌──────────────────────────────────────────────┐
    │[7] c2x2x2x3x2: shape 0:2,1:2|2:2,3:3,4:2     │
    │┌──────┬──────────────────┬──────────────────┐│
    ││0 @ 0 │0 @ 2             │1 @ 2             ││
    ││      │axis 4            │axis 4            ││
    │├──────┼──────────────────┼──────────────────┤│
    ││0 @ 1 │ 1.00e+0  3.10e+1 │ 4.00e+0  3.40e+1 ││
    ││axis 3│ 2.00e+0  3.20e+1 │ 5.00e+0  3.50e+1 ││
    ││      │ 3.00e+0  3.30e+1 │ 6.00e+0  3.60e+1 ││
    │├──────┼──────────────────┼──────────────────┤│
    ││1 @ 1 │ 7.00e+0  3.70e+1 │ 1.00e+1  4.00e+1 ││
    ││axis 3│ 8.00e+0  3.80e+1 │ 1.10e+1  4.10e+1 ││
    ││      │ 9.00e+0  3.90e+1 │ 1.20e+1  4.20e+1 ││
    │└──────┴──────────────────┴──────────────────┘│
    ├──────────────────────────────────────────────┤
    │┌──────┬──────────────────┬──────────────────┐│
    ││1 @ 0 │0 @ 2             │1 @ 2             ││
    ││      │axis 4            │axis 4            ││
    │├──────┼──────────────────┼──────────────────┤│
    ││0 @ 1 │ 1.30e+1  4.30e+1 │ 1.60e+1  4.60e+1 ││
    ││axis 3│ 1.40e+1  4.40e+1 │ 1.70e+1  4.70e+1 ││
    ││      │ 1.50e+1  4.50e+1 │ 1.80e+1  4.80e+1 ││
    │├──────┼──────────────────┼──────────────────┤│
    ││1 @ 1 │ 1.90e+1  4.90e+1 │ 2.20e+1  5.20e+1 ││
    ││axis 3│ 2.00e+1  5.00e+1 │ 2.30e+1  5.30e+1 ││
    ││      │ 2.10e+1  5.10e+1 │ 2.40e+1  5.40e+1 ││
    │└──────┴──────────────────┴──────────────────┘│
    └──────────────────────────────────────────────┘ |}];
  let%nn_mo heyhoo4 = [| [ [[1, 31; 2, 32; 3, 33]; [4, 34; 5, 35; 6, 36]];
                             [[7, 37; 8, 38; 9, 39]; [10, 40; 11, 41; 12, 42]] ];
                          [ [[13, 43; 14, 44; 15, 45]; [16, 46; 17, 47; 18, 48]];
                             [[19, 49; 20, 50; 21, 51]; [22, 52; 23, 53; 24, 54]] ] |] in
  let heyhoo4_f = Network.unpack heyhoo4 in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ heyhoo4_f;
  [%expect {|
    [|
      [
        [[1.00, 31.00; 2.00, 32.00; 3.00, 33.00];
          [4.00, 34.00; 5.00, 35.00; 6.00, 36.00]];
        [[7.00, 37.00; 8.00, 38.00; 9.00, 39.00];
          [10.00, 40.00; 11.00, 41.00; 12.00, 42.00]]];
      [
        [[13.00, 43.00; 14.00, 44.00; 15.00, 45.00];
          [16.00, 46.00; 17.00, 47.00; 18.00, 48.00]];
        [[19.00, 49.00; 20.00, 50.00; 21.00, 51.00];
          [22.00, 52.00; 23.00, 53.00; 24.00, 54.00]]]
    |] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ heyhoo4_f;
  [%expect {|
    ┌──────────────────────────────────────────────┐
    │[8] c2x2x2x3x2: shape 0:2|4:2->1:2,2:2,3:3    │
    │┌──────┬──────────────────┬──────────────────┐│
    ││0 @ 0 │0 @ 2             │1 @ 2             ││
    ││      │axis 4            │axis 4            ││
    │├──────┼──────────────────┼──────────────────┤│
    ││0 @ 1 │ 1.00e+0  3.10e+1 │ 4.00e+0  3.40e+1 ││
    ││axis 3│ 2.00e+0  3.20e+1 │ 5.00e+0  3.50e+1 ││
    ││      │ 3.00e+0  3.30e+1 │ 6.00e+0  3.60e+1 ││
    │├──────┼──────────────────┼──────────────────┤│
    ││1 @ 1 │ 7.00e+0  3.70e+1 │ 1.00e+1  4.00e+1 ││
    ││axis 3│ 8.00e+0  3.80e+1 │ 1.10e+1  4.10e+1 ││
    ││      │ 9.00e+0  3.90e+1 │ 1.20e+1  4.20e+1 ││
    │└──────┴──────────────────┴──────────────────┘│
    ├──────────────────────────────────────────────┤
    │┌──────┬──────────────────┬──────────────────┐│
    ││1 @ 0 │0 @ 2             │1 @ 2             ││
    ││      │axis 4            │axis 4            ││
    │├──────┼──────────────────┼──────────────────┤│
    ││0 @ 1 │ 1.30e+1  4.30e+1 │ 1.60e+1  4.60e+1 ││
    ││axis 3│ 1.40e+1  4.40e+1 │ 1.70e+1  4.70e+1 ││
    ││      │ 1.50e+1  4.50e+1 │ 1.80e+1  4.80e+1 ││
    │├──────┼──────────────────┼──────────────────┤│
    ││1 @ 1 │ 1.90e+1  4.90e+1 │ 2.20e+1  5.20e+1 ││
    ││axis 3│ 2.00e+1  5.00e+1 │ 2.30e+1  5.30e+1 ││
    ││      │ 2.10e+1  5.10e+1 │ 2.40e+1  5.40e+1 ││
    │└──────┴──────────────────┴──────────────────┘│
    └──────────────────────────────────────────────┘ |}]

let%expect_test "Matrix multiplication dims 2x3" =
  (* let open Operation.CLI in *)
  let open Session.CLI in
  drop_session();
  Random.init 0;
  set_executor test_executor;
  (* Hey is inferred to be a matrix. *)
  let%nn_mo hey = "hey" in
  let%nn_mo y = [2; 3] * hey + [4; 5; 6] in
  let y_f = Network.unpack y in
  let hey_f = Network.unpack hey in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Default @@ hey_f;
  [%expect {|
    ┌───────────────────────────┐
    │[1] hey: shape 1:2->0:3    │
    │┌──────┬──────────────────┐│
    ││      │axis 1            ││
    │├──────┼──────────────────┤│
    ││axis 0│ 1.34e-1  8.68e-1 ││
    ││      │ 4.49e-1  2.68e-1 ││
    ││      │ 3.56e-2  5.87e-1 ││
    │└──────┴──────────────────┘│
    └───────────────────────────┘ |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ y_f;
  [%expect {|
    ┌───────────────────────────────────────────────────────┐
    │[5] ([4.00; 5.00; 6.00]+(hey*[2.00; 3.00])): shape 0:3 │
    │┌┬───────────────────────────┐                         │
    │││axis 0                     │                         │
    │├┼───────────────────────────┼──────────────────────── │
    │││ 6.60e+0  5.80e+0  7.76e+0 │                         │
    │└┴───────────────────────────┘                         │
    └───────────────────────────────────────────────────────┘ |}]

let%expect_test "Big matrix" =
  let open Operation.CLI in
  let open Session.CLI in
  drop_session();
  Random.init 0;
  set_executor test_executor;
  (* Hey is inferred to be a matrix. *)
  let hey = O.(!~ "hey") in
  let zero_to_twenty = range 20 in
  let y = O.(zero_to_twenty * hey + zero_to_twenty) in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline zero_to_twenty;
  [%expect {|
      [0.00; 1.00; 2.00; 3.00; 4.00; 5.00; 6.00; 7.00; 8.00; 9.00; 10.00; 11.00;
        12.00; 13.00; 14.00; 15.00; 16.00; 17.00; 18.00; 19.00; 20.00
      ] |}];
  print_formula ~with_code:false ~with_grad:false `Default zero_to_twenty;
  [%expect {|
      ┌────────────────────────────────────────────┐
      │[2] 0...20: shape 0:21                      │
      │┌┬─────────────────────────────────────────┐│
      │││axis 0                                   ││
      │├┼─────────────────────────────────────────┤│
      │││ 0.00e+0  1.00e+0  ...  1.90e+1  2.00e+1 ││
      │└┴─────────────────────────────────────────┘│
      └────────────────────────────────────────────┘ |}];
  print_formula ~with_code:false ~with_grad:false `Default hey;
  [%expect {|
      ┌──────────────────────────────────────────────────┐
      │[1] hey: shape 1:21->0:21                         │
      │┌──────┬─────────────────────────────────────────┐│
      ││      │axis 1                                   ││
      │├──────┼─────────────────────────────────────────┤│
      ││axis 0│ 1.34e-1  8.68e-1  ...  5.46e-1  4.70e-1 ││
      ││      │ 5.31e-1  4.31e-1  ...  9.64e-1  4.50e-2 ││
      ││      │ ...      ...      ...  ...      ...     ││
      ││      │ 3.78e-1  1.22e-1  ...  3.10e-1  4.93e-1 ││
      ││      │ 8.50e-1  4.69e-1  ...  6.16e-2  8.49e-1 ││
      │└──────┴─────────────────────────────────────────┘│
      └──────────────────────────────────────────────────┘ |}];
  print_formula ~with_code:false ~with_grad:false `Default y;
  [%expect {|
      ┌────────────────────────────────────────────┐
      │[4] (0...20+(hey*0...20)): shape 0:21       │
      │┌┬─────────────────────────────────────────┐│
      │││axis 0                                   ││
      │├┼─────────────────────────────────────────┤│
      │││ 9.39e+0  1.90e+0  ...  2.89e+1  3.70e+1 ││
      │└┴─────────────────────────────────────────┘│
      └────────────────────────────────────────────┘ |}]

let%expect_test "Very big tensor" =
    let open Session.CLI in
    drop_session();
    Random.init 0;
    let open Operation.CLI in
    set_executor test_executor;
    (* Hey is inferred to be a matrix. *)
    let hey = Network.return_term @@
      range_of_shape ~batch_dims:[7] ~input_dims:[9; 10; 11] ~output_dims:[13; 14] () in
    let%nn_mo hoo = (1 + 1) * hey - 10 in
    let hoo_f = Network.unpack hoo in
    refresh_session ();
    (* print_formula ~with_code:false ~with_grad:false `Inline hey;
    [%expect {| |}]; *)
    print_formula ~with_code:false ~with_grad:false `Default hoo_f;
    (* Disable line wrapping for viewing the output. In VSCode: `View: Toggle Word Wrap`. *)
    [%expect {|
      ┌───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
      │[9] ((r7x13x14x9x10x11*(1+1))+(10*.-1)): shape 0:7|1:13,2:14                                                                                                                           │
      │┌──────┬─────────────────────────────────────────┬─────────────────────────────────────────┬──────┬─────────────────────────────────────────┬─────────────────────────────────────────┐│
      ││      │0 @ 0                                    │1 @ 0                                    │~~~~~ │5 @ 0                                    │6 @ 0                                    ││
      ││      │axis 2                                   │axis 2                                   │axis 2│axis 2                                   │axis 2                                   ││
      │├──────┼─────────────────────────────────────────┼─────────────────────────────────────────┼──────┼─────────────────────────────────────────┼─────────────────────────────────────────┤│
      ││axis 1│ 1.97e+3  3.95e+3  ...  2.57e+4  2.77e+4 │ 3.62e+5  3.64e+5  ...  3.86e+5  3.88e+5 │ ...  │ 1.80e+6  1.81e+6  ...  1.83e+6  1.83e+6 │ 2.16e+6  2.17e+6  ...  2.19e+6  2.19e+6 ││
      ││      │ 2.97e+4  3.17e+4  ...  5.34e+4  5.54e+4 │ 3.90e+5  3.92e+5  ...  4.14e+5  4.16e+5 │      │ 1.83e+6  1.83e+6  ...  1.86e+6  1.86e+6 │ 2.19e+6  2.19e+6  ...  2.22e+6  2.22e+6 ││
      ││      │ ...      ...      ...  ...      ...     │ ...      ...      ...  ...      ...     │      │ ...      ...      ...  ...      ...     │ ...      ...      ...  ...      ...     ││
      ││      │ 3.07e+5  3.09e+5  ...  3.31e+5  3.33e+5 │ 6.67e+5  6.69e+5  ...  6.91e+5  6.93e+5 │      │ 2.11e+6  2.11e+6  ...  2.13e+6  2.13e+6 │ 2.47e+6  2.47e+6  ...  2.49e+6  2.49e+6 ││
      ││      │ 3.35e+5  3.37e+5  ...  3.58e+5  3.60e+5 │ 6.95e+5  6.97e+5  ...  7.19e+5  7.21e+5 │      │ 2.14e+6  2.14e+6  ...  2.16e+6  2.16e+6 │ 2.50e+6  2.50e+6  ...  2.52e+6  2.52e+6 ││
      │└──────┴─────────────────────────────────────────┴─────────────────────────────────────────┴──────┴─────────────────────────────────────────┴─────────────────────────────────────────┘│
      └───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘ |}]
