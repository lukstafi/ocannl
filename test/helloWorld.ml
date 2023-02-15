open Base
open Ocannl

let%expect_test "Hello World" =
  Stdio.printf "Hello World!\n";
  [%expect {| Hello World! |}]

let%expect_test "Pointwise multiplication dims 1" =
  Random.init 0;
  (* "Hey" is inferred to be a scalar.
     Note the pointwise multiplication means "hey" does not have any input axes. *)
  let%ocannl y = 2 *. "hey" in
  let y_f = Network.unpack y in
  let open Operation.CLI in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Default @@ y_f;
  [%expect {|
    ┌────────────────────────────────┐
    │[4] (hey*2): shape 1 layout: 0:1│
    │┌┬───────┐                      │
    │││axis 0 │                      │
    │├┼───────┼───────────────────── │
    │││ 0.267 │                      │
    │└┴───────┘                      │
    └────────────────────────────────┘ |}]

let%expect_test "Matrix multiplication dims 1x1" =
  Operation.drop_session();
  Random.init 0;
  (* Hey is inferred to be a matrix. *)
  let%ocannl hey = "hey" in
  let%ocannl y = "q" 2.0 * hey + "p" 1.0 in
  let y_f = Network.unpack y in
  let hey_f = Network.unpack hey in
  let open Operation.CLI in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Default @@ hey_f;
  [%expect {|
    ┌─────────────────────────────────────────┐
    │[1] hey: shape q:1->p:1 layout: 0:1 x 1:1│
    │┌┬────────┐                              │
    │││0 @ p=0 │                              │
    │││axis q=1│                              │
    │├┼────────┼───────────────────────────── │
    │││ 0.134  │                              │
    │└┴────────┘                              │
    └─────────────────────────────────────────┘ |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ y_f;
  [%expect {|
    ┌──────────────────────────────────────┐
    │[5] (1+(hey*2)): shape p:1 layout: 0:1│
    │┌┬────────┐                           │
    │││axis p=0│                           │
    │├┼────────┼────────────────────────── │
    │││ 1.267  │                           │
    │└┴────────┘                           │
    └──────────────────────────────────────┘ |}]

let%expect_test "Print constant tensor" =
  Operation.drop_session();
  Random.init 0;
  let open Operation.CLI in
  let%ocannl hey = [1, 2, 3; 4, 5, 6] in
  let hey_f = Network.unpack hey in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ hey_f;
  [%expect {| [1.000, 2.000, 3.000; 4.000, 5.000, 6.000] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ hey_f;
  [%expect {|
    ┌────────────────────────────────────────────────────────────────────────────┐
    │[1] [1.000, 2.000, 3.000; 4.000, 5.000, 6.000]: shape 3->2 layout: 0:2 x 1:3│
    │┌┬─────────────────────┐                                                    │
    │││0 @ 0                │                                                    │
    │││axis 1               │                                                    │
    │├┼─────────────────────┼─────────────────────────────────────────────────── │
    │││ 1.000  2.000  3.000 │                                                    │
    │││ 4.000  5.000  6.000 │                                                    │
    │└┴─────────────────────┘                                                    │
    └────────────────────────────────────────────────────────────────────────────┘ |}];
  let%ocannl hoo = [| [1; 2; 3]; [4; 5; 6] |] in
  let hoo_f = Network.unpack hoo in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ hoo_f;
  [%expect {| [|[1.000; 2.000; 3.000]; [4.000; 5.000; 6.000]|] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ hoo_f;
  [%expect {|
    ┌─────────────────────────────────────────────────────────────────────────────────┐
    │[2] [|[1.000; 2.000; 3.000]; [4.000; 5.000; 6.000]|]: shape 2|3 layout: 0:2 x 1:3│
    │┌─────┬─────────────────────┐│┌─────┬─────────────────────┐                      │
    ││0 @ 0│axis 1               │││1 @ 0│axis 1               │                      │
    │├─────┼─────────────────────┤│├─────┼─────────────────────┼───────────────────── │
    ││     │ 1.000  2.000  3.000 │││     │ 4.000  5.000  6.000 │                      │
    │└─────┴─────────────────────┘│└─────┴─────────────────────┘                      │
    └─────────────────────────────┴───────────────────────────────────────────────────┘ |}];
  let%ocannl hey2 = [(1, 2, 3), (4, 5, 6); (7, 8, 9), (10, 11, 12); (13, 14, 15), (16, 17, 18);
                     (19, 20, 21), (22, 23, 24)] in
  let hey2_f = Network.unpack hey2 in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ hey2_f;
  [%expect {|
    [(1.000, 2.000, 3.000), (4.000, 5.000, 6.000);
      (7.000, 8.000, 9.000), (10.000, 11.000, 12.000);
      (13.000, 14.000, 15.000), (16.000, 17.000, 18.000);
      (19.000, 20.000, 21.000), (22.000, 23.000, 24.000)
    ] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ hey2_f;
  [%expect {|
    ┌──────────────────────────────────────────────────────────┐
    │[3] c4x2x3: shape 2,3->4 layout: 0:4 x 1:2 x 2:3          │
    │┌──────┬────────────────────────┬────────────────────────┐│
    ││      │0 @ 0                   │1 @ 0                   ││
    ││      │axis 2                  │axis 2                  ││
    │├──────┼────────────────────────┼────────────────────────┤│
    ││axis 1│ 1.000   2.000   3.000  │ 4.000   5.000   6.000  ││
    ││      │ 7.000   8.000   9.000  │ 10.000  11.000  12.000 ││
    ││      │ 13.000  14.000  15.000 │ 16.000  17.000  18.000 ││
    ││      │ 19.000  20.000  21.000 │ 22.000  23.000  24.000 ││
    │└──────┴────────────────────────┴────────────────────────┘│
    └──────────────────────────────────────────────────────────┘ |}];
  let%ocannl hoo2 = [| [[1; 2; 3]; [4; 5; 6]]; [[7; 8; 9]; [10; 11; 12]]; [[13; 14; 15]; [16; 17; 18]];
                       [[19; 20; 21]; [22; 23; 24]] |] in
  let hoo2_f = Network.unpack hoo2 in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ hoo2_f;
  [%expect {|
    [|[[1.000; 2.000; 3.000]; [4.000; 5.000; 6.000]];
      [[7.000; 8.000; 9.000]; [10.000; 11.000; 12.000]];
      [[13.000; 14.000; 15.000]; [16.000; 17.000; 18.000]];
      [[19.000; 20.000; 21.000]; [22.000; 23.000; 24.000]]
    |] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ hoo2_f;
  [%expect {| |}];
  let%ocannl heyhoo = [| [|[1; 2; 3]; [4; 5; 6]|]; [|[7; 8; 9]; [10; 11; 12]|]; [|[13; 14; 15]; [16; 17; 18]|];
                       [|[19; 20; 21]; [22; 23; 24]|] |] in
  let heyhoo_f = Network.unpack heyhoo in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ heyhoo_f;
  [%expect {|
    [|[|[1.000; 2.000; 3.000]; [4.000; 5.000; 6.000]|];
      [|[7.000; 8.000; 9.000]; [10.000; 11.000; 12.000]|];
      [|[13.000; 14.000; 15.000]; [16.000; 17.000; 18.000]|];
      [|[19.000; 20.000; 21.000]; [22.000; 23.000; 24.000]|]
    |] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ heyhoo_f;
  [%expect {| |}];
  let%ocannl heyhoo2 = [| [|[[1; 31]; [2; 32]; [3; 33]]; [[4; 34]; [5; 35]; [6; 36]]|];
                          [|[[7; 37]; [8; 38]; [9; 39]]; [[10; 40]; [11; 41]; [12; 42]]|];
                          [|[[13; 43]; [14; 44]; [15; 45]]; [[16; 46]; [17; 47]; [18; 48]]|];
                          [|[[19; 49]; [20; 50]; [21; 51]]; [[22; 52]; [23; 53]; [24; 54]]|] |] in
  let heyhoo2_f = Network.unpack heyhoo2 in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ heyhoo2_f;
  [%expect {|
    [|
      [|[[1.000; 31.000]; [2.000; 32.000]; [3.000; 33.000]];
        [[4.000; 34.000]; [5.000; 35.000]; [6.000; 36.000]]|];
      [|[[7.000; 37.000]; [8.000; 38.000]; [9.000; 39.000]];
        [[10.000; 40.000]; [11.000; 41.000]; [12.000; 42.000]]|];
      [|[[13.000; 43.000]; [14.000; 44.000]; [15.000; 45.000]];
        [[16.000; 46.000]; [17.000; 47.000]; [18.000; 48.000]]|];
      [|[[19.000; 49.000]; [20.000; 50.000]; [21.000; 51.000]];
        [[22.000; 52.000]; [23.000; 53.000]; [24.000; 54.000]]|]
    |] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ heyhoo2_f;
  [%expect {| |}];
  let%ocannl heyhoo3 = [| [| [[[1; 31]; [2; 32]; [3; 33]]; [[4; 34]; [5; 35]; [6; 36]]];
                             [[[7; 37]; [8; 38]; [9; 39]]; [[10; 40]; [11; 41]; [12; 42]]] |];
                          [| [[[13; 43]; [14; 44]; [15; 45]]; [[16; 46]; [17; 47]; [18; 48]]];
                             [[[19; 49]; [20; 50]; [21; 51]]; [[22; 52]; [23; 53]; [24; 54]]] |] |] in
  let heyhoo3_f = Network.unpack heyhoo3 in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ heyhoo3_f;
  [%expect {|
    [|
      [|
        [[[1.000; 31.000]; [2.000; 32.000]; [3.000; 33.000]];
          [[4.000; 34.000]; [5.000; 35.000]; [6.000; 36.000]]];
        [[[7.000; 37.000]; [8.000; 38.000]; [9.000; 39.000]];
          [[10.000; 40.000]; [11.000; 41.000]; [12.000; 42.000]]]|];
      [|
        [[[13.000; 43.000]; [14.000; 44.000]; [15.000; 45.000]];
          [[16.000; 46.000]; [17.000; 47.000]; [18.000; 48.000]]];
        [[[19.000; 49.000]; [20.000; 50.000]; [21.000; 51.000]];
          [[22.000; 52.000]; [23.000; 53.000]; [24.000; 54.000]]]|]
    |] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ heyhoo3_f;
  [%expect {| |}];
  let%ocannl heyhoo4 = [| [ [[1, 31; 2, 32; 3, 33]; [4, 34; 5, 35; 6, 36]];
                             [[7, 37; 8, 38; 9, 39]; [10, 40; 11, 41; 12, 42]] ];
                          [ [[13, 43; 14, 44; 15, 45]; [16, 46; 17, 47; 18, 48]];
                             [[19, 49; 20, 50; 21, 51]; [22, 52; 23, 53; 24, 54]] ] |] in
  let heyhoo4_f = Network.unpack heyhoo4 in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Inline @@ heyhoo4_f;
  [%expect {|
    [|
      [
        [[1.000, 31.000; 2.000, 32.000; 3.000, 33.000];
          [4.000, 34.000; 5.000, 35.000; 6.000, 36.000]];
        [[7.000, 37.000; 8.000, 38.000; 9.000, 39.000];
          [10.000, 40.000; 11.000, 41.000; 12.000, 42.000]]];
      [
        [[13.000, 43.000; 14.000, 44.000; 15.000, 45.000];
          [16.000, 46.000; 17.000, 47.000; 18.000, 48.000]];
        [[19.000, 49.000; 20.000, 50.000; 21.000, 51.000];
          [22.000, 52.000; 23.000, 53.000; 24.000, 54.000]]]
    |] |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ heyhoo4_f;
  [%expect {| |}]

let%expect_test "Matrix multiplication dims 2x3" =
  Operation.drop_session();
  Random.init 0;
  (* Hey is inferred to be a matrix. *)
  let%ocannl hey = "hey" in
  let%ocannl y = [2; 3] * hey + [4; 5; 6] in
  let y_f = Network.unpack y in
  let hey_f = Network.unpack hey in
  let open Operation.CLI in
  refresh_session ();
  print_formula ~with_code:false ~with_grad:false `Default @@ hey_f;
  [%expect {|
    ┌─────────────────────────────────────┐
    │[1] hey: shape 2->3 layout: 0:3 x 1:2│
    │┌┬──────────────┐                    │
    │││0 @ 0         │                    │
    │││axis 1        │                    │
    │├┼──────────────┼─────────────────── │
    │││ 0.134  0.868 │                    │
    │││ 0.449  0.268 │                    │
    │││ 0.036  0.587 │                    │
    │└┴──────────────┘                    │
    └─────────────────────────────────────┘ |}];
  print_formula ~with_code:false ~with_grad:false `Default @@ y_f;
  [%expect {|
    ┌─────────────────────────────────────────────────────────────────────┐
    │[5] ([4.000; 5.000; 6.000]+(hey*[2.000; 3.000])): shape 3 layout: 0:3│
    │┌┬─────────────────────┐                                             │
    │││axis 0               │                                             │
    │├┼─────────────────────┼──────────────────────────────────────────── │
    │││ 6.603  5.804  7.762 │                                             │
    │└┴─────────────────────┘                                             │
    └─────────────────────────────────────────────────────────────────────┘ |}]
