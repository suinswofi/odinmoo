package vm

// Top-level entry point tying activation + evaluator together for a single verb body.

import "../compiler"
import "../values"

run :: proc(body: []compiler.Stmt, names: ^compiler.Name_Table, world: ^World, act: ^Activation) -> Stmt_Result {
	// A task's ROOT verb call arrives with no budget (every server entry point -- command
	// dispatch, login, a forked body, the `.program` editor, `.eval` -- just builds a bare
	// Activation), and a NESTED one arrives with its caller's, copied by call_verb_from.
	// Opening the budget here rather than at each of those entry points is what makes it
	// impossible to add a new one that is accidentally unmetered.
	//
	// It lives on this stack frame, which is sound precisely because this is the task's
	// outermost run(): every activation that borrows the pointer belongs to a call nested
	// inside it and is gone before it returns. The pointer is cleared on the way out anyway,
	// so a root Activation that outlives its run() (netio reuses one) can't be left holding
	// a dangling one.
	local_budget: Task_Budget
	opened_budget := act.budget == nil
	if opened_budget {
		budget_init(&local_budget)
		act.budget = &local_budget
	}
	defer if opened_budget {act.budget = nil}

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
