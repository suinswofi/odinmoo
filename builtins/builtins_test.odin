package builtins

import "../values"
import "../vm"
import "core:strings"
import "core:testing"

@(private = "file")
mklist :: proc(items: ..values.Var) -> values.Var {
	arr := make([]values.Var, len(items))
	copy(arr, items)
	return values.list_val(arr)
}

@(private = "file")
call_int :: proc(t: ^testing.T, name: string, args: values.Var) -> i32 {
	r, found := call(name, args)
	testing.expectf(t, found, "builtin %q not found", name)
	if !found {
		return 0
	}
	defer if r.raised {
		delete(r.msg)
		values.free_var(r.rvalue)
	} else {
		values.free_var(r.value)
	}
	if !testing.expectf(t, !r.raised, "%s: unexpected raise %v (%s)", name, r.code, r.msg) {
		return 0
	}
	testing.expectf(t, r.value.type == .Int, "%s: expected Int result, got %v", name, r.value.type)
	return r.value.data.num
}

@(private = "file")
call_str :: proc(t: ^testing.T, name: string, args: values.Var) -> string {
	r, found := call(name, args)
	testing.expect(t, found)
	defer if r.raised {
		delete(r.msg)
		values.free_var(r.rvalue)
	} else {
		values.free_var(r.value)
	}
	if !testing.expectf(t, !r.raised, "%s: unexpected raise %v (%s)", name, r.code, r.msg) {
		return ""
	}
	testing.expectf(t, r.value.type == .Str, "%s: expected Str result, got %v", name, r.value.type)
	return r.value.data.str.s
}

@(private = "file")
expect_raises :: proc(t: ^testing.T, name: string, args: values.Var, code: values.Error) {
	r, found := call(name, args)
	testing.expect(t, found)
	defer if r.raised {
		delete(r.msg)
		values.free_var(r.rvalue)
	} else {
		values.free_var(r.value)
	}
	testing.expectf(t, r.raised && r.code == code, "%s: expected raise %v, got raised=%v code=%v", name, code, r.raised, r.code)
}

@(test)
test_typeof :: proc(t: ^testing.T) {
	testing.expect(t, call_int(t, "typeof", mklist(values.int_val(5))) == i32(values.Var_Type.Int))
	testing.expect(t, call_int(t, "typeof", mklist(values.str_val(values.clone_string("x")))) == i32(values.Var_Type.Str))
}

@(test)
test_tostr_concatenates_without_quotes :: proc(t: ^testing.T) {
	s := call_str(t, "tostr", mklist(values.str_val(values.clone_string("n=")), values.int_val(5), values.obj_val(3)))
	testing.expect(t, s == "n=5#3")
}

@(test)
test_toliteral_quotes_and_recurses_lists :: proc(t: ^testing.T) {
	inner := mklist(values.int_val(1), values.str_val(values.clone_string("a\"b")))
	s := call_str(t, "toliteral", mklist(inner))
	testing.expect(t, s == `{1, "a\"b"}`)
}

@(test)
test_toint_conversions :: proc(t: ^testing.T) {
	testing.expect(t, call_int(t, "toint", mklist(values.str_val(values.clone_string("42")))) == 42)
	testing.expect(t, call_int(t, "toint", mklist(values.float_val(3.9))) == 3)
	testing.expect(t, call_int(t, "toint", mklist(values.obj_val(7))) == 7)
	testing.expect(t, call_int(t, "toint", mklist(values.str_val(values.clone_string("not a number")))) == 0)
}

@(test)
test_equal_is_case_sensitive_unlike_eq_operator :: proc(t: ^testing.T) {
	testing.expect(t, call_int(t, "equal", mklist(values.str_val(values.clone_string("ABC")), values.str_val(values.clone_string("abc")))) == 0)
	testing.expect(t, call_int(t, "equal", mklist(values.str_val(values.clone_string("abc")), values.str_val(values.clone_string("abc")))) == 1)
}

@(test)
test_list_operations :: proc(t: ^testing.T) {
	testing.expect(t, call_int(t, "length", mklist(mklist(values.int_val(1), values.int_val(2), values.int_val(3)))) == 3)

	r, _ := call("listappend", mklist(mklist(values.int_val(1), values.int_val(2)), values.int_val(3)))
	defer values.free_var(r.value)
	testing.expect(t, values.list_len(r.value) == 3)
	testing.expect(t, values.list_get(r.value, 3).data.num == 3)

	r2, _ := call("listdelete", mklist(mklist(values.int_val(1), values.int_val(2), values.int_val(3)), values.int_val(2)))
	defer values.free_var(r2.value)
	testing.expect(t, values.list_len(r2.value) == 2)
	testing.expect(t, values.list_get(r2.value, 2).data.num == 3)
}

@(test)
test_is_member_case_sensitive :: proc(t: ^testing.T) {
	l := mklist(values.str_val(values.clone_string("ABC")))
	testing.expect(t, call_int(t, "is_member", mklist(values.str_val(values.clone_string("abc")), l)) == 0)
}

@(test)
test_index_and_rindex :: proc(t: ^testing.T) {
	testing.expect(t, call_int(t, "index", mklist(values.str_val(values.clone_string("hello world")), values.str_val(values.clone_string("world")))) == 7)
	testing.expect(t, call_int(t, "index", mklist(values.str_val(values.clone_string("hello")), values.str_val(values.clone_string("xyz")))) == 0)
	testing.expect(t, call_int(t, "rindex", mklist(values.str_val(values.clone_string("abcabc")), values.str_val(values.clone_string("abc")))) == 4)
}

@(test)
test_strsub :: proc(t: ^testing.T) {
	s := call_str(t, "strsub", mklist(values.str_val(values.clone_string("hello world")), values.str_val(values.clone_string("world")), values.str_val(values.clone_string("there"))))
	testing.expect(t, s == "hello there")
}

@(test)
test_math_functions :: proc(t: ^testing.T) {
	r, _ := call("abs", mklist(values.int_val(-5)))
	defer values.free_var(r.value)
	testing.expect(t, r.value.data.num == 5)

	r2, _ := call("max", mklist(values.int_val(3), values.int_val(7), values.int_val(1)))
	defer values.free_var(r2.value)
	testing.expect(t, r2.value.data.num == 7)

	r3, _ := call("sqrt", mklist(values.float_val(16.0)))
	defer values.free_var(r3.value)
	testing.expect(t, r3.value.data.fnum == 4.0)
}

@(test)
test_random_within_bounds :: proc(t: ^testing.T) {
	r, _ := call("random", mklist(values.int_val(10)))
	defer values.free_var(r.value)
	testing.expect(t, r.value.data.num >= 1 && r.value.data.num <= 10)
}

@(test)
test_raise_builtin :: proc(t: ^testing.T) {
	expect_raises(t, "raise", mklist(values.err_val(.E_PERM)), .E_PERM)
}

@(test)
test_arity_and_type_errors :: proc(t: ^testing.T) {
	expect_raises(t, "typeof", mklist(), .E_ARGS)
	expect_raises(t, "length", mklist(values.int_val(5)), .E_TYPE)
	expect_raises(t, "listdelete", mklist(mklist(values.int_val(1)), values.int_val(5)), .E_RANGE)
}

@(test)
test_ansi_builtins :: proc(t: ^testing.T) {
	s1 := call_str(t, "ansi_strip", mklist(values.str_val(values.clone_string("%rRed%n text"))))
	testing.expect(t, s1 == "Red text")

	testing.expect(t, call_int(t, "ansi_len", mklist(values.str_val(values.clone_string("%rRed%n")))) == 3)

	s2 := call_str(t, "ansify", mklist(values.str_val(values.clone_string("%rRed%n"))))
	testing.expect(t, s2 == "\x1b[31mRed\x1b[0m")
}

@(test)
test_unknown_builtin_not_found :: proc(t: ^testing.T) {
	// call() only consumes `args` when a builtin is actually found -- that's what lets
	// objdb/world.odin's dispatcher chain builtins.call() into its own object-aware
	// fallback table using the SAME args on a "not found" result without a double-free.
	// A caller that doesn't chain further must free args itself, as here.
	args := mklist()
	_, found := call("this_does_not_exist", args)
	testing.expect(t, !found)
	values.free_var(args)
}

// tostr(), strsub() and toliteral() all concatenate, so each is a doubling construction:
// `s = tostr(s, s)` in a loop reached 64MB -- four times values.MAX_STR_LEN -- while the `+`
// operator's guard in vm/value_ops.odin sat there doing nothing, because none of these go
// through it. Each must refuse to build past the cap.
@(test)
test_string_builders_respect_max_str_len :: proc(t: ^testing.T) {
	big := strings.repeat("x", values.MAX_STR_LEN)
	defer delete(big)

	// tostr: two near-limit arguments would concatenate to twice the limit.
	a1 := make([]values.Var, 2)
	a1[0] = values.str_val(strings.clone(big))
	a1[1] = values.str_val(strings.clone(big))
	r1 := call_builtin(t, "tostr", a1)
	expect_raised(t, r1, .E_QUOTA, "tostr")

	// strsub: every "x" becomes "xx", doubling a near-limit subject.
	a2 := make([]values.Var, 3)
	a2[0] = values.str_val(strings.clone(big))
	a2[1] = values.str_val(strings.clone("x"))
	a2[2] = values.str_val(strings.clone("xx"))
	r2 := call_builtin(t, "strsub", a2)
	expect_raised(t, r2, .E_QUOTA, "strsub")

	// toliteral: quoting a near-limit string of quote characters roughly doubles it.
	quotes := strings.repeat("\"", values.MAX_STR_LEN)
	defer delete(quotes)
	a3 := make([]values.Var, 1)
	a3[0] = values.str_val(strings.clone(quotes))
	r3 := call_builtin(t, "toliteral", a3)
	expect_raised(t, r3, .E_QUOTA, "toliteral")
}

// The guards must not disturb ordinary use.
@(test)
test_string_builders_still_work_normally :: proc(t: ^testing.T) {
	a1 := make([]values.Var, 3)
	a1[0] = values.str_val(strings.clone("ab"))
	a1[1] = values.int_val(1)
	a1[2] = values.obj_val(2)
	r1 := call_builtin(t, "tostr", a1)
	testing.expect(t, !r1.raised)
	testing.expectf(t, r1.value.type == .Str && r1.value.data.str.s == "ab1#2", "got %v", r1.value)
	values.free_var(r1.value)

	a2 := make([]values.Var, 3)
	a2[0] = values.str_val(strings.clone("banana"))
	a2[1] = values.str_val(strings.clone("an"))
	a2[2] = values.str_val(strings.clone("AN"))
	r2 := call_builtin(t, "strsub", a2)
	testing.expect(t, !r2.raised)
	testing.expectf(t, r2.value.type == .Str && r2.value.data.str.s == "bANANa", "got %v", r2.value)
	values.free_var(r2.value)
}

@(private = "file")
call_builtin :: proc(t: ^testing.T, name: string, args: []values.Var) -> vm.Call_Result {
	r, found := call(name, values.list_val(args))
	testing.expectf(t, found, "%s should be a known built-in", name)
	return r
}

@(private = "file")
expect_raised :: proc(t: ^testing.T, r: vm.Call_Result, want: values.Error, label: string) {
	if !testing.expectf(t, r.raised, "%s: expected a raise, got %v", label, r.value) {
		values.free_var(r.value)
		return
	}
	testing.expectf(t, r.code == want, "%s: want %v, got %v", label, want, r.code)
	delete(r.msg)
	values.free_var(r.rvalue)
}
