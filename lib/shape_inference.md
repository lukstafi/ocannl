# Shape inference and projection inference

To separate concerns, OCANNL is split into the `arrayjit` library, responsible for compilation of high-level n-D array operation sequences (`Assignments.t`) via the gccjit and cuda backends, and the main `ocannl` library, responsible for deriving the operations computing the forward propagation and backpropagation from tensor expressions. In particular, `arrayjit` contains `Indexing`, which represents complex indexing into arrays, and the main library `ocannl` has `Row` and `Shape` modules, which do the most "heavy-lifting" in the translation from concise tensor expressions to sequences of assignments.

Shape inference broadly speaking consists in OCANNL of inferring the `Shape.t` record -- shape inference proper, and inferring the `Indexing.projections` record -- projections inference. `Shape.t` records are mutable, so that the partially inferred shapes can be observed by the user. Shape and projections inference is intended to be declarative -- independent of the order in which constraints are added. There is one aspect that is not declarative: when tensor expressions are compiled to assignments, i.e. jitted, still-unsolved shape variables in terminal nodes are substituted by their least upper bounds if any, or by dimension-1 / no-more-axes.

The bulk of the projections inference happens alongside shape inference, with the projections-relevant information stored in auxiliary fields -- this prevents subtle bugs where projection semantics deviates from shape semantics, and will simplify adding new shape/projection inference features. Shape inference happens during `propagate_shapes` calls, and then again in a `finish_inference` call, which is triggered whenever the dimensions or projections are required (i.e. typically by jitting). Finally, the projections are reconstructed in `derive_projections`. It would seem `derive_projections` could reuse the already-computed solutions constraints. But we face a problem: we must prevent contaminating projections across different operations. To illustrate: we conclude the dimensions of two axes are the same because they are reduced together in another operation -- this should not force the axes to share a projection in the processed operation. To prevent the contamination, in each `derive_projections` call, we freshen the projection ids in the (inferred) shapes, and regenerate and re-solve the constraints with the fresh projection ids.

## Representing shapes and constraints

A tensor shape in OCANNL is composed of three rows of axes: batch, input and output. These are ordered input-last (`batch @ output @ input`) in the underlying n-dimensional array implementation of tensors. A (fully inferred) tensor shape must have non-empty output axes; we do not use the convention where empty axes mean the tensor is a scalar -- scalars = 1-D output-only tensors. For printing and einsum-notation-like specifications, we use the syntax: `batch|input->output` (or `input->output`, or `output`), where `batch`, `input`, `output` are whitespace or comma or parenthesis separated axis entries; or the axis entries are the individual characters, if no separators are used (except if it's digits only).

A row is a sequence of axes of a single kind: batch, input, or output. The shape type incorporates information relevant to inference, in particular shape variables: both for individual axes (`dim` variables), and for extending a row with more axes (`row` variables). Currently, all rows are (independently) broadcastable: can be broadcasted to a larger number of axes, except when used with an einsum specification that forbids it.

```ocaml
type dim = Var of dim_var | Dim of { d : int; label : string option; proj_id : int option }

type bcast =
  | Row_var of row_var  (** The row can be inferred to have more axes. *)
  | Broadcastable  (** The shape does not have more axes of this kind, but is "polymorphic". *)

type dims_constraint =
  | Unconstrained
  | Total_elems of int  (** The shape-kind, inclusive of the further row spec, has this many elements. *)

type row = Row.t = { dims : dim list; constr : dims_constraint; bcast : bcast; id : row_id }

type shape = Shape.t = {
  mutable batch : row;
  mutable input : row;
  mutable output : row;
  id : int;  (** A node that has the same shape as this shape. *)
  debug_name : string;
}
```

The actual implementation is split into the `Row` module, which handles multi-row inference, and the `Shape` module which deals with the specific axis kinds (batch, input, output), _einsum_ specifications, and the shape-relevant semantics of operations expressed via the `Shape.logic` variant type. Since broadcasting extends leading axes (preserves trailing axes), substituting a `row_var` means prepending to the `dims` of the row that has the row variable as its `bcast` field.

Labels are a part of OCANNL, but it's a topic that needs more exploration and future work. Currently, OCANNL has labeled dimensions, but not labeled axes. This means that when two axes need to agree on the number of dimensions, they also need to agree on the labels. If the dimensions of both axes have labels, the labels need to be the same, and if one doesn't have a label initially, it's inferred to have the label from the other axis. Intuitively, the label is a specification of the semantics of an axis that is more fine-grained than, but of similar nature as, the number of dimensions. Currently, there is no global check to prevent the same label be used with different numbers of dimensions (on unrelated axes). Example: a label `"rgb"` attached to dimensions size 3 to denote that an axis represents three channels "red", "green" and "blue".

The actual shape inference combines row polymorphism with (nominal) subtyping, as known in the type inference literature. The subtyping stems merely from the fact that a dimension-1 axis can be used in the context of any dimension due to per-axis broadcasting. Row polymorphism stems from broadcasting to more axes: for example, when unifying an unknown (shape) row with a known one, we cannot assume that the unknown row will have just the axes of the known one, because maybe the known row is meant to be broadcasted here to more axes. The combination of row polymorphism with nominal subtyping means that the constraints we are solving are inequalities, both inequalities between rows (the `Row.t` type, i.e. the `row` type above), and between axes/dimensions (the `Row.dim` type). We maintain the inequality ordering between variables in the environment to compute the transitive closure during simplification. We also maintain a least upper bound on the solution.

```ocaml
type ('a, 'b) entry = Solved of 'b | Bounds of { cur : 'a list; subr : 'a list; lub : 'b option }
(** An entry implements inequalities [cur >= v >= subr] and/or an equality [v = solved]. *)

type dim_env = (dim_var, dim) entry Map.M(Dim_var).t
type row_env = (row_var, row) entry Map.M(Int).t

type environment = { dim_env : dim_env; row_env : row_env }

type inequality =
  | Dim_eq of { d1 : dim; d2 : dim }
  | Row_eq of { r1 : row; r2 : row }
  | Dim_ineq of { cur : dim; subr : dim }
  | Row_ineq of { cur : row; subr : row }
```

We tie the direction of inequalities with capturing information in the structure of tensor expressions: where relevant, `cur` is a part of the shape of a super-tensor, and `subr` of a sub-tensor in a tensor expression. This reflects the nature of broadcasting: it is one-directional in that the shape of a subtensor can be "smaller-than-expected" thanks to broadcasting, but the shape of a super-tensor cannot be "smaller-than-expected". So, for ground (variable-free) dimensions, _n ≥ m_ means: _either n = m, or m = 1_; and for ground (variable-free) rows, _q ≥ r_ means: _q has at least as many axes as r, and for each dimension n of q at an axis where r has dimension m, we have n ≥ m_. The least upper bound `lub` of a variable is derived from the `cur` sides of inequalities with the variable on the `subr` side. We don't need to maintain a greatest lower bound, because we can incorporate the corresponding information immediately. For rows, we can substitute the row variable by a new row consisting of variables only, and add the corresponding `dim` inequalities with the variables on the `cur` side.

The entry point to shape inference is the shape logic specification, that each operation instance needs to provide. There are shortcuts in the syntax extension `%cd` to make it painless.

```ocaml
type deduce_within_shape = Not_constrained | Input_equals_output

type compose_type =
  | Pointwise_bin  (** NumPy-style broadcast matching batch, input and output axes, e.g. as in [s1 + s2]. *)
  | Compose
      (** Compose the outputs of the second shape with the inputs of the first shape, i.e. the shape of
      [fun x -> s1(s2(x))], or [s1 * s2] where [*] is the inner product (e.g. matrix multiply). *)
  | Einsum of string
      (** The [einsum] syntax: LABELS1;LABELS2=>LABELS3, where LABELSi are labels specifications.
      Since OCANNL's extended einsum notation supports both axis variables and row variables, it makes
      other compose types redundant.
      The [axis_labels] use pseudo-labels local to the notation, to line up the axes.
      For [Einsum (ls1^";"^ls2^"=>"^ls3)], the symmetric difference / disjunctive union of [ls1] and [ls2]'s
      pseudo-labels should be equal to [ls3] pseudo-labels.

      Note: The "right-hand-side" is on the left! I.e. the syntax is "rhs=>lhs", "rhs1;rhs2=>lhs". *)

type transpose_type =
  | Transpose  (** Swaps inputs and outputs of a shape, preserves batch axes. *)
  | Pointwise_un  (** Preserves the shape. *)
  | Permute of string
      (** [Permute (ls1^"=>"^ls2)] is a variant of the [einsum] syntax [Einsum (ls1^";"^ls1^"=>"^ls2)].
      Note: The "right-hand-side" is on the left! I.e. the syntax is "rhs=>lhs", "rhs1;rhs2=>lhs". *)
  | Batch_slice of Arrayjit.Indexing.static_symbol  (** Removes the leftmost batch axis. *)

type logic =
  | Broadcast of compose_type * shape * shape
      (** Matches the shapes for a binary operation.

      For [Broadcast (Einsum (ls1, ls2, ls3), s1, s2)], the labels of [s1] and [s2] must match according
      to the [ls1], [ls2] lineup, and the resulting shape inherits the labels according to the [ls3] lineup.
  *)
  | Transpose of transpose_type * shape
      (** Permutes the axes of a shape. One case of [Transpose] is to swap inputs with outputs of [s1],
      hence the name. *)
  | Terminal of Arrayjit.Ops.init_op
      (** Extracts any available shape information from the initialization. E.g.
      for [File_mapped fn], opens the file [fn] to check its length. *)
```

## Solving the constraints

The constraints are solved by: unification of the equation constraints, and unification-like simplification of the inequality constraints. Simplification of an inequality can generate more equations and inequalities, so we need to be careful to keep it terminating.

Let's explain the shape inference functions.

* `s_dim_one_in_entry` / `s_row_one_in_entry`: substitutes the given dim / row variable in one dim / row env entry. Generates new inequalities if the variable was in one of the sides of a `Bounds` entry.
* `subst_dim` / `subst_row`: substitutes out a variable in a dim / row value, if any.
* `unify_dim`: solves a single equation between two values of type `dim`, and recursively all `dim` equations that this entails, but not inequalities nor row equations.
* `unify_row`: solves a single equation between two rows, and recursively all `dim` and `row` equations that this entails, but not inequalities.
* `apply_constraint`: if there's enough information in a row -- in particular it is not open i.e. there is no row variable -- solves the row constraint. Currently, there's just `Total_elems n`: if there's just one `dim` variable, it will become `n` divided by the product of other dimensions.
* `solve_dim_ineq`: solves a single inequality between two values of type `dim`; returns derived equations and inequalities. It maintains the between-variable bounds and the least-upper-bound (LUB). But there can only be one LUB (a dimension > 1) without forcing the bound variable itself to a solved form (with dimension = 1).
* `solve_row_ineq`: solves a single inequality between two rows; returns derived equations and inequalities. It derives between-`dim` inequalities from the known parts of the compared rows. It maintains between-row-variable bounds (when known parts of the rows match) and the LUB. It forces the `cur` side to have at least the number of axes of the `subr` side (via a variables-only `template`). It updates the LUB by computing dimensions-wise LUBs.
* `close_dim_terminal` and `close_row_terminal`: produce the equal-to-LUB constraint when available.
* `solve_inequalities`: solves equations, inequalities, and row constraints, until only row constraints remain. Row constraints can "pass" if there is not enough information, rather than reflecting their effect in the environment. Calls `close_dim_terminal` and `close_row_terminal` as appropriate (when `finish`).

## Projections inference

```ocaml
type proj = Var of dim_var | Proj of { proj_id : int; d : int } | Solved of axis_index
type proj_to_index = Arrayjit.Indexing.axis_index Map.M(Int).t
type proj_classes = int Map.M(Int).t

type proj_env = {
  proj_to_index : proj_to_index;
  proj_classes : proj_classes;
  product_dim : int Map.M(Int).t;
  non_product : Set.M(Int).t;
}
```

The projection inference functions.

* `get_proj_equations inequalities proj_axis_env env` converts both equations and inequalitites to projection equations. For inequalities, it takes broadcasting into account, and equates a potentially-broadcasted dim-1 projection to `Fixed_idx 0`. `proj_axis_env` originates from the `Shape` module, holds projections from the slice operator and the einsum syntax.
* `solve_proj_equations` unifies the projection equations, using union-find to maintain a representative for equal projections. Projections that already have an `axis_index` are `non_product` (not to be iterated over). The remaining projections have a `product_dim`, and get a fresh iterator.
* `get_proj_index` gets an `axis_index` for a `dim` based on the representative of its `proj_id`; and `Fixed_idx 0` for dim-1.

## Deriving the constraints

Other important functions in the `Shape` module.

* `einsum_slot_spec_to_dims_bio ~generative` parses an einsum spec for a single shape, returns the three rows and a mapping from axis (`dim`) variables to indices where the einsum specifies fixed indexing. When `generative` is true for the kind of a row, when an axis has a fixed projection to dimension 0, the axis is not a variable added to the fixed indexing mapping, but is instead dimension-1 (solved). The "generative" rows are the ones with no initial user-provided shape information. This is just a heuristic to avoid surprises where a tensor axis with only dimension 0 populated gets inferred a bigger dimension size -- it might be revisited in the future.
* `get_inequalities` builds row inequalities by pairing the rows of the current shape (as `cur`) with the rows of sub-shapes (as `subr`). It also derives a batch row constraint for terminals initialized with `Constant_fill { values; strict = true }` and `File_mapped (filename, prec)` (where the file is scanned to get its length). For `Batch_slice` (the `@|` operation) it waits till the batch row variables (if any) are solved, and derives row equations (not inequalities) between the current shape and the sub-shape, with `cur_sh.batch.dims` expanded to account for the slicing / indexing. For einsum specs, it derives inequalities, roughly: _current shape ≥ lhs spec shape_, and _rhs spec shape ≥ sub-shape_.
* `propagate_shapes` gets and then solves the inequalities, using a global state for the environment. It udpates the shapes in-place with the partial solution. It is invoked twice for each `update_step`: first during the bottom-up process of building tensors, and then in reverse order from `finish_inference`.
* `finish_inference` is called right before some projections or array dimensions are required (typically, because of jitting). It performs a second round of `propagate_shapes`, and then once again attempts to solve any remaining constraints that `propagate_shapes` didn't solve. Then it "closes the shapes": substitutes out remaining shape variables by their LUBs if any, or dimension-1 / `Broadcastable` (no-more-axes). Then it resets the environment state, since the shapes are now guaranteed to not have variables.
* `derive_projections` starts by freshening the `proj_id`s in the `update_step`. Then it generates and solves shape inequalities, and then generates and solves projection equations, and constructs the `projections` record.
* `backprop_ith_arg ~from_1` swaps the LHS of `projections` with the `from_1` (e.g. first, second) RHS argument of `projections`. This leads to input-output behavior analogous to the inverse of the original operation wrt. the `from_1` argument.
* `of_spec` constructs a shape record from an einsum slot spec. If `deduced = Input_equals_output`, it adds the corresponding equation to the global environment.
