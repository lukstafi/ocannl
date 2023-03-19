open Base
open Ocannl
module DSL = Operation.DSL

let () = Session.DSL.set_executor `OCaml

let hello1() =
  Session.drop_session();
  Random.init 0;
  let open Operation.DSL in
  let open Session.DSL in
  (* Hey is inferred to be a matrix. *)
  let hey =
    range_of_shape ~batch_dims:[7] ~input_dims:[9; 10; 11] ~output_dims:[13; 14] () in
  let%nn_op hoo = (1 + 1) * hey - 10 in
  refresh_session ();
  print_node_tree ~with_grad:false ~depth:99 hoo.node_id;
  print_formula ~with_code:false ~with_grad:false `Default hoo
  (* Disable line wrapping for viewing the output. In VSCode: `View: Toggle Word Wrap`. *)

let hello2() =
  let open Session.DSL in
  drop_session();
  Random.init 0;
  (* Hey is inferred to be a matrix. *)
  let%nn_op y = "hey" * 'q' 2.0 + 'p' 1.0 in
  (* Punning for ["hey"] above introduced the [hey] identifier. *)
  refresh_session ();
  print_preamble();
  print_formula ~with_code:false ~with_grad:false `Default @@ hey;
  print_formula ~with_code:false ~with_grad:false `Default @@ y

let hello3() =
  let open Session.DSL in
  drop_session();
  Random.init 0;
  (* Hey is inferred to be a matrix. *)
  let hey = DSL.O.(!~ "hey") in
  let zero_to_twenty = DSL.range 20 in
  let _y = DSL.O.(hey * zero_to_twenty + zero_to_twenty) in
  refresh_session ();
  print_preamble();
  print_session_code();
  Caml.Format.print_newline();
  print_formula ~with_code:true ~with_grad:false `Inline zero_to_twenty;
  Caml.Format.print_newline();
  print_formula ~with_code:true ~with_grad:false `Default zero_to_twenty;
  Caml.Format.print_newline();
  print_formula ~with_code:true ~with_grad:false `Default hey

let () = ignore (hello1, hello2); hello3()