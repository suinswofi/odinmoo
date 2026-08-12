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
		return call_to_expr(ctx.world.set_prop(ctx.world, obj_r.value.data.obj, prop_r.value.data.str.s, new_value, ctx))

	case ^compiler.Expr_Index:
		return assign_indexed(ctx, target, new_value)

	case ^compiler.Expr_Range:
		return assign_indexed(ctx, target, new_value)

	case ^compiler.Expr_Scatter:
		return exec_scatter(ctx, t.items, new_value)

	case:
		values.free_var(new_value)
		return raise_or_value(ctx, .E_TYPE)
	}
}

// assign_indexed ports code_gen.c's push_lvalue() + the OP_INDEXSET/EOP_RANGESET chain for
// `a[i] = v`, `a[i][j]... = v`, and `a[i..j] = v` -- as ONE pass over the lvalue path, exactly
// like the compiled original:
//
//   - Every index expression is evaluated exactly once (an earlier version re-evaluated the
//     whole base path per nesting level via recursion, so `a[f()][j] = v` could read element
//     f()=k1 but write back at f()=k2 -- observably wrong whenever an index expression has
//     side effects or nondeterminism).
//   - `$` works inside assignment-target indices (`a[$] = v`, `s[2..$] = "xy"`): push_lvalue
//     brackets each index expression with save_stack_top/restore_stack_top so EOP_LENGTH can
//     see the base being indexed; here that's a dollar_stack push around the same evaluation.
//   - Evaluation/deref order matches the opcode stream: push base, eval index, deref (E_RANGE
//     raised here, before any outer index is evaluated), eval next index, ...
//
// Only the outermost step can be a range (the parser's check_assign_lvalue rejects anything
// else), and the chain bottoms out at a variable or property, read once and written once.
@(private = "file")
assign_indexed :: proc(ctx: ^Eval_Context, target: compiler.Expr, new_value: values.Var) -> Expr_Result {
	// Collect the index/range chain, outermost node first, down to the root lvalue.
	steps := make([dynamic]compiler.Expr, 0, 4)
	defer delete(steps)
	root: compiler.Expr = target
	collect: for {
		#partial switch t in root {
		case ^compiler.Expr_Index:
			append(&steps, root)
			root = t.base
		case ^compiler.Expr_Range:
			if len(steps) > 0 {
				// A range anywhere but the outermost position is unreachable through the
				// parser; treat defensively as a type error rather than crashing.
				values.free_var(new_value)
				return raise_or_value(ctx, .E_TYPE)
			}
			append(&steps, root)
			root = t.base
		case:
			break collect
		}
	}
	n := len(steps)

	// Read the root's current value exactly once (OP_PUSH / OP_PUSH_GET_PROP). For a property
	// root, keep the evaluated obj/name so the final write-back doesn't re-evaluate them.
	root_val: values.Var
	root_is_prop := false
	prop_obj, prop_name: values.Var
	#partial switch r in root {
	case ^compiler.Expr_Id:
		v := ctx.activation.locals[r.var_id]
		if v.type == .None {
			values.free_var(new_value)
			return raise_or_value(ctx, .E_VARNF)
		}
		root_val = values.var_ref(v)
	case ^compiler.Expr_Prop:
		obj_r := eval_expr(ctx, r.obj)
		if obj_r.raised {
			values.free_var(new_value)
			return obj_r
		}
		name_r := eval_expr(ctx, r.prop)
		if name_r.raised {
			values.free_var(obj_r.value)
			values.free_var(new_value)
			return name_r
		}
		if obj_r.value.type != .Obj || name_r.value.type != .Str {
			values.free_var(obj_r.value)
			values.free_var(name_r.value)
			values.free_var(new_value)
			return raise_or_value(ctx, .E_TYPE)
		}
		get_r := ctx.world.get_prop(ctx.world, obj_r.value.data.obj, name_r.value.data.str.s, ctx)
		if get_r.raised {
			values.free_var(obj_r.value)
			values.free_var(name_r.value)
			values.free_var(new_value)
			return call_to_expr(get_r)
		}
		root_is_prop = true
		prop_obj = obj_r.value
		prop_name = name_r.value
		root_val = get_r.value
	case:
		values.free_var(new_value)
		return raise_or_value(ctx, .E_TYPE)
	}

	// Descend from the root, evaluating each intermediate step's index once (with the base
	// visible to `$`) and dereferencing (OP_PUSH_REF). bases[k]/indices[k] are owned here
	// until consumed by the re-assembly below.
	bases := make([]values.Var, n)
	indices := make([]values.Var, n) // only [1..n-1] used; [0] belongs to the final set below
	defer delete(bases)
	defer delete(indices)
	// Frees bases[bases_from..] and indices[indices_from..] (whatever is still owned at the
	// failure point -- the two ranges genuinely differ between call sites, since index_set/
	// range_set consume their arguments even on error), plus the property root's obj/name.
	cleanup_descent :: proc(bases, indices: []values.Var, bases_from, indices_from: int, root_is_prop: bool, prop_obj, prop_name: values.Var) {
		for k := bases_from; k < len(bases); k += 1 {
			values.free_var(bases[k])
		}
		for k := max(indices_from, 1); k < len(indices); k += 1 {
			values.free_var(indices[k])
		}
		if root_is_prop {
			values.free_var(prop_obj)
			values.free_var(prop_name)
		}
	}

	bases[n - 1] = root_val
	for k := n - 1; k >= 1; k -= 1 {
		step := steps[k].(^compiler.Expr_Index) // intermediate steps are always plain indexes
		append(&ctx.dollar_stack, bases[k])
		idx_r := eval_expr(ctx, step.index)
		pop(&ctx.dollar_stack)
		if idx_r.raised {
			cleanup_descent(bases, indices, k, k + 1, root_is_prop, prop_obj, prop_name)
			values.free_var(new_value)
			return idx_r
		}
		indices[k] = idx_r.value
		elem := index_get(bases[k], indices[k])
		if elem.err != .E_NONE {
			values.free_var(indices[k])
			cleanup_descent(bases, indices, k, k + 1, root_is_prop, prop_obj, prop_name)
			values.free_var(new_value)
			return raise_or_value(ctx, elem.err)
		}
		bases[k - 1] = elem.value
	}

	// The assignment expression's value is v itself, not the rebuilt container -- take our
	// reference before the set consumes new_value.
	result_value := values.var_ref(new_value)

	// Apply the outermost set (OP_INDEXSET / EOP_RANGESET), still with `$` visible.
	updated: Op_Result
	#partial switch s0 in steps[0] {
	case ^compiler.Expr_Index:
		append(&ctx.dollar_stack, bases[0])
		idx_r := eval_expr(ctx, s0.index)
		pop(&ctx.dollar_stack)
		if idx_r.raised {
			values.free_var(result_value)
			cleanup_descent(bases, indices, 0, 1, root_is_prop, prop_obj, prop_name)
			values.free_var(new_value)
			return idx_r
		}
		updated = index_set(bases[0], idx_r.value, new_value) // consumes bases[0], idx, new_value
	case ^compiler.Expr_Range:
		append(&ctx.dollar_stack, bases[0])
		from_r := eval_expr(ctx, s0.from)
		if from_r.raised {
			pop(&ctx.dollar_stack)
			values.free_var(result_value)
			cleanup_descent(bases, indices, 0, 1, root_is_prop, prop_obj, prop_name)
			values.free_var(new_value)
			return from_r
		}
		to_r := eval_expr(ctx, s0.to)
		pop(&ctx.dollar_stack)
		if to_r.raised {
			values.free_var(from_r.value)
			values.free_var(result_value)
			cleanup_descent(bases, indices, 0, 1, root_is_prop, prop_obj, prop_name)
			values.free_var(new_value)
			return to_r
		}
		updated = range_set(bases[0], from_r.value, to_r.value, new_value) // consumes all four
	}
	if updated.err != .E_NONE {
		values.free_var(result_value)
		cleanup_descent(bases, indices, 1, 1, root_is_prop, prop_obj, prop_name)
		return raise_or_value(ctx, updated.err)
	}

	// Re-assemble upward: splice each rebuilt container back into its parent (the INDEXSET
	// chain the original unwinds). These can't fail -- every index was validated against the
	// very container it's being written back into.
	t := updated.value
	for k in 1 ..< n {
		r := index_set(bases[k], indices[k], t) // consumes bases[k], indices[k], t
		if r.err != .E_NONE {
			values.free_var(result_value)
			cleanup_descent(bases, indices, k + 1, k + 1, root_is_prop, prop_obj, prop_name)
			return raise_or_value(ctx, r.err)
		}
		t = r.value
	}

	// Write the rebuilt root back (OP_PUT / OP_PUT_PROP).
	#partial switch r in root {
	case ^compiler.Expr_Id:
		values.free_var(ctx.activation.locals[r.var_id])
		ctx.activation.locals[r.var_id] = t
	case ^compiler.Expr_Prop:
		set_r := ctx.world.set_prop(ctx.world, prop_obj.data.obj, prop_name.data.str.s, t, ctx)
		values.free_var(prop_obj)
		values.free_var(prop_name)
		if set_r.raised {
			values.free_var(result_value)
			return call_to_expr(set_r)
		}
		values.free_var(set_r.value)
	}

	return ok_expr(result_value)
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
