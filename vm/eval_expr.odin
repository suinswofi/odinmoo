package vm

// Expression evaluator, ported from execute.c's opcode handlers for the corresponding
// EXPR_* AST shapes (see ast.odin's comment on why this is a tree-walker rather than a
// literal bytecode VM). Every eval_expr case that recurses into a sub-expression checks
// `.raised` immediately afterward and propagates -- Odin has no exceptions, so this is the
// explicit equivalent of the original's PUSH_ERROR-then-unwind behavior for debug-mode
// verbs.

import "../compiler"
import "../values"
import "core:strings"

Expr_Result :: struct {
	value:  values.Var,
	raised: bool,
	err:    Error_Info,
}

ok_expr :: proc(v: values.Var) -> Expr_Result {return Expr_Result{value = v}}

// raise_or_value ports the debug-flag branch shared by every PUSH_ERROR call site: a
// debug-enabled verb (the default) raises a catchable exception; a legacy non-debug verb
// just gets the bare ERR value pushed as an ordinary result, matching very old MOO behavior.
raise_or_value :: proc(ctx: ^Eval_Context, code: values.Error) -> Expr_Result {
	if ctx.activation.debug {
		return Expr_Result{raised = true, err = Error_Info{code = code, msg = strings.clone(error_message(code)), value = values.int_val(0)}}
	}
	return ok_expr(values.err_val(code))
}

// propagate turns a lower-level Op_Result into an Expr_Result, applying the same
// raise-vs-inline-error policy.
@(private = "file")
propagate :: proc(ctx: ^Eval_Context, r: Op_Result) -> Expr_Result {
	if r.err != .E_NONE {
		return raise_or_value(ctx, r.err)
	}
	return ok_expr(r.value)
}

call_to_expr :: proc(r: Call_Result) -> Expr_Result {
	if r.raised {
		return Expr_Result{raised = true, err = Error_Info{code = r.code, msg = r.msg, value = r.rvalue}}
	}
	return ok_expr(r.value)
}

eval_expr :: proc(ctx: ^Eval_Context, e: compiler.Expr) -> Expr_Result {
	switch v in e {
	case ^compiler.Expr_Var:
		return ok_expr(values.var_ref(v.value))

	case ^compiler.Expr_Id:
		val := ctx.activation.locals[v.var_id]
		if val.type == .None {
			return raise_or_value(ctx, .E_VARNF)
		}
		return ok_expr(values.var_ref(val))

	case ^compiler.Expr_Prop:
		return eval_prop_get(ctx, v.obj, v.prop)

	case ^compiler.Expr_Verb_Call:
		return eval_verb_call(ctx, v.obj, v.verb, v.args)

	case ^compiler.Expr_Index:
		return eval_index(ctx, v.base, v.index)

	case ^compiler.Expr_Range:
		return eval_range(ctx, v.base, v.from, v.to)

	case ^compiler.Expr_Assign:
		val_r := eval_expr(ctx, v.value)
		if val_r.raised {
			return val_r
		}
		return assign_to_lvalue(ctx, v.target, val_r.value)

	case ^compiler.Expr_Call:
		return eval_call(ctx, v.name, v.is_known, v.args)

	case ^compiler.Expr_Binary:
		return eval_binary(ctx, v)

	case ^compiler.Expr_Unary:
		operand_r := eval_expr(ctx, v.operand)
		if operand_r.raised {
			return operand_r
		}
		if v.op == .Not {
			r := ok_expr(values.int_val(values.is_true(operand_r.value) ? 0 : 1))
			values.free_var(operand_r.value)
			return r
		}
		res := do_unary_minus(operand_r.value)
		values.free_var(operand_r.value)
		return propagate(ctx, res)

	case ^compiler.Expr_List:
		return eval_list(ctx, v.items)

	case ^compiler.Expr_Cond:
		cond_r := eval_expr(ctx, v.condition)
		if cond_r.raised {
			return cond_r
		}
		is_true := values.is_true(cond_r.value)
		values.free_var(cond_r.value)
		return is_true ? eval_expr(ctx, v.consequent) : eval_expr(ctx, v.alternate)

	case ^compiler.Expr_Catch:
		return eval_catch(ctx, v)

	case ^compiler.Expr_Length:
		if len(ctx.dollar_stack) == 0 {
			return raise_or_value(ctx, .E_TYPE)
		}
		base := ctx.dollar_stack[len(ctx.dollar_stack) - 1]
		#partial switch base.type {
		case .Str:
			return ok_expr(values.int_val(i32(len(base.data.str.s))))
		case .List:
			return ok_expr(values.int_val(i32(values.list_len(base))))
		case:
			return raise_or_value(ctx, .E_TYPE)
		}

	case ^compiler.Expr_Scatter:
		// Only ever appears as an Expr_Assign target; handled in assign_to_lvalue.
		return raise_or_value(ctx, .E_TYPE)
	}
	return raise_or_value(ctx, .E_TYPE)
}

@(private = "file")
eval_prop_get :: proc(ctx: ^Eval_Context, obj_e, prop_e: compiler.Expr) -> Expr_Result {
	obj_r := eval_expr(ctx, obj_e)
	if obj_r.raised {
		return obj_r
	}
	prop_r := eval_expr(ctx, prop_e)
	if prop_r.raised {
		values.free_var(obj_r.value)
		return prop_r
	}
	defer values.free_var(obj_r.value)
	defer values.free_var(prop_r.value)
	if obj_r.value.type != .Obj || prop_r.value.type != .Str {
		return raise_or_value(ctx, .E_TYPE)
	}
	return call_to_expr(ctx.world.get_prop(ctx.world, obj_r.value.data.obj, prop_r.value.data.str.s))
}

@(private = "file")
eval_verb_call :: proc(ctx: ^Eval_Context, obj_e, verb_e: compiler.Expr, arg_exprs: []compiler.Arg) -> Expr_Result {
	obj_r := eval_expr(ctx, obj_e)
	if obj_r.raised {
		return obj_r
	}
	verb_r := eval_expr(ctx, verb_e)
	if verb_r.raised {
		values.free_var(obj_r.value)
		return verb_r
	}
	args_r := eval_args_as_list(ctx, arg_exprs)
	if args_r.raised {
		values.free_var(obj_r.value)
		values.free_var(verb_r.value)
		return args_r
	}
	defer values.free_var(obj_r.value)
	defer values.free_var(verb_r.value)
	if obj_r.value.type != .Obj || verb_r.value.type != .Str {
		values.free_var(args_r.value)
		return raise_or_value(ctx, .E_TYPE)
	}
	return call_to_expr(ctx.world.call_verb(ctx.world, obj_r.value.data.obj, verb_r.value.data.str.s, args_r.value, ctx))
}

@(private = "file")
eval_call :: proc(ctx: ^Eval_Context, name: string, is_known: bool, arg_exprs: []compiler.Arg) -> Expr_Result {
	args_r := eval_args_as_list(ctx, arg_exprs)
	if args_r.raised {
		return args_r
	}
	return call_to_expr(ctx.world.call_builtin(ctx.world, name, is_known, args_r.value, ctx))
}

// eval_args_as_list evaluates a call/list-literal argument list into a single MOO list,
// splicing `@expr` arguments (which must themselves be lists) in place -- ports
// OP_MAKE_SINGLETON_LIST/OP_LIST_ADD_TAIL/OP_LIST_APPEND/OP_CHECK_LIST_FOR_SPLICE's combined
// effect.
@(private = "file")
eval_args_as_list :: proc(ctx: ^Eval_Context, args: []compiler.Arg) -> Expr_Result {
	result := values.empty_list()
	for a in args {
		item_r := eval_expr(ctx, a.expr)
		if item_r.raised {
			values.free_var(result)
			return item_r
		}
		if a.splice {
			if item_r.value.type != .List {
				values.free_var(item_r.value)
				values.free_var(result)
				return raise_or_value(ctx, .E_TYPE)
			}
			result = values.list_concat(result, item_r.value)
		} else {
			result = values.list_append(result, item_r.value)
		}
	}
	return ok_expr(result)
}

@(private = "file")
eval_list :: proc(ctx: ^Eval_Context, items: []compiler.Arg) -> Expr_Result {
	return eval_args_as_list(ctx, items)
}

@(private = "file")
eval_index :: proc(ctx: ^Eval_Context, base_e, index_e: compiler.Expr) -> Expr_Result {
	base_r := eval_expr(ctx, base_e)
	if base_r.raised {
		return base_r
	}
	append(&ctx.dollar_stack, base_r.value)
	index_r := eval_expr(ctx, index_e)
	pop(&ctx.dollar_stack)
	if index_r.raised {
		values.free_var(base_r.value)
		return index_r
	}
	defer values.free_var(base_r.value)
	defer values.free_var(index_r.value)
	return propagate(ctx, index_get(base_r.value, index_r.value))
}

@(private = "file")
eval_range :: proc(ctx: ^Eval_Context, base_e, from_e, to_e: compiler.Expr) -> Expr_Result {
	base_r := eval_expr(ctx, base_e)
	if base_r.raised {
		return base_r
	}
	append(&ctx.dollar_stack, base_r.value)
	from_r := eval_expr(ctx, from_e)
	if from_r.raised {
		pop(&ctx.dollar_stack)
		values.free_var(base_r.value)
		return from_r
	}
	to_r := eval_expr(ctx, to_e)
	pop(&ctx.dollar_stack)
	if to_r.raised {
		values.free_var(base_r.value)
		values.free_var(from_r.value)
		return to_r
	}
	defer values.free_var(base_r.value)
	defer values.free_var(from_r.value)
	defer values.free_var(to_r.value)
	return propagate(ctx, range_get(base_r.value, from_r.value, to_r.value))
}

@(private = "file")
eval_binary :: proc(ctx: ^Eval_Context, b: ^compiler.Expr_Binary) -> Expr_Result {
	// `and`/`or` short-circuit and yield the actual operand value (not a coerced boolean),
	// ports OP_AND/OP_OR.
	if b.op == .And || b.op == .Or {
		lhs_r := eval_expr(ctx, b.lhs)
		if lhs_r.raised {
			return lhs_r
		}
		lhs_true := values.is_true(lhs_r.value)
		if (b.op == .And && !lhs_true) || (b.op == .Or && lhs_true) {
			return lhs_r
		}
		values.free_var(lhs_r.value)
		return eval_expr(ctx, b.rhs)
	}

	lhs_r := eval_expr(ctx, b.lhs)
	if lhs_r.raised {
		return lhs_r
	}
	rhs_r := eval_expr(ctx, b.rhs)
	if rhs_r.raised {
		values.free_var(lhs_r.value)
		return rhs_r
	}
	defer values.free_var(lhs_r.value)
	defer values.free_var(rhs_r.value)

	switch b.op {
	case .Plus:
		return propagate(ctx, do_add(lhs_r.value, rhs_r.value))
	case .Minus:
		return propagate(ctx, do_subtract(lhs_r.value, rhs_r.value))
	case .Times:
		return propagate(ctx, do_multiply(lhs_r.value, rhs_r.value))
	case .Divide:
		return propagate(ctx, do_divide(lhs_r.value, rhs_r.value))
	case .Mod:
		return propagate(ctx, do_modulus(lhs_r.value, rhs_r.value))
	case .Exp:
		return propagate(ctx, do_power(lhs_r.value, rhs_r.value))
	case .Eq:
		return ok_expr(values.int_val(values.equality(lhs_r.value, rhs_r.value, false) ? 1 : 0))
	case .Ne:
		return ok_expr(values.int_val(values.equality(lhs_r.value, rhs_r.value, false) ? 0 : 1))
	case .Lt, .Le, .Gt, .Ge:
		cmp, err := compare_ordered(lhs_r.value, rhs_r.value)
		if err != .E_NONE {
			return raise_or_value(ctx, err)
		}
		result: bool
		switch b.op {
		case .Lt: result = cmp < 0
		case .Le: result = cmp <= 0
		case .Gt: result = cmp > 0
		case .Ge: result = cmp >= 0
		case .Plus, .Minus, .Times, .Divide, .Mod, .Exp, .And, .Or, .Eq, .Ne, .In:
		}
		return ok_expr(values.int_val(result ? 1 : 0))
	case .In:
		if rhs_r.value.type != .List {
			return raise_or_value(ctx, .E_TYPE)
		}
		return ok_expr(values.int_val(i32(values.is_member(lhs_r.value, rhs_r.value, false))))
	case .And, .Or:
	// handled above
	}
	return raise_or_value(ctx, .E_TYPE)
}

// eval_catch ports EXPR_CATCH: evaluate `try`; on a matching raised error, evaluate the
// `=> handler` if given, else yield the bare error code (ports EXPR_CATCH's codegen: no
// default means "select code from tuple", i.e. index 1).
@(private = "file")
eval_catch :: proc(ctx: ^Eval_Context, c: ^compiler.Expr_Catch) -> Expr_Result {
	saved_debug := ctx.activation.debug
	result := eval_expr(ctx, c.try)
	if !result.raised {
		return result
	}
	if !error_code_matches(ctx, c.codes, result.err.code) {
		return result
	}
	error_info_destroy_local(&result.err)
	_ = saved_debug
	if c.handler != nil {
		return eval_expr(ctx, c.handler)
	}
	return ok_expr(values.err_val(result.err.code))
}

error_info_destroy_local :: proc(e: ^Error_Info) {
	delete(e.msg)
	values.free_var(e.value)
}

// error_code_matches evaluates a `codes` list (nil means ANY) and checks membership,
// mirroring generate_codes()+ismember() at the AST level instead of compiled bytecode.
error_code_matches :: proc(ctx: ^Eval_Context, codes: []compiler.Arg, code: values.Error) -> bool {
	if codes == nil {
		return true
	}
	list_r := eval_args_as_list(ctx, codes)
	if list_r.raised {
		error_info_destroy_local(&list_r.err)
		return false
	}
	defer values.free_var(list_r.value)
	return values.is_member(values.err_val(code), list_r.value, false) != 0
}
