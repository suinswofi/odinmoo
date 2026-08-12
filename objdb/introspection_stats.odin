package objdb

// Misc introspection/stats built-ins: floatstr() (numbers.c), value_bytes()/object_bytes()
// (list.c/objects.c, backed by utils.c's value_bytes()/db_objects.c's db_object_bytes()),
// memory_usage() (server.c, backed by storage.c's memory_usage()), function_info()/
// call_function() (functions.c/execute.c).

import "../compiler"
import "../dbfile"
import "../values"
import "../vm"
import "core:fmt"
import "core:strings"

// bf_floatstr ports numbers.c's bf_floatstr(): (float, precision, [sci-notation]) -> a
// %.<prec>f or %.<prec>e formatted string, precision clamped to DBL_DIG+4 (19) like the
// original.
bf_floatstr :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	n := values.list_len(args)
	if n < 2 || n > 3 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	f_v, prec_v := values.list_get(args, 1), values.list_get(args, 2)
	if f_v.type != .Float || prec_v.type != .Int {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	prec := int(prec_v.data.num)
	if prec < 0 {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	if prec > 19 {
		prec = 19
	}
	use_sci := n == 3 && values.is_true(values.list_get(args, 3))
	text := fmt.tprintf("%.*e", prec, f_v.data.fnum) if use_sci else fmt.tprintf("%.*f", prec, f_v.data.fnum)
	return ok_result(values.str_val(strings.clone(text)))
}

// bf_value_bytes ports list.c's bf_value_bytes(), via utils.c's value_bytes(): an estimate of
// the Var's own storage footprint. Uses this port's real Odin type sizes (size_of(values.Var),
// not the C struct layout) -- a like-for-like "how big is this value" estimate, not a
// byte-exact match against the original's C struct sizes (which would be meaningless here
// anyway, the memory layouts are entirely different).
bf_value_bytes :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	return ok_result(values.int_val(i32(value_byte_estimate(values.list_get(args, 1)))))
}

@(private = "file")
value_byte_estimate :: proc(v: values.Var) -> int {
	size := size_of(values.Var)
	#partial switch v.type {
	case .Str:
		size += len(v.data.str.s) + 1
	case .Float:
		size += size_of(f64)
	case .List:
		size += size_of(values.Var)
		n := values.list_len(v)
		for i in 1 ..= n {
			size += value_byte_estimate(values.list_get(v, i))
		}
	}
	return size
}

// bf_object_bytes ports objects.c's bf_object_bytes(), via db_objects.c's db_object_bytes():
// same "real Odin struct sizes, not the C ones" approximation as bf_value_bytes -- see its
// comment. Wizard-only, matching the original.
bf_object_bytes :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	if !is_wizard(w.db, ctx.activation.programmer) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	obj, ok := w.db.objects[v.data.obj]
	if !ok {
		return err_result_local(.E_INVIND, "Invalid indirection")
	}

	count := size_of(dbfile.Object)
	count += len(obj.name) + 1
	for vd in obj.verbdefs {
		count += size_of(dbfile.Verbdef)
		count += len(vd.name) + 1
		count += len(vd.program_source)
	}
	for pd in obj.propdefs {
		count += size_of(dbfile.Propdef)
		count += len(pd.name) + 1
	}
	for pv in obj.propvals {
		count += size_of(dbfile.Propval)
		count += value_byte_estimate(pv.value)
	}
	return ok_result(values.int_val(i32(count)))
}

// bf_memory_usage ports server.c's bf_memory_usage(), via storage.c's memory_usage(): the
// original only reports non-empty data when built against its bundled GNU malloc's block-size
// histogram (USE_GNU_MALLOC); without it -- the case this port's build targets, using Odin's
// own allocator, see the top-level plan's "modern minimal" scope note -- it returns an empty
// list. Matches that default (non-GNU-malloc) behavior exactly.
bf_memory_usage :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 0 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	return ok_result(values.empty_list())
}

// function_description builds the {name, minargs, maxargs, {arg-type-prototype...}} tuple
// function_info() reports. This port doesn't retain a real per-builtin arg-count/type table
// (unlike the original's bf_table -- see compiler/builtins_list.odin's header, which explains
// why only *names* were ever needed through Phase 2-5), so minargs/maxargs/prototype are
// honest placeholders (0, -1, {}) rather than fabricated numbers -- real LambdaCore verb code
// only actually depends on function_info() to check *whether a name exists*
// ($wiz_utils-style `function_info(name) ! E_INVARG => 0` existence probes), never on the
// arg-count details, so this is a deliberate, narrow approximation, not a silent gap.
@(private = "file")
function_description :: proc(name: string) -> values.Var {
	fields := make([]values.Var, 4)
	fields[0] = values.str_val(strings.clone(name))
	fields[1] = values.int_val(0)
	fields[2] = values.int_val(-1)
	fields[3] = values.empty_list()
	return values.list_val(fields)
}

// bf_function_info ports functions.c's bf_function_info(): with no argument, every known
// builtin's description; with a name, that one's -- or E_INVARG if it's not a recognized
// builtin name (checked against compiler.known_builtin_functions, the single canonical name
// list this whole port already uses for parsing).
bf_function_info :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	n := values.list_len(args)
	if n > 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	if n == 0 {
		items := make([]values.Var, len(compiler.known_builtin_functions))
		i := 0
		for name in compiler.known_builtin_functions {
			items[i] = function_description(name)
			i += 1
		}
		return ok_result(values.list_val(items))
	}
	name_v := values.list_get(args, 1)
	if name_v.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	if !compiler.is_known_builtin(name_v.data.str.s) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	return ok_result(function_description(name_v.data.str.s))
}

// bf_call_function ports execute.c's bf_call_function(): call_function(name, @args) dispatches
// to the named builtin exactly as if it had been called directly (name(@args)) -- reuses the
// same dispatch chain (builtins' pure table, then this package's own object-aware set, then
// the scheduler's) that an ordinary Expr_Call already goes through, via ctx.world.call_builtin.
bf_call_function :: proc(args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	n := values.list_len(args)
	if n < 1 {
		values.free_var(args)
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	name_v := values.list_get(args, 1)
	if name_v.type != .Str {
		values.free_var(args)
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	fname := strings.clone(name_v.data.str.s)
	defer delete(fname)
	if !compiler.is_known_builtin(fname) {
		name_ref := values.var_ref(name_v)
		values.free_var(args)
		return vm.Call_Result{raised = true, code = .E_INVARG, msg = strings.clone("Unknown built-in function"), rvalue = name_ref}
	}

	rest_items := make([]values.Var, n - 1)
	for i in 2 ..= n {
		rest_items[i - 2] = values.var_ref(values.list_get(args, i))
	}
	rest := values.list_val(rest_items)
	values.free_var(args)
	return ctx.world.call_builtin(ctx.world, fname, true, rest, ctx)
}
