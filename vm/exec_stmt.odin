package vm

// Statement execution, ported from execute.c's STMT_* handling. Control flow (break/
// continue/return/raised-error) propagates as an explicit signal riding up through ordinary
// Odin call returns -- see the architecture note atop activation.odin for why this replaces
// the original's activation-stack-marker scanning: Odin's native call stack already gives
// "unwind to the nearest enclosing handler, possibly across several verb calls" for free.

import "../compiler"
import "../values"
import "core:strings"

Stmt_Signal :: enum {
	Normal,
	Break,
	Continue,
	Return,
	Raised,
}

Stmt_Result :: struct {
	signal:    Stmt_Signal,
	loop_name: string, // for Break/Continue; "" means "innermost, unnamed"
	value:     values.Var, // for Return (owned); zero value otherwise
	err:       Error_Info, // for Raised (owned)
}

normal_result :: proc() -> Stmt_Result {return Stmt_Result{signal = .Normal}}

@(private = "file")
raised_from_expr :: proc(r: Expr_Result) -> Stmt_Result {
	return Stmt_Result{signal = .Raised, err = r.err}
}

// raised_stmt builds a Raised result for a statement-level type error. Always construct these
// through here rather than filling in an Error_Info literal: `msg` is OWNED (whoever handles or
// discards the exception calls error_info_destroy on it), so passing a string constant
// directly would hand delete() a pointer into static data -- an invalid free that only shows up
// when the error is actually caught, i.e. in exactly the try/except code written to handle it.
@(private = "file")
raised_stmt :: proc(ctx: ^Eval_Context, code: values.Error, msg: string) -> Stmt_Result {
	r := Stmt_Result{signal = .Raised, err = Error_Info{code = code, msg = strings.clone(msg), value = values.int_val(0)}}
	record_error(ctx, &r.err)
	return r
}

// stmt_error ports RAISE_ERROR (execute.c): the error is raised only when the verb has its
// `d` flag set. In a !d verb the statement simply doesn't happen -- a `for` over a non-list
// skips its body, a `fork` with a bad delay doesn't fork -- which is how JHCore's
// $code_utils:help_db_list survives an object whose .help is neither a list nor an object.
@(private = "file")
stmt_error :: proc(ctx: ^Eval_Context, code: values.Error) -> Stmt_Result {
	if !ctx.activation.debug {
		return normal_result()
	}
	return raised_stmt(ctx, code, error_message(code))
}

@(private = "file")
budget_abort :: proc(ctx: ^Eval_Context) -> Stmt_Result {
	r := Stmt_Result{signal = .Raised, err = budget_abort_error(ctx.activation.budget)}
	record_error(ctx, &r.err)
	return r
}

// charge_iteration bills one tick for going round a loop, and is the reason the budget
// holds for EVERY loop rather than most of them. exec_stmt's per-statement charge covers a
// loop whose body does something, but `while (1) endwhile` and `for i in [1..n] endfor` have
// no statements in them at all: exec_stmts runs over an empty slice, exec_stmt is never
// reached, and the loop spins forever uncharged -- holding big_lock and wedging the whole
// server, which is precisely what the budget exists to prevent. (Not hypothetical: an
// empty-bodied `while (1)` typed at a live JHCore server did exactly that, while the same
// loop with a statement in it aborted correctly.) Every construct that can repeat calls
// this before running its body.
@(private = "file")
charge_iteration :: proc(ctx: ^Eval_Context) -> (r: Stmt_Result, exhausted: bool) {
	if budget_charge(ctx.activation.budget) {
		return {}, false
	}
	return budget_abort(ctx), true
}

exec_stmts :: proc(ctx: ^Eval_Context, stmts: []compiler.Stmt) -> Stmt_Result {
	for s in stmts {
		r := exec_stmt(ctx, s)
		if r.signal != .Normal {
			return r
		}
	}
	return normal_result()
}

exec_stmt :: proc(ctx: ^Eval_Context, s: compiler.Stmt) -> Stmt_Result {
	// One tick per statement -- see budget.odin for what a tick means in a tree-walker and
	// why the abort is uncatchable. This charge covers the bulk of it (a verb call is always
	// reached from a statement, so recursion is billed too), but NOT quite everything: a loop
	// with an empty body executes no statements at all, which is what charge_iteration above
	// is for. Both are needed.
	if !budget_charge(ctx.activation.budget) {
		return budget_abort(ctx)
	}
	if values.stack_exhausted() { // nested blocks recurse too -- see values/stack_guard.odin
		return raised_stmt(ctx, .E_MAXREC, error_message(.E_MAXREC))
	}
	switch v in s {
	case ^compiler.Stmt_Cond:
		for arm in v.arms {
			ctx.activation.line = arm.line // an error in an `elseif` test is blamed on its line
			cond_r := eval_expr(ctx, arm.condition)
			if cond_r.raised {
				return raised_from_expr(cond_r)
			}
			is_true := values.is_true(cond_r.value)
			values.free_var(cond_r.value)
			if is_true {
				return exec_stmts(ctx, arm.body)
			}
		}
		return exec_stmts(ctx, v.otherwise)

	case ^compiler.Stmt_List_Loop:
		ctx.activation.line = v.line
		return exec_list_loop(ctx, v)

	case ^compiler.Stmt_Range_Loop:
		ctx.activation.line = v.line
		return exec_range_loop(ctx, v)

	case ^compiler.Stmt_While:
		return exec_while(ctx, v)

	case ^compiler.Stmt_Fork:
		// Ports OP_FORK/OP_FORK_WITH_ID (execute.c:1579-1604): the delay expression is
		// evaluated NOW, must be a non-negative INT (E_TYPE / E_INVARG respectively), and the
		// optional `fork ident (...)` variable is bound -- in both the parent and the forked
		// task's snapshot -- by do_fork itself (tasks.c's enqueue_forked_task2 assigns the new
		// task id into the shared rt_env before copying it).
		ctx.activation.line = v.line
		delay_r := eval_expr(ctx, v.time)
		if delay_r.raised {
			return raised_from_expr(delay_r)
		}
		if delay_r.value.type != .Int {
			values.free_var(delay_r.value)
			return stmt_error(ctx, .E_TYPE)
		}
		if delay_r.value.data.num < 0 {
			values.free_var(delay_r.value)
			return stmt_error(ctx, .E_INVARG)
		}
		if ctx.world.do_fork != nil {
			// E_QUOTA when the forking verb's owner is at $server_options.queued_task_limit
			// (tasks.c's check_user_task_limit) -- also a RAISE_ERROR, so also d-flag gated.
			if e := ctx.world.do_fork(ctx.world, delay_r.value, v.body, ctx.names, v.var_id, ctx); e != .E_NONE {
				values.free_var(delay_r.value)
				return stmt_error(ctx, e)
			}
		}
		values.free_var(delay_r.value)
		return normal_result()

	case ^compiler.Stmt_Expr:
		ctx.activation.line = v.line
		r := eval_expr(ctx, v.expr)
		if r.raised {
			return raised_from_expr(r)
		}
		values.free_var(r.value)
		return normal_result()

	case ^compiler.Stmt_Return:
		ctx.activation.line = v.line
		if v.expr == nil {
			return Stmt_Result{signal = .Return, value = values.int_val(0)}
		}
		r := eval_expr(ctx, v.expr)
		if r.raised {
			return raised_from_expr(r)
		}
		return Stmt_Result{signal = .Return, value = r.value}

	case ^compiler.Stmt_Try_Except:
		ctx.activation.line = v.line
		return exec_try_except(ctx, v)

	case ^compiler.Stmt_Try_Finally:
		ctx.activation.line = v.line
		return exec_try_finally(ctx, v)

	case ^compiler.Stmt_Break:
		ctx.activation.line = v.line
		return Stmt_Result{signal = .Break, loop_name = loop_name_of(ctx, v.var_id)}

	case ^compiler.Stmt_Continue:
		ctx.activation.line = v.line
		return Stmt_Result{signal = .Continue, loop_name = loop_name_of(ctx, v.var_id)}
	}
	return normal_result()
}

@(private = "file")
loop_name_of :: proc(ctx: ^Eval_Context, var_id: int) -> string {
	if var_id < 0 {
		return ""
	}
	return ctx.names.names[var_id]
}

// exec_list_loop ports STMT_LIST (`for x in (list) ... endfor`).
//
// A LIST, and nothing else: "The expression is evaluated and should return a list; if it does
// not, E_TYPE is raised" (Programmer's Manual, 4.1.2). This used to also accept a string and
// iterate its characters, described in a comment here as MOO behaviour -- it is not, it is a
// Stunt/ToastStunt extension, and accepting it silently turned code that should have raised
// E_TYPE on an unexpected string into code that quietly looped over its bytes.
@(private = "file")
exec_list_loop :: proc(ctx: ^Eval_Context, v: ^compiler.Stmt_List_Loop) -> Stmt_Result {
	list_r := eval_expr(ctx, v.list)
	if list_r.raised {
		return raised_from_expr(list_r)
	}
	defer values.free_var(list_r.value)

	if list_r.value.type != .List {
		return stmt_error(ctx, .E_TYPE) // OP_FOR_LIST: RAISE_ERROR(E_TYPE), so `d`-gated
	}
	n := values.list_len(list_r.value)

	for i in 1 ..= n {
		if r, exhausted := charge_iteration(ctx); exhausted {
			return r
		}
		values.free_var(ctx.activation.locals[v.var_id])
		ctx.activation.locals[v.var_id] = values.var_ref(values.list_get(list_r.value, i))

		r := exec_stmts(ctx, v.body)
		if r.signal == .Break && (r.loop_name == "" || r.loop_name == loop_name_of(ctx, v.var_id)) {
			return normal_result()
		}
		if r.signal == .Continue && (r.loop_name == "" || r.loop_name == loop_name_of(ctx, v.var_id)) {
			continue
		}
		if r.signal != .Normal {
			return r
		}
	}
	return normal_result()
}

// exec_range_loop ports OP_FOR_RANGE: both bounds INT, or both OBJ (`for o in [#1..#10]`),
// anything else E_TYPE (d-flag gated, like OP_FOR_LIST). The bounds are evaluated once.
@(private = "file")
exec_range_loop :: proc(ctx: ^Eval_Context, v: ^compiler.Stmt_Range_Loop) -> Stmt_Result {
	from_r := eval_expr(ctx, v.from)
	if from_r.raised {
		return raised_from_expr(from_r)
	}
	to_r := eval_expr(ctx, v.to)
	if to_r.raised {
		values.free_var(from_r.value)
		return raised_from_expr(to_r)
	}
	defer values.free_var(from_r.value)
	defer values.free_var(to_r.value)
	kind := to_r.value.type
	if (kind != .Int && kind != .Obj) || from_r.value.type != kind {
		return stmt_error(ctx, .E_TYPE)
	}

	i, to: i32
	if kind == .Int {
		i, to = from_r.value.data.num, to_r.value.data.num
	} else {
		i, to = i32(from_r.value.data.obj), i32(to_r.value.data.obj)
	}
	for i <= to {
		if r, exhausted := charge_iteration(ctx); exhausted {
			return r
		}
		values.free_var(ctx.activation.locals[v.var_id])
		ctx.activation.locals[v.var_id] = kind == .Int ? values.int_val(i) : values.obj_val(values.Objid(i))

		r := exec_stmts(ctx, v.body)
		mine := r.loop_name == "" || r.loop_name == loop_name_of(ctx, v.var_id)
		if r.signal == .Break && mine {
			return normal_result()
		}
		if r.signal != .Normal && !(r.signal == .Continue && mine) {
			return r
		}
		// Terminate on the value rather than by incrementing past it. `to` can be max(i32),
		// and i32 addition wraps, so the increment after the last iteration used to produce
		// min(i32) -- still <= to -- and the loop restarted from the bottom of the range and
		// never finished. `for i in [2147483645..2147483647]`, which the language says runs
		// exactly three times, ran forever. (The original avoids the same wrap by decrementing
		// `to` instead once `from` reaches MAXINT.)
		if i == to {
			break
		}
		i += 1
	}
	return normal_result()
}

@(private = "file")
exec_while :: proc(ctx: ^Eval_Context, v: ^compiler.Stmt_While) -> Stmt_Result {
	my_name := loop_name_of(ctx, v.var_id)
	for {
		if r, exhausted := charge_iteration(ctx); exhausted {
			return r
		}
		ctx.activation.line = v.line // the test is blamed on the `while` line, every time round
		cond_r := eval_expr(ctx, v.condition)
		if cond_r.raised {
			return raised_from_expr(cond_r)
		}
		is_true := values.is_true(cond_r.value)
		values.free_var(cond_r.value)
		if !is_true {
			return normal_result()
		}

		r := exec_stmts(ctx, v.body)
		if r.signal == .Break && (r.loop_name == "" || r.loop_name == my_name) {
			return normal_result()
		}
		if r.signal == .Continue && (r.loop_name == "" || r.loop_name == my_name) {
			continue
		}
		if r.signal != .Normal {
			return r
		}
	}
}

// exec_try_except ports STMT_TRY_EXCEPT: run the body; on a Raised signal, check each arm
// in order (nil codes == ANY), bind the arm's variable to the exception tuple
// {code, message, value} if named, and run that arm's body instead. An unmatched Raised
// propagates further up unchanged -- naturally reaching an enclosing try/except several
// verb calls up, once verb calls exist, simply by ordinary Odin call-stack unwinding.
@(private = "file")
exec_try_except :: proc(ctx: ^Eval_Context, v: ^compiler.Stmt_Try_Except) -> Stmt_Result {
	r := exec_stmts(ctx, v.body)
	if r.signal != .Raised {
		return r
	}
	if r.err.uncatchable {
		// A task-budget abort is not an exception the program gets a say in. Letting
		// `except (ANY)` see it would make the whole budget ineffective: the handler
		// returns, the enclosing loop goes round again, and the task carries on holding
		// big_lock exactly as it did before there was a budget.
		return r
	}
	for arm in v.excepts {
		if !error_code_matches(ctx, arm.codes, r.err.code) {
			continue
		}
		if arm.var_id >= 0 {
			tuple := raised_tuple(ctx, r.err)
			values.free_var(ctx.activation.locals[arm.var_id])
			ctx.activation.locals[arm.var_id] = tuple
		}
		error_info_destroy_local(&r.err)
		return exec_stmts(ctx, arm.body)
	}
	return r
}

// raised_tuple builds the {code, message, value, stack} tuple bound to a try/except arm's
// variable (raise_error's 4-element value). `stack` is make_stack_list from the handling
// activation up to the one that raised, each frame {this, verb, programmer, verb-loc, player,
// line} -- what LambdaCore's #0:user_connected prints when a confunc fails.
raised_tuple :: proc(ctx: ^Eval_Context, e: Error_Info) -> values.Var {
	items := make([]values.Var, 4)
	items[0] = values.err_val(e.code)
	items[1] = values.str_val(strings.clone(e.msg))
	items[2] = values.var_ref(e.value)
	frames, owned := error_frames(ctx.activation, e.serial)
	items[3] = stack_list(frames, ctx.activation.depth)
	release_frames(&frames, owned)
	return values.list_val(items)
}

@(private = "file")
exec_try_finally :: proc(ctx: ^Eval_Context, v: ^compiler.Stmt_Try_Finally) -> Stmt_Result {
	body_r := exec_stmts(ctx, v.body)
	if body_r.signal == .Raised && body_r.err.uncatchable {
		// The handler is skipped deliberately. It is ordinary MOO code, so running it would
		// mean running statements for a task that has already exhausted its budget -- each
		// one immediately re-aborting (the exhaustion is sticky), and a `finally` body
		// containing a loop would spin through it. The original doesn't face the question
		// because an out-of-ticks task is killed where it stands, not unwound.
		return body_r
	}
	handler_r := exec_stmts(ctx, v.handler)
	if handler_r.signal != .Normal {
		if body_r.signal == .Raised {
			error_info_destroy_local(&body_r.err)
		}
		if body_r.signal == .Return {
			values.free_var(body_r.value)
		}
		return handler_r
	}
	return body_r
}
