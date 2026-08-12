package builtins

// List and string manipulation, ported from list.c's bf_* implementations. These mostly
// just validate argument shapes and delegate to the values package's list.c ports from
// Phase 0 (values.list_insert/list_delete/list_set/set_add/set_remove/is_member).

import "../values"
import "../vm"
import "core:strings"

bf_length :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 1 {
		return arg_count_error()
	}
	v := nth(args, 1)
	#partial switch v.type {
	case .Str:
		return vm.call_ok(values.int_val(i32(len(v.data.str.s))))
	case .List:
		return vm.call_ok(values.int_val(i32(values.list_len(v))))
	}
	return arg_type_error()
}

// bf_listappend ports listappend(list, value [, pos]) -- inserts after `pos` (default: at
// the end), unlike listinsert's "before pos" convention.
bf_listappend :: proc(args: values.Var) -> vm.Call_Result {
	n := nargs(args)
	if n != 2 && n != 3 {
		values.free_var(args)
		return arg_count_error()
	}
	list := nth(args, 1)
	value := nth(args, 2)
	if list.type != .List {
		values.free_var(args)
		return arg_type_error()
	}
	list_owned := values.var_dup(list)
	value_owned := values.var_ref(value)
	pos := values.list_len(list) + 1
	if n == 3 {
		p := nth(args, 3)
		if p.type != .Int {
			values.free_var(list_owned)
			values.free_var(value_owned)
			values.free_var(args)
			return arg_type_error()
		}
		pos = int(p.data.num) + 1
	}
	values.free_var(args)
	return vm.call_ok(values.list_insert(list_owned, value_owned, pos))
}

bf_listinsert :: proc(args: values.Var) -> vm.Call_Result {
	n := nargs(args)
	if n != 2 && n != 3 {
		values.free_var(args)
		return arg_count_error()
	}
	list := nth(args, 1)
	value := nth(args, 2)
	if list.type != .List {
		values.free_var(args)
		return arg_type_error()
	}
	list_owned := values.var_dup(list)
	value_owned := values.var_ref(value)
	pos := 1
	if n == 3 {
		p := nth(args, 3)
		if p.type != .Int {
			values.free_var(list_owned)
			values.free_var(value_owned)
			values.free_var(args)
			return arg_type_error()
		}
		pos = int(p.data.num)
	}
	values.free_var(args)
	return vm.call_ok(values.list_insert(list_owned, value_owned, pos))
}

bf_listdelete :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 2 {
		return arg_count_error()
	}
	list := nth(args, 1)
	p := nth(args, 2)
	if list.type != .List || p.type != .Int {
		return arg_type_error()
	}
	pos := int(p.data.num)
	if pos < 1 || pos > values.list_len(list) {
		return raise_err(.E_RANGE, "Range error")
	}
	return vm.call_ok(values.list_delete(values.var_dup(list), pos))
}

bf_listset :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 3 {
		return arg_count_error()
	}
	list := nth(args, 1)
	value := nth(args, 2)
	p := nth(args, 3)
	if list.type != .List || p.type != .Int {
		return arg_type_error()
	}
	pos := int(p.data.num)
	if pos < 1 || pos > values.list_len(list) {
		return raise_err(.E_RANGE, "Range error")
	}
	return vm.call_ok(values.list_set(values.var_dup(list), values.var_ref(value), pos))
}

bf_setadd :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 2 {
		return arg_count_error()
	}
	list := nth(args, 1)
	if list.type != .List {
		return arg_type_error()
	}
	return vm.call_ok(values.set_add(values.var_dup(list), values.var_ref(nth(args, 2))))
}

bf_setremove :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 2 {
		return arg_count_error()
	}
	list := nth(args, 1)
	if list.type != .List {
		return arg_type_error()
	}
	return vm.call_ok(values.set_remove(values.var_dup(list), nth(args, 2)))
}

// bf_is_member ports bf_is_member(): case-SENSITIVE (case_matters=1), unlike the `in`
// operator (case-insensitive -- see vm/eval_expr.odin's eval_binary .In case).
bf_is_member :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 2 {
		return arg_count_error()
	}
	list := nth(args, 2)
	if list.type != .List {
		return arg_type_error()
	}
	return vm.call_ok(values.int_val(i32(values.is_member(nth(args, 1), list, true))))
}

bf_strcmp :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 2 {
		return arg_count_error()
	}
	a, b := nth(args, 1), nth(args, 2)
	if a.type != .Str || b.type != .Str {
		return arg_type_error()
	}
	cmp := strings.compare(a.data.str.s, b.data.str.s)
	return vm.call_ok(values.int_val(i32(cmp)))
}

// bf_index/bf_rindex port strindex()/strrindex(): 1-based position of the first/last
// occurrence of `what` in `source`, 0 if absent, case-insensitive unless the 3rd arg is
// true. An empty `what` matches at position 1 (index) / len(source)+1 (rindex) -- real verb
// code does rely on this (e.g. LambdaCore's $site_db trie insert algorithm, where the root
// node's empty common-prefix hits exactly this case); core:strings.index/last_index already
// return the right 0-based answer for an empty substr (0 / len(s)), so no special-casing is
// needed here, just don't override it.
bf_index :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	n := nargs(args)
	if n != 2 && n != 3 {
		return arg_count_error()
	}
	source, what := nth(args, 1), nth(args, 2)
	if source.type != .Str || what.type != .Str {
		return arg_type_error()
	}
	case_matters := n == 3 && values.is_true(nth(args, 3))
	pos: int
	if case_matters {
		pos = strings.index(source.data.str.s, what.data.str.s)
	} else {
		pos = strings.index(strings.to_lower(source.data.str.s, context.temp_allocator), strings.to_lower(what.data.str.s, context.temp_allocator))
	}
	return vm.call_ok(values.int_val(i32(pos + 1)))
}

bf_rindex :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	n := nargs(args)
	if n != 2 && n != 3 {
		return arg_count_error()
	}
	source, what := nth(args, 1), nth(args, 2)
	if source.type != .Str || what.type != .Str {
		return arg_type_error()
	}
	case_matters := n == 3 && values.is_true(nth(args, 3))
	pos: int
	if case_matters {
		pos = strings.last_index(source.data.str.s, what.data.str.s)
	} else {
		pos = strings.last_index(strings.to_lower(source.data.str.s, context.temp_allocator), strings.to_lower(what.data.str.s, context.temp_allocator))
	}
	return vm.call_ok(values.int_val(i32(pos + 1)))
}

// bf_strsub ports strsub(subject, what, with [, case-matters]): replaces every
// non-overlapping occurrence of `what` in `subject` with `with`.
bf_strsub :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	n := nargs(args)
	if n != 3 && n != 4 {
		return arg_count_error()
	}
	subject := nth(args, 1)
	what := nth(args, 2)
	with := nth(args, 3)
	if subject.type != .Str || what.type != .Str || with.type != .Str {
		return arg_type_error()
	}
	if len(what.data.str.s) == 0 {
		return raise_err(.E_INVARG, "Invalid argument")
	}
	case_matters := n == 4 && values.is_true(nth(args, 4))

	haystack := subject.data.str.s
	needle := what.data.str.s
	search_haystack := case_matters ? haystack : strings.to_lower(haystack, context.temp_allocator)
	search_needle := case_matters ? needle : strings.to_lower(needle, context.temp_allocator)

	b := strings.builder_make()
	i := 0
	for i < len(haystack) {
		rest := search_haystack[i:]
		if strings.has_prefix(rest, search_needle) {
			strings.write_string(&b, with.data.str.s)
			i += len(needle)
		} else {
			strings.write_byte(&b, haystack[i])
			i += 1
		}
	}
	return vm.call_ok(values.str_val(strings.to_string(b)))
}
