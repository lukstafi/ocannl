(** `Node`: the computation type, global state and utils which the `Formula` staged code uses. *)
(* Do not depend on Base to minimize dependencies. *)
module Obj = Obj

module A = Bigarray.Genarray
type elt = Bigarray.float32_elt
type data = (float, elt, Bigarray.c_layout) A.t

(* The reference cell below contains something other than None for a brief
   period, before the value is taken and returned to the caller of
   run_native. This policy prevents memory leaks
*)
let result__ : Obj.t option ref = ref None

let dims (arr: data) = A.dims arr
  
 let create_array = A.create Bigarray.Float32 Bigarray.C_layout
 let empty = create_array [||]

type t = {
  mutable value: data;
  mutable grad: data;
  label: string;
  id: int;
}

type state = {
  mutable unique_id: int;
  node_store: (int, t) Hashtbl.t;
}

let global = {
  unique_id = 1;
  node_store = Hashtbl.create 16;
}
let get uid = Hashtbl.find global.node_store uid

let create ~label =
  let node = {
    value=empty; grad=empty; label;
    id=let uid = global.unique_id in global.unique_id <- global.unique_id + 1; uid
  } in
  Hashtbl.add global.node_store node.id node;
  node

let minus = (-)