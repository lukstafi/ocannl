open Base
open Ocannl
let y0 =
  let open! Network.O in
    let hey1 =
      Network.return_term (Operation.unconstrained_param ?init:None "hey1") in
    Network.apply
      (Network.apply (+)
         (Network.apply
            (Network.apply ( * )
               (Network.return_term (Operation.number (Float.of_int 2))))
            hey1)) (Network.return_term (Operation.number (Float.of_int 3)))
let y1 =
  let open! Network.O in
    let hey2 =
      Network.return_term (Operation.unconstrained_param ?init:None "hey2") in
    let x__ref = ref [] in
    let x = Network.return (Network.Placeholder x__ref) in
    let body =
      Network.apply
        (Network.apply (+)
           (Network.apply
              (Network.apply ( * )
                 (Network.return_term (Operation.number (Float.of_int 2))))
              hey2)) x in
    fun x ->
      x__ref := (x :: (!x__ref));
      (let result__ = Network.unpack body in
       x__ref := (List.tl_exn (!x__ref)); result__)
let y2 =
  let open! Network.O in
    let hey3 =
      Network.return_term (Operation.unconstrained_param ?init:None "hey3") in
    let x1__ref = ref [] in
    let x1 = Network.return (Network.Placeholder x1__ref) in
    let x2__ref = ref [] in
    let x2 = Network.return (Network.Placeholder x2__ref) in
    let body =
      Network.apply
        (Network.apply (+) (Network.apply (Network.apply ( * ) x1) hey3)) x2 in
    fun x1 ->
      fun x2 ->
        x1__ref := (x1 :: (!x1__ref));
        x2__ref := (x2 :: (!x2__ref));
        (let result__ = Network.unpack body in
         x1__ref := (List.tl_exn (!x1__ref));
         x2__ref := (List.tl_exn (!x2__ref));
         result__)
let a =
  let open! Network.O in
    Network.return_term
      (Operation.ndarray ~batch_dims:[] ~input_dims:[3] ~output_dims:
         [2]
         [|(Float.of_int 1);(Float.of_int 2);(Float.of_int 3);(Float.of_int 4);(
           Float.of_int 5);(Float.of_int 6)|])
let b =
  let open! Network.O in
    Network.return_term
      (Operation.ndarray ~batch_dims:[2] ~input_dims:[] ~output_dims:
         [2]
         [|(Float.of_int 7);(Float.of_int 8);(Float.of_int 9);(Float.of_int
                                                                 10)|])
let y =
  let open! Network.O in
    let hey4 =
      Network.return_term (Operation.unconstrained_param ?init:None "hey4") in
    Network.apply
      (Network.apply (+)
         (Network.apply
            (Network.apply ( * )
               (Network.return_term (Operation.number ~axis_label:"q" 2.0)))
            hey4))
      (Network.return_term (Operation.number ~axis_label:"p" 1.0))
let z =
  let open! Network.O in
    let hey5 =
      Network.return_term (Operation.unconstrained_param ?init:None "hey5")
    and hey6 =
      Network.return_term (Operation.unconstrained_param ?init:None "hey6") in
    Network.apply
      (Network.apply (+)
         (Network.apply
            (Network.apply ( * )
               (Network.return_term (Operation.number ~axis_label:"q" 2.0)))
            hey5))
      (Network.apply (Network.apply ( * ) hey6)
         (Network.return_term (Operation.number ~axis_label:"p" 1.0)))
let () = ignore (y0, y1, y2, a, b, y, z)