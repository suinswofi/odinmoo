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
raised_stmt :: proc(code: values.Error, msg: string) -> Stmt_Result {
	return Stmt_Result{signal = .Raised, err = Error_Info{code = code, msg = strings.clone(msg), value = values.int_val(0)}}
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
	switch v in s {
	case ^compiler.Stmt_Cond:
		for arm in v.arms {
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
		return exec_list_loop(ctx, v)

	case ^compiler.Stmt_Range_Loop:
		return exec_range_loop(ctx, v)

	case ^compiler.Stmt_While:
		return exec_while(ctx, v)

	case ^compiler.Stmt_Fork:
		// Ports OP_FORK/OP_FORK_WITH_ID (execute.c:1579-1604): the delay expression is
		// evaluated NOW, must be a non-negative INT (E_TYPE / E_INVARG respectively), and the
		// optional `fork ident (...)` variable is bound -- in both the parent and the forked
		// task's snapshot -- by do_fork itself (tasks.c's enqueue_forked_task2 assigns the new
		// task id into the shared rt_env before copying it).
		delay_r := eval_expr(ctx, v.time)
		if delay_r.raised {
			return raised_from_expr(delay_r)
		}
		if delay_r.value.type != .Int {
			values.free_var(delay_r.value)
			return raised_stmt(.E_TYPE, "Type mismatch")
		}
		if delay_r.value.data.num < 0 {
			values.free_var(delay_r.value)
			return raised_stmt(.E_INVARG, "Invalid argument")
		}
		if ctx.world.do_fork != nil {
			ctx.world.do_fork(ctx.world, delay_r.value, v.body, ctx.names, v.var_id, ctx)
		}
		values.free_var(delay_r.value)
		return normal_result()

	case ^compiler.Stmt_Expr:
		r := eval_expr(ctx, v.expr)
		if r.raised {
			return raised_from_expr(r)
		}
		values.free_var(r.value)
		return normal_result()

	case ^compiler.Stmt_Return:
		if v.expr == nil {
			return Stmt_Result{signal = .Return, value = values.int_val(0)}
		}
		r := eval_expr(ctx, v.expr)
		if r.raised {
			return raised_from_expr(r)
		}
		return Stmt_Result{signal = .Return, value = r.value}

	case ^compiler.Stmt_Try_Except:
		return exec_try_except(ctx, v)

	case ^compiler.Stmt_Try_Finally:
		return exec_try_finally(ctx, v)

	case ^compiler.Stmt_Break:
		return Stmt_Result{signal = .Break, loop_name = loop_name_of(ctx, v.var_id)}

	case ^compiler.Stmt_Continue:
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

// exec_list_loop ports STMT_LIST (`for x in (list_or_str) ... endfor`; MOO's `for` also
// accepts a string here, iterating its characters).
@(private = "file")
exec_list_loop :: proc(ctx: ^Eval_Context, v: ^compiler.Stmt_List_Loop) -> Stmt_Result {
	list_r := eval_expr(ctx, v.list)
	if list_r.raised {
		return raised_from_expr(list_r)
	}
	defer values.free_var(list_r.value)

	n: int
	#partial switch list_r.value.type {
	case .List:
		n = values.list_len(list_r.value)
	case .Str:
		n = len(list_r.value.data.str.s)
	case:
		return raised_stmt(.E_TYPE, "List or string required")
	}

	for i in 1 ..= n {
		item: values.Var
		if list_r.value.type == .List {
			item = values.var_ref(values.list_get(list_r.value, i))
		} else {
			// str_val takes OWNERSHIP and free_var will delete() the string -- handing it
			// a borrowed slice into the loop subject corrupts the heap (freeing an interior
			// pointer, or the subject's own buffer for i == 1). Must clone.
			item = values.str_val(strings.clone(list_r.value.data.str.s[i - 1:i]))
		}
		values.free_var(ctx.activation.locals[v.var_id])
		ctx.activation.locals[v.var_id] = item

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
	if from_r.value.type != .Int || to_r.value.type != .Int {
		return raised_stmt(.E_TYPE, "Integer required")
	}

	i := from_r.value.data.num
	to := to_r.value.data.num
	for i <= to {
		values.free_var(ctx.activation.locals[v.var_id])
		ctx.activation.locals[v.var_id] = values.int_val(i)

		r := exec_stmts(ctx, v.body)
		if r.signal == .Break && (r.loop_name == "" || r.loop_name == loop_name_of(ctx, v.var_id)) {
			return normal_result()
		}
		if r.signal == .Continue && (r.loop_name == "" || r.loop_name == loop_name_of(ctx, v.var_id)) {
			i += 1
			continue
		}
		if r.signal != .Normal {
			return r
		}
		i += 1
	}
	return normal_result()
}

@(private = "file")
exec_while :: proc(ctx: ^Eval_Context, v: ^compiler.Stmt_While) -> Stmt_Result {
	my_name := loop_name_of(ctx, v.var_id)
	for {
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
	for arm in v.excepts {
		if !error_code_matches(ctx, arm.codes, r.err.code) {
			continue
		}
		if arm.var_id >= 0 {
			tuple := raised_tuple(r.err)
			values.free_var(ctx.activation.locals[arm.var_id])
			ctx.activation.locals[arm.var_id] = tuple
		}
		error_info_destroy_local(&r.err)
		return exec_stmts(ctx, arm.body)
	}
	return r
}

// raised_tuple builds the {code, message, value, backtrace} tuple bound to a try/except
// arm's variable (ports code_gen.c's STMT_TRY_EXCEPT: `emit_var_op(OP_PUT, ex->id, ...)`
// storing the whole exception tuple, not just the code). The backtrace slot is an empty
// list for now -- building a real one needs Phase 4's object DB to describe stack frames.
raised_tuple :: proc(e: Error_Info) -> values.Var {
	items := make([]values.Var, 4)
	items[0] = values.err_val(e.code)
	items[1] = values.str_val(strings.clone(e.msg))
	items[2] = values.var_ref(e.value)
	items[3] = values.empty_list()
	return values.list_val(items)
}

@(private = "file")
exec_try_finally :: proc(ctx: ^Eval_Context, v: ^compiler.Stmt_Try_Finally) -> Stmt_Result {
	body_r := exec_stmts(ctx, v.body)
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
