open Base
open Ocannl
module CDSL = Session.CDSL
module TDSL = Operation.TDSL
module NTDSL = Operation.NTDSL
module SDSL = Session.SDSL

let () = SDSL.set_executor Gccjit

let _suspended () =
  (* SDSL.drop_all_sessions (); *)
  SDSL.set_executor Cuda;
  CDSL.with_debug := true;
  CDSL.keep_files_in_run_directory := true;
  Random.init 0;
  let%nn_op c = "a" [ -4 ] + "b" [ 2 ] in
  (* let%nn_op c = c + c + 1 in
     let%nn_op c = c + 1 + c + ~-a in *)
  (* SDSL.set_fully_on_host g;
     SDSL.set_fully_on_host a;
     SDSL.set_fully_on_host b; *)
  SDSL.everything_fully_on_host ();
  SDSL.refresh_session ~verbose:true ();
  SDSL.print_tree ~with_grad:true ~depth:9 c;
  Stdio.print_endline "\n";
  SDSL.print_tensor ~with_code:false ~with_grad:false `Default @@ c;
  SDSL.print_tensor ~with_code:false ~with_grad:true `Default @@ a;
  SDSL.print_tensor ~with_code:false ~with_grad:true `Default @@ b

let () =
  (* SDSL.drop_all_sessions (); *)
  SDSL.set_executor Cuda;
  CDSL.with_debug := true;
  CDSL.keep_files_in_run_directory := true;
  Random.init 0;
  let%nn_op c = "a" [ -4 ] + "b" [ 2 ] in
  let%nn_op d = (a *. b) + (b **. 3) in
  let%nn_op c = c + c + 1 in
  let%nn_op c = c + 1 + c + ~-a in
  let%nn_op d = d + (d *. 2) + !/(b + a) in
  let%nn_op d = d + (3 *. d) + !/(b - a) in
  let%nn_op e = c - d in
  let%nn_op f = e *. e in
  let%nn_op g = f /. 2 in
  let%nn_op g = g + (10. /. f) in
  (* *)
  SDSL.set_fully_on_host g;
  SDSL.set_fully_on_host a;
  SDSL.set_fully_on_host b;
  (* *)
  (* SDSL.everything_fully_on_host (); *)
  SDSL.refresh_session ~verbose:true ();
  SDSL.print_tree ~with_grad:true ~depth:9 g;
  Stdio.print_endline "\n";
  SDSL.print_tensor ~with_code:false ~with_grad:false `Default @@ g;
  SDSL.print_tensor ~with_code:false ~with_grad:true `Default @@ a;
  SDSL.print_tensor ~with_code:false ~with_grad:true `Default @@ b
