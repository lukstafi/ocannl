(** The row type, shape inference related types and constraint solving. *)

open Base

type kind = [ `Batch | `Input | `Output ] [@@deriving equal, compare, sexp, hash, variants]
type dim_var [@@deriving equal, hash, compare, sexp]
type dim_cmp
type 'a dim_map = (dim_var, 'a, dim_cmp) Base.Map.t [@@deriving equal, sexp]

val get_var : ?label:string -> unit -> dim_var
val dim_map_empty : (dim_var, 'a, dim_cmp) Map.t

(** A single axis in a shape. *)
type dim = Var of dim_var | Dim of { d : int; label : string option; proj_id : int option }
[@@deriving equal, hash, compare, sexp, variants]

val get_dim : d:int -> ?label:string -> unit -> dim
val dim_to_int_exn : dim -> int
val dim_to_string : [> `Only_labels ] -> dim -> string

type row_id [@@deriving sexp, compare, equal, hash]
type row_cmp

val row_id : sh_id:int -> kind:kind -> row_id

type row_var [@@deriving sexp, compare, equal, hash]

val get_row_var : unit -> row_var

(** A bcast specifies how axes of a single kind in a shape (i.e. the row) can adapt to other shapes. *)
type bcast =
  | Row_var of row_var  (** The row can be inferred to have more axes. *)
  | Broadcastable  (** The shape does not have more axes of this kind, but is "polymorphic". *)
[@@deriving equal, hash, compare, sexp, variants]

type t = { dims : dim list; bcast : bcast; id : row_id } [@@deriving equal, hash, compare, sexp]

val dims_label_assoc : t -> (string * dim) list

type environment [@@deriving sexp]
type error_trace = ..

type error_trace +=
  | Row_mismatch of t list
  | Dim_mismatch of dim list
  | Index_mismatch of Arrayjit.Indexing.axis_index list

val sexp_of_error_trace : error_trace -> Sexp.t

exception Shape_error of string * error_trace list [@@deriving sexp_of]

type dims_constraint =
  | Unconstrained
  | Total_elems of int  (** The shape-kind, inclusive of the further row spec, has this many elements. *)
[@@deriving equal, hash, compare, sexp, variants]

type inequality =
  | Dim_eq of { d1 : dim; d2 : dim }
  | Row_eq of { r1 : t; r2 : t }
  | Dim_ineq of { cur : dim; subr : dim }
  | Row_ineq of { cur : t; subr : t }
  | Row_constr of { r : t; constr : dims_constraint }
  | Terminal_dim of dim
  | Terminal_row of t
[@@deriving compare, equal, sexp, variants]

val subst_row : environment -> t -> t
val unify_row : t * t -> environment -> inequality list * environment
val empty_env : environment
val solve_inequalities : finish:bool -> inequality list -> environment -> inequality list * environment
val row_to_labels : environment -> t -> string array
val finalize_row :  environment -> t -> inequality list

type proj [@@deriving compare, equal, sexp]
type proj_env [@@deriving sexp]

val fresh_row_proj : t -> t

type proj_equation =
  | Proj_eq of proj * proj  (** Two projections are the same, e.g. two axes share the same iterator. *)
  | Iterated of proj
      (** The projection needs to be an iterator even if an axis is not matched with another axis,
          e.g. for broadcasted-to axes of a tensor assigned a constant. *)
[@@deriving compare, equal, sexp]

val get_proj_equations :
  inequality list -> Arrayjit.Indexing.axis_index dim_map -> environment -> proj_equation list

val solve_proj_equations : proj_equation list -> proj_env
val get_proj_index : proj_env -> dim -> Arrayjit.Indexing.axis_index
val get_product_proj : proj_env -> dim -> (int * int) option
val proj_to_iterator : proj_env -> int -> Arrayjit.Indexing.symbol
