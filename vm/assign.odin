package vm

// Assignment-target handling, ported from code_gen.c's EXPR_ASGN lvalue dispatch
// (OP_PUT / OP_PUT_PROP / the INDEXSET-then-recurse chain for `a[i]...[j] = v`) and
// EOP_SCATTER for `{...} = v`. assign_to_lvalue takes ownership of `new_value` and returns
// it back out (still owned by the caller) as the result of the assignment expression --
// matches MOO's `a = b = 5` chaining, where the whole expression's value is 5.

import "../compiler"
import "../values"

assign_to_lvalue :: proc(ctx: ^Eval_Context, target: compiler.Expr, new_value: values.Var) -> Expr_Result {
	#partial switch t in target {
	case ^compiler.Expr_Id:
		old := ctx.activation.locals[t.var_id]
		values.free_var(old)
		ctx.activation.locals[t.var_id] = values.var_ref(new_value)
		return ok_expr(new_value)

	case ^compiler.Expr_Prop:
		obj_r := eval_expr(ctx, t.obj)
		if obj_r.raised {
			values.free_var(new_value)
			return obj_r
		}
		prop_r := eval_expr(ctx, t.prop)
		if prop_r.raised {
			values.free_var(obj_r.value)
			values.free_var(new_value)
			return prop_r
		}
		defer values.free_var(obj_r.value)
		defer values.free_var(prop_r.value)
		if obj_r.value.type != .Obj || prop_r.value.type != .Str {
			values.free_var(new_value)
			return raise_or_value(ctx, .E_TYPE)
		}
		return call_to_expr(ctx.world.set_prop(ctx.world, obj_r.value.data.obj, prop_r.value.data.str.s, new_value))

	case ^compiler.Expr_Index:
		base_r := eval_expr(ctx, t.base)
		if base_r.raised {
			values.free_var(new_value)
			return base_r
		}
		index_r := eval_expr(ctx, t.index)
		if index_r.raised {
			values.free_var(base_r.value)
			values.free_var(new_value)
			return index_r
		}
		// `a[i] = v` evaluates to v (the element value), not to the rebuilt container --
		// take our own reference before index_set() consumes new_value into the rebuilt
		// list, since assign_to_lvalue's recursive call below returns THAT (the whole
		// container) as its own result, which is the wrong value for this expression.
		result_value := values.var_ref(new_value)
		updated := index_set(base_r.value, index_r.value, new_value)
		if updated.err != .E_NONE {
			values.free_var(result_value)
			return raise_or_value(ctx, updated.err)
		}
		inner := assign_to_lvalue(ctx, t.base, updated.value)
		if inner.raised {
			values.free_var(result_value)
			return inner
		}
		values.free_var(inner.value)
		return ok_expr(result_value)

	case ^compiler.Expr_Range:
		base_r := eval_expr(ctx, t.base)
		if base_r.raised {
			values.free_var(new_value)
			return base_r
		}
		from_r := eval_expr(ctx, t.from)
		if from_r.raised {
			values.free_var(base_r.value)
			values.free_var(new_value)
			return from_r
		}
		to_r := eval_expr(ctx, t.to)
		if to_r.raised {
			values.free_var(base_r.value)
			values.free_var(from_r.value)
			values.free_var(new_value)
			return to_r
		}
		// Same reasoning as Expr_Index above: `a[i..j] = v` evaluates to v, not to the
		// rebuilt container.
		result_value := values.var_ref(new_value)
		updated := range_set(base_r.value, from_r.value, to_r.value, new_value)
		if updated.err != .E_NONE {
			values.free_var(result_value)
			return raise_or_value(ctx, updated.err)
		}
		inner := assign_to_lvalue(ctx, t.base, updated.value)
		if inner.raised {
			values.free_var(result_value)
			return inner
		}
		values.free_var(inner.value)
		return ok_expr(result_value)

	case ^compiler.Expr_Scatter:
		return exec_scatter(ctx, t.items, new_value)

	case:
		values.free_var(new_value)
		return raise_or_value(ctx, .E_TYPE)
	}
}

// exec_scatter ports EOP_SCATTER's binding algorithm (see the comment on the original in
// execute.c): required items bind positionally, one rest item (if any) absorbs however many
// elements are left over, and optional items bind if a value remains or evaluate their
// default otherwise. `value` is consumed; the scattered list itself is the result (matching
// `{a,b} = {1,2}` evaluating to `{1,2}`, not to a or b).
exec_scatter :: proc(ctx: ^Eval_Context, items: []compiler.Scatter_Item, value: values.Var) -> Expr_Result {
	if value.type != .List {
		values.free_var(value)
		return raise_or_value(ctx, .E_TYPE)
	}

	rest_idx := -1
	nreq := 0
	for it, i in items {
		if it.kind == .Rest {
			rest_idx = i
		}
		if it.kind == .Required {
			nreq += 1
		}
	}
	n := len(items)
	have_rest := rest_idx >= 0
	list_len := values.list_len(value)

	if list_len < nreq || (!have_rest && list_len > n) {
		values.free_var(value)
		return raise_or_value(ctx, .E_ARGS)
	}

	nopt_avail := list_len - nreq
	nrest := (have_rest && list_len >= n) ? (list_len - n + 1) : 0
	pos := 1

	for it, i in items {
		if i == rest_idx {
			bound := values.sub_list(values.var_ref(value), pos, pos + nrest - 1)
			bind_scatter_var(ctx, it.var_id, bound)
			pos += nrest
			continue
		}
		switch it.kind {
		case .Required:
			bind_scatter_var(ctx, it.var_id, values.var_ref(values.list_get(value, pos)))
			pos += 1
		case .Optional:
			if nopt_avail > 0 {
				nopt_avail -= 1
				bind_scatter_var(ctx, it.var_id, values.var_ref(values.list_get(value, pos)))
				pos += 1
			} else if it.default != nil {
				def_r := eval_expr(ctx, it.default)
				if def_r.raised {
					values.free_var(value)
					return def_r
				}
				bind_scatter_var(ctx, it.var_id, def_r.value)
			}
		// else: no value available and no default -- variable slot left untouched,
		// matching the original (only assigns rt_env when it actually has a value).
		case .Rest:
		// handled via the `i == rest_idx` branch above
		}
	}

	return ok_expr(value)
}

@(private = "file")
bind_scatter_var :: proc(ctx: ^Eval_Context, var_id: int, v: values.Var) {
	values.free_var(ctx.activation.locals[var_id])
	ctx.activation.locals[var_id] = v
}
