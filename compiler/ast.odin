package compiler

// AST, ported from src/ast.h. Re-engineered from the original's C-style manual tagged
// union (an `enum Expr_Kind` + `union Expr_Data`, since C has no sum types) into Odin's
// native tagged `union` -- each variant is its own struct, and the union itself acts as the
// discriminant, so there's no separate Kind enum to keep in sync by hand. Statement/argument
// sequences (originally C linked lists threaded through `next` pointers, appended by
// walking to the tail) become plain `[]` slices built with `[dynamic]` + `append` during
// parsing -- same information, no manual list-splicing.

import "../values"

Expr :: union {
	^Expr_Var,
	^Expr_Id,
	^Expr_Prop,
	^Expr_Verb_Call,
	^Expr_Index,
	^Expr_Range,
	^Expr_Assign,
	^Expr_Call,
	^Expr_Binary,
	^Expr_Unary,
	^Expr_List,
	^Expr_Cond,
	^Expr_Catch,
	^Expr_Length,
	^Expr_Scatter,
}

// A literal constant (int/float/string/obj/error), including unary-minus-folded numeric
// literals (`-5` parses directly to this, not to an Expr_Unary wrapping a positive 5 --
// ports the constant-folding done inline in parser.y's unary-minus grammar action).
Expr_Var :: struct {
	value: values.Var,
}

// A reference to a local variable slot (resolved by name at parse time via Name_Table,
// exactly like the original's find_id()).
Expr_Id :: struct {
	var_id: int,
}

// obj.prop, obj.(expr), and the `$foo` shorthand (desugared to #0.("foo") at parse time,
// same as the original).
Expr_Prop :: struct {
	obj:  Expr,
	prop: Expr,
}

// obj:verb(args), obj:(expr)(args), and the `$foo(args)` shorthand (desugared to
// #0:("foo")(args)).
Expr_Verb_Call :: struct {
	obj:  Expr,
	verb: Expr,
	args: []Arg,
}

Expr_Index :: struct {
	base:  Expr,
	index: Expr,
}

Expr_Range :: struct {
	base, from, to: Expr,
}

// target = value. target is an Expr_Id, Expr_Prop, Expr_Index (on any of those), or an
// Expr_Scatter for `{a, ?b, @rest} = value`.
Expr_Assign :: struct {
	target: Expr,
	value:  Expr,
}

// A built-in function call, `name(args)`. is_known mirrors the original's
// number_func_by_name() lookup at parse time: an unrecognized name is not a parse error --
// it's rewritten to a call_function("name", @args) call instead (with a compiler warning),
// exactly as the C original does, so that forward-compatible/newer-builtin verb code
// written for a different server build still parses.
Expr_Call :: struct {
	name:     string, // always the literal name as written, even when rewritten
	is_known: bool,
	args:     []Arg,
}

Binary_Op :: enum {
	Plus, Minus, Times, Divide, Mod, Exp,
	And, Or,
	Eq, Ne, Lt, Le, Gt, Ge, In,
}

Expr_Binary :: struct {
	op:       Binary_Op,
	lhs, rhs: Expr,
}

Unary_Op :: enum {
	Negate,
	Not,
}

Expr_Unary :: struct {
	op:      Unary_Op,
	operand: Expr,
}

// {a, b, @rest} list-literal expression (also reused as the parse target that
// vet_scatter()/scatter_from_arglist() rewrite into an Expr_Scatter when it's the LHS of
// `=`).
Expr_List :: struct {
	items: []Arg,
}

// condition ? consequent | alternate
Expr_Cond :: struct {
	condition, consequent, alternate: Expr,
}

// `try_expr ! codes => handler'` (backtick/quote catch expression). codes == nil means ANY;
// handler == nil means no default (a matching error simply becomes the expression's value).
Expr_Catch :: struct {
	try:     Expr,
	codes:   []Arg, // nil means ANY
	handler: Expr,  // nil means no `=> expr` default
}

// The `$` expression (length of the innermost enclosing indexing operation).
Expr_Length :: struct{}

Scatter_Kind :: enum {
	Required,
	Optional,
	Rest,
}

Scatter_Item :: struct {
	kind:    Scatter_Kind,
	var_id:  int,
	default: Expr, // only meaningful for .Optional; nil otherwise
}

// The `{a, ?b = default, @rest}` target of a scattering assignment. Always appears as the
// target of an Expr_Assign, never standalone.
Expr_Scatter :: struct {
	items: []Scatter_Item,
}

// Arg is a single call/list-literal argument -- either a plain expr or an `@expr` splice
// (spread) argument.
Arg :: struct {
	splice: bool,
	expr:   Expr,
}

Stmt :: union {
	^Stmt_Cond,
	^Stmt_List_Loop,
	^Stmt_Range_Loop,
	^Stmt_While,
	^Stmt_Fork,
	^Stmt_Expr,
	^Stmt_Return,
	^Stmt_Try_Except,
	^Stmt_Try_Finally,
	^Stmt_Break,
	^Stmt_Continue,
}

Cond_Arm :: struct {
	condition: Expr,
	body:      []Stmt,
}

// if/elseif*/else/endif. `otherwise` is nil when there's no `else` clause.
Stmt_Cond :: struct {
	arms:      []Cond_Arm,
	otherwise: []Stmt,
}

// for VAR in (list_expr) ... endfor
Stmt_List_Loop :: struct {
	var_id: int,
	list:   Expr,
	body:   []Stmt,
}

// for VAR in [from..to] ... endfor
Stmt_Range_Loop :: struct {
	var_id:    int,
	from, to:  Expr,
	body:      []Stmt,
}

// while (cond) ... endwhile, and the named form `while VAR (cond) ... endwhile`.
// var_id == -1 for the unnamed form.
Stmt_While :: struct {
	var_id:    int,
	condition: Expr,
	body:      []Stmt,
}

// fork (time) ... endfork, and the named form `fork VAR (time) ... endfork`.
Stmt_Fork :: struct {
	var_id: int,
	time:   Expr,
	body:   []Stmt,
}

Stmt_Expr :: struct {
	expr: Expr,
}

// return [expr];  -- expr is nil for a bare `return;`.
Stmt_Return :: struct {
	expr: Expr,
}

Except_Arm :: struct {
	var_id: int,   // -1 if the exception value isn't bound to a name
	codes:  []Arg, // nil means ANY
	body:   []Stmt,
}

Stmt_Try_Except :: struct {
	body:    []Stmt,
	excepts: []Except_Arm,
}

Stmt_Try_Finally :: struct {
	body:    []Stmt,
	handler: []Stmt,
}

// break [VAR];  -- var_id == -1 for the unnamed form.
Stmt_Break :: struct {
	var_id: int,
}

Stmt_Continue :: struct {
	var_id: int,
}
