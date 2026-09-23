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

// nest_ok is the shared guard for the four built-ins that put a value INSIDE a list
// (listappend/listinsert/listset/setadd) -- the builtin-level counterpart to the checks the
// VM applies to `{x}` and `l[i] = v`. Every one of them deepens the result by a level and
// so can be looped to build the pathologically nested values values.MAX_VALUE_DEPTH exists
// to prevent; `grows` additionally covers the ones that lengthen the list, against
// values.MAX_LIST_LEN.
//
// values.nests_too_deep, not `value_depth(value) + 1 > MAX_VALUE_DEPTH`: the cached depth is an
// upper bound that in-place mutation raises and cannot lower, so deciding off it rejected
// values that are not deep at all. See its header for the case and the repro.
//
// values.grows_too_big covers the third limit, MAX_VALUE_SIZE: `x = listappend({x}, x)` in a
// loop doubles x's expanded size per call without ever making it long or deep. `replaced` is
// the element listset overwrites (none_val() for the others, which only add).
@(private = "file")
nest_ok :: proc(list, value, replaced: values.Var, grows: bool) -> bool {
	if values.nests_too_deep(value) {
		return false
	}
	if values.grows_too_big(list, value, replaced, grows) {
		return false
	}
	if grows && values.list_len(list) >= values.MAX_LIST_LEN {
		return false
	}
	return true
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
	if !nest_ok(list, value, values.none_val(), true) {
		values.free_var(args)
		return raise_err(.E_QUOTA, "Value too large")
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
	if !nest_ok(list, value, values.none_val(), true) {
		values.free_var(args)
		return raise_err(.E_QUOTA, "Value too large")
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
	if !nest_ok(list, value, values.list_get(list, pos), false) { // replaces an element, so the list doesn't lengthen
		return raise_err(.E_QUOTA, "Value too large")
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
	if !nest_ok(list, nth(args, 2), values.none_val(), true) {
		return raise_err(.E_QUOTA, "Value too large")
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
		pos = values.ascii_index(source.data.str.s, what.data.str.s)
	} else {
		pos = values.ascii_index_fold(source.data.str.s, what.data.str.s)
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
		pos = values.ascii_last_index(source.data.str.s, what.data.str.s)
	} else {
		pos = values.ascii_last_index_fold(source.data.str.s, what.data.str.s)
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

	// Finding each occurrence with a search, rather than asking "does the needle start here"
	// at every position, is what keeps this linear. The per-position spelling was
	// O(len(haystack) * len(needle)) -- the same product of two MAX_STR_LEN-capped inputs that
	// made index() a server wedge, and reached here by the same route, since the prefix test at
	// each position is itself O(len(needle)). Measured on 400KB of "a" with a 200KB needle that
	// never matches: 29s folding, 0.95s case-sensitive, both for ONE tick with big_lock held.
	// values.ascii_index_fold and values.ascii_index are both worst-case linear now (see their
	// headers), so this loop is O(len(haystack) + len(needle)) overall:
	// rebuilding a search structure per occurrence is bounded by the bytes that occurrence
	// consumes, and occurrences do not overlap.
	b := strings.builder_make()
	i := 0
	for i < len(haystack) {
		// Same doubling guard as tostr/toliteral: `s = strsub(s, "a", "aa")` grew a string past
		// values.MAX_STR_LEN unchecked (measured: 64MB after 26 iterations, and unbounded after
		// that). Checked inside the loop so it stops at the limit instead of after the whole
		// replacement has been materialised; the transient overshoot is one gap plus one
		// replacement, each itself already bounded by MAX_STR_LEN.
		if strings.builder_len(b) > values.MAX_STR_LEN {
			strings.builder_destroy(&b)
			return raise_err(.E_QUOTA, "Value too large")
		}
		rest := haystack[i:]
		pos := values.ascii_index(rest, needle) if case_matters else values.ascii_index_fold(rest, needle)
		if pos < 0 {
			strings.write_string(&b, rest)
			break
		}
		strings.write_string(&b, rest[:pos])
		strings.write_string(&b, with.data.str.s)
		i += pos + len(needle)
	}
	// The loop's guard runs before each write, so the last one can still carry the result past
	// the cap; without this a strsub could hand back a string longer than any other path in the
	// server is willing to build.
	if strings.builder_len(b) > values.MAX_STR_LEN {
		strings.builder_destroy(&b)
		return raise_err(.E_QUOTA, "Value too large")
	}
	return vm.call_ok(values.str_val(strings.to_string(b)))
}
