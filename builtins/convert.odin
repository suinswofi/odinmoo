package builtins

// Type conversion / inspection, ported from numbers.c's become_integer()/become_float()
// (toint/tofloat/toobj) and list.c's bf_tostr()/bf_toliteral()/bf_equal().

import "../compiler"
import "../values"
import "../vm"
import "core:fmt"
import "core:strconv"
import "core:strings"

bf_typeof :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 1 {
		return arg_count_error()
	}
	return vm.call_ok(values.int_val(i32(nth(args, 1).type)))
}

// bf_tostr ports stream_add_tostr()'s per-type formatting, applied to every argument and
// concatenated with no separator: INT decimal, OBJ "#N", STR raw (no quotes), ERR its
// English message (not the E_FOO token -- that's toliteral's job), FLOAT "%g", LIST the
// literal marker text "{list}" (not recursively expanded).
bf_tostr :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	b := strings.builder_make()
	for i in 1 ..= nargs(args) {
		v := nth(args, i)
		#partial switch v.type {
		case .Int:
			fmt.sbprintf(&b, "%d", v.data.num)
		case .Obj:
			fmt.sbprintf(&b, "#%d", v.data.obj)
		case .Str:
			strings.write_string(&b, v.data.str.s)
		case .Err:
			strings.write_string(&b, vm.error_message(v.data.err))
		case .Float:
			write_float_g(&b, v.data.fnum)
		case .List:
			strings.write_string(&b, "{list}")
		}
	}
	return vm.call_ok(values.str_val(strings.to_string(b)))
}

// bf_toliteral ports unparse_value(): recreates MOO source syntax for a value, recursively
// for lists -- the output of toliteral() always reparses to an equal value.
bf_toliteral :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 1 {
		return arg_count_error()
	}
	b := strings.builder_make()
	write_literal(&b, nth(args, 1))
	return vm.call_ok(values.str_val(strings.to_string(b)))
}

@(private = "file")
write_literal :: proc(b: ^strings.Builder, v: values.Var) {
	#partial switch v.type {
	case .Int:
		fmt.sbprintf(b, "%d", v.data.num)
	case .Obj:
		fmt.sbprintf(b, "#%d", v.data.obj)
	case .Err:
		strings.write_string(b, compiler.error_name(v.data.err))
	case .Float:
		write_float_g(b, v.data.fnum)
	case .Str:
		strings.write_byte(b, '"')
		for c in v.data.str.s {
			if c == '"' || c == '\\' {
				strings.write_byte(b, '\\')
			}
			strings.write_rune(b, c)
		}
		strings.write_byte(b, '"')
	case .List:
		strings.write_byte(b, '{')
		for i in 1 ..= values.list_len(v) {
			if i > 1 {
				strings.write_string(b, ", ")
			}
			write_literal(b, values.list_get(v, i))
		}
		strings.write_byte(b, '}')
	}
}

@(private = "file")
write_float_g :: proc(b: ^strings.Builder, f: f64) {
	s := fmt.tprintf("%g", f)
	has_marker := false
	for c in s {
		if c == '.' || c == 'e' || c == 'E' || c == 'n' || c == 'i' {
			has_marker = true
			break
		}
	}
	strings.write_string(b, s)
	if !has_marker {
		strings.write_string(b, ".0")
	}
}

// bf_toint ports become_integer(): STR parses as int (falling back to float-then-truncate),
// defaulting to 0 on unparseable input (matches the original's silent-zero behavior rather
// than raising); OBJ/ERR widen their ordinal value; FLOAT truncates (E_FLOAT if out of
// range); LIST is E_TYPE.
bf_toint :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 1 {
		return arg_count_error()
	}
	v := nth(args, 1)
	#partial switch v.type {
	case .Int:
		return vm.call_ok(values.int_val(v.data.num))
	case .Obj:
		return vm.call_ok(values.int_val(i32(v.data.obj)))
	case .Err:
		return vm.call_ok(values.int_val(i32(v.data.err)))
	case .Float:
		if v.data.fnum < f64(min(i32)) || v.data.fnum > f64(max(i32)) {
			return raise_err(.E_FLOAT, "Floating-point arithmetic error")
		}
		return vm.call_ok(values.int_val(i32(v.data.fnum)))
	case .Str:
		s := strings.trim_space(v.data.str.s)
		if n, ok := strconv.parse_i64(s); ok {
			return vm.call_ok(values.int_val(i32(n)))
		}
		if f, ok := strconv.parse_f64(s); ok {
			return vm.call_ok(values.int_val(i32(f)))
		}
		return vm.call_ok(values.int_val(0))
	case .List:
		return arg_type_error()
	}
	return arg_type_error()
}

bf_tofloat :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 1 {
		return arg_count_error()
	}
	v := nth(args, 1)
	#partial switch v.type {
	case .Int:
		return vm.call_ok(values.float_val(f64(v.data.num)))
	case .Obj:
		return vm.call_ok(values.float_val(f64(v.data.obj)))
	case .Err:
		return vm.call_ok(values.float_val(f64(v.data.err)))
	case .Float:
		return vm.call_ok(values.float_val(v.data.fnum))
	case .Str:
		s := strings.trim_space(v.data.str.s)
		f, ok := strconv.parse_f64(s)
		if !ok {
			return raise_err(.E_INVARG, "Invalid argument")
		}
		return vm.call_ok(values.float_val(f))
	case .List:
		return arg_type_error()
	}
	return arg_type_error()
}

// bf_toobj ports become_integer()'s TYPE_OBJ conversions plus parse_object() for strings
// (accepts a leading '#'; a bare number is also accepted).
bf_toobj :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 1 {
		return arg_count_error()
	}
	v := nth(args, 1)
	#partial switch v.type {
	case .Int:
		return vm.call_ok(values.obj_val(values.Objid(v.data.num)))
	case .Obj:
		return vm.call_ok(values.obj_val(v.data.obj))
	case .Err:
		return vm.call_ok(values.obj_val(values.Objid(v.data.err)))
	case .Float:
		return vm.call_ok(values.obj_val(values.Objid(v.data.fnum)))
	case .Str:
		s := strings.trim_space(v.data.str.s)
		s = strings.trim_prefix(s, "#")
		n, ok := strconv.parse_int(s, 10)
		if !ok {
			return vm.call_ok(values.obj_val(0))
		}
		return vm.call_ok(values.obj_val(values.Objid(n)))
	case .List:
		return arg_type_error()
	}
	return arg_type_error()
}

// bf_equal ports bf_equal(): case-SENSITIVE equality -- unlike the `==` operator (see
// vm/eval_expr.odin's note), which is case-insensitive for strings.
bf_equal :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 2 {
		return arg_count_error()
	}
	return vm.call_ok(values.int_val(values.equality(nth(args, 1), nth(args, 2), true) ? 1 : 0))
}
