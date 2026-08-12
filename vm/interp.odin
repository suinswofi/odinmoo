package vm

// Top-level entry point tying activation + evaluator together for a single verb body.

import "../compiler"
import "../values"

run :: proc(body: []compiler.Stmt, names: ^compiler.Name_Table, world: ^World, act: ^Activation) -> Stmt_Result {
	ctx := Eval_Context{activation = act, world = world, names = names}
	defer delete(ctx.dollar_stack)

	r := exec_stmts(&ctx, body)
	switch r.signal {
	case .Return, .Raised:
		return r
	case .Normal:
		// Fell off the end of the verb without an explicit `return` -- implicit `return 0;`.
		return Stmt_Result{signal = .Return, value = values.int_val(0)}
	case .Break, .Continue:
		// Can't happen for a well-formed program (parser validates every break/continue
		// has an enclosing loop); treat defensively as a no-op return rather than panic.
		return Stmt_Result{signal = .Return, value = values.int_val(0)}
	}
	return r
}
