package builtins

// match()/rmatch()/substitute(), ported from list.c's do_match()/bf_substitute() on top of
// the ../regex package (see its header for what MOO pattern syntax it does/doesn't cover).

import "../regex"
import "../values"
import "../vm"
import "core:strings"

bf_match :: proc(args: values.Var) -> vm.Call_Result {
	return do_match(args, false)
}

bf_rmatch :: proc(args: values.Var) -> vm.Call_Result {
	return do_match(args, true)
}

@(private = "file")
do_match :: proc(args: values.Var, reverse: bool) -> vm.Call_Result {
	defer values.free_var(args)
	n := nargs(args)
	if n != 2 && n != 3 {
		return arg_count_error()
	}
	subject_v, pattern_v := nth(args, 1), nth(args, 2)
	if subject_v.type != .Str || pattern_v.type != .Str {
		return arg_type_error()
	}
	case_matters := n == 3 && values.is_true(nth(args, 3))

	prog, ok := regex.compile(pattern_v.data.str.s)
	if !ok {
		return raise_err(.E_INVARG, "Invalid pattern")
	}
	defer regex.program_destroy(&prog)

	res := regex.match_pattern(&prog, subject_v.data.str.s, reverse, !case_matters)
	if !res.found {
		return vm.call_ok(values.empty_list())
	}

	// Ports do_match()'s 0-based-half-open -> 1-based-closed conversion: start+1, end
	// unchanged (see list.c's Match_Indices assembly). A group that never participated gets
	// the {0, -1} sentinel invalid_pair() treats as "unused", not {1, 0}.
	groups := make([]values.Var, 9)
	for i in 0 ..< 9 {
		g := res.groups[i]
		pair := make([]values.Var, 2)
		if g[0] < 0 {
			pair[0] = values.int_val(0)
			pair[1] = values.int_val(-1)
		} else {
			pair[0] = values.int_val(i32(g[0] + 1))
			pair[1] = values.int_val(i32(g[1]))
		}
		groups[i] = values.list_val(pair)
	}
	result := make([]values.Var, 4)
	result[0] = values.int_val(i32(res.start + 1))
	result[1] = values.int_val(i32(res.end))
	result[2] = values.list_val(groups)
	result[3] = values.str_val(strings.clone(subject_v.data.str.s))
	return vm.call_ok(values.list_val(result))
}

// bf_substitute ports list.c's bf_substitute(): `template` may contain %0-%9 (whole
// match / group N, using subs's 1-based-closed indices back into subs's own subject string)
// and %% (literal '%'). subs is the 4-element list match()/rmatch() returns.
bf_substitute :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 2 {
		return arg_count_error()
	}
	template_v, subs_v := nth(args, 1), nth(args, 2)
	if template_v.type != .Str || subs_v.type != .List {
		return arg_type_error()
	}
	if values.list_len(subs_v) != 4 {
		return raise_err(.E_INVARG, "Invalid subs list")
	}
	start_v := values.list_get(subs_v, 1)
	end_v := values.list_get(subs_v, 2)
	groups_v := values.list_get(subs_v, 3)
	subject_v := values.list_get(subs_v, 4)
	if start_v.type != .Int || end_v.type != .Int || groups_v.type != .List ||
	   subject_v.type != .Str || values.list_len(groups_v) != 9 {
		return raise_err(.E_INVARG, "Invalid subs list")
	}
	subject := subject_v.data.str.s

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	t := template_v.data.str.s
	i := 0
	for i < len(t) {
		c := t[i]
		if c != '%' {
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		i += 1
		if i >= len(t) {
			return raise_err(.E_INVARG, "Invalid substitution template")
		}
		e := t[i]
		i += 1
		if e == '%' {
			strings.write_byte(&b, '%')
			continue
		}
		start, end: int
		if e >= '1' && e <= '9' {
			pair := values.list_get(groups_v, int(e - '0'))
			if pair.type != .List || values.list_len(pair) != 2 {
				return raise_err(.E_INVARG, "Invalid subs list")
			}
			sp, ep := values.list_get(pair, 1), values.list_get(pair, 2)
			if sp.type != .Int || ep.type != .Int {
				return raise_err(.E_INVARG, "Invalid subs list")
			}
			start, end = int(sp.data.num) - 1, int(ep.data.num) - 1
		} else if e == '0' {
			start, end = int(start_v.data.num) - 1, int(end_v.data.num) - 1
		} else {
			return raise_err(.E_INVARG, "Invalid substitution template")
		}
		for start <= end {
			if start < 0 || start >= len(subject) {
				return raise_err(.E_INVARG, "Invalid subs list")
			}
			strings.write_byte(&b, subject[start])
			start += 1
		}
	}
	return vm.call_ok(values.str_val(strings.clone(strings.to_string(b))))
}
