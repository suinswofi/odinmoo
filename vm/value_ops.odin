package vm

// Arithmetic/comparison/indexing operations, ported from numbers.c and the corresponding
// opcode handlers in execute.c. The single most surprising fact captured here (confirmed by
// numbers.c's own header comment: "All of the following implementations are strict, not
// performing any coercions between integer and floating-point operands"): MOO does NOT
// auto-convert between int and float. `1 + 1.5` is a genuine E_TYPE error, not 2.5 -- every
// arithmetic op below requires both operands to already be the same type.

import "../values"
import "core:math"
import "core:strings"

Op_Result :: struct {
	value: values.Var, // valid iff err == .E_NONE
	err:   values.Error,
}

ok_result :: proc(v: values.Var) -> Op_Result {return Op_Result{value = v, err = .E_NONE}}
err_result :: proc(e: values.Error) -> Op_Result {return Op_Result{err = e}}

@(private = "file")
is_real :: proc(f: f64) -> bool {
	return f >= -max(f64) && f <= max(f64) // ports my-math.h's IS_REAL
}

// do_add/subtract/multiply ports numbers.c's SIMPLE_BINARY macro instantiations.
do_add :: proc(a, b: values.Var) -> Op_Result {
	if a.type == .Str && b.type == .Str {
		return do_string_concat(a, b)
	}
	return simple_binary(a, b, proc(x, y: i32) -> i32 {return x + y}, proc(x, y: f64) -> f64 {return x + y})
}

do_subtract :: proc(a, b: values.Var) -> Op_Result {
	return simple_binary(a, b, proc(x, y: i32) -> i32 {return x - y}, proc(x, y: f64) -> f64 {return x - y})
}

do_multiply :: proc(a, b: values.Var) -> Op_Result {
	return simple_binary(a, b, proc(x, y: i32) -> i32 {return x * y}, proc(x, y: f64) -> f64 {return x * y})
}

@(private = "file")
simple_binary :: proc(a, b: values.Var, iop: proc(i32, i32) -> i32, fop: proc(f64, f64) -> f64) -> Op_Result {
	if a.type != b.type {
		return err_result(.E_TYPE)
	}
	if a.type == .Int {
		return ok_result(values.int_val(iop(a.data.num, b.data.num)))
	}
	if a.type == .Float {
		d := fop(a.data.fnum, b.data.fnum)
		if !is_real(d) {
			return err_result(.E_FLOAT)
		}
		return ok_result(values.float_val(d))
	}
	return err_result(.E_TYPE)
}

// do_string_concat ports OP_ADD's TYPE_STR branch (a plain string concatenation; the
// original's SVO_MAX_STRING_CONCAT quota check is a $server_options-driven limit -- a
// Phase 4/5 concern once the object DB providing $server_options exists, so it's not
// enforced here yet).
do_string_concat :: proc(a, b: values.Var) -> Op_Result {
	return ok_result(values.str_val(strings.concatenate({a.data.str.s, b.data.str.s})))
}

// do_divide/modulus ports numbers.c's DIVISION_OP macro instantiations: divide-by-zero (of
// either type) is E_DIV, not a crash or infinity.
do_divide :: proc(a, b: values.Var) -> Op_Result {
	if a.type != b.type {
		return err_result(.E_TYPE)
	}
	if a.type == .Int {
		if b.data.num == 0 {
			return err_result(.E_DIV)
		}
		return ok_result(values.int_val(a.data.num / b.data.num))
	}
	if a.type == .Float {
		if b.data.fnum == 0 {
			return err_result(.E_DIV)
		}
		d := a.data.fnum / b.data.fnum
		if !is_real(d) {
			return err_result(.E_FLOAT)
		}
		return ok_result(values.float_val(d))
	}
	return err_result(.E_TYPE)
}

do_modulus :: proc(a, b: values.Var) -> Op_Result {
	if a.type != b.type {
		return err_result(.E_TYPE)
	}
	if a.type == .Int {
		if b.data.num == 0 {
			return err_result(.E_DIV)
		}
		return ok_result(values.int_val(a.data.num % b.data.num))
	}
	if a.type == .Float {
		if b.data.fnum == 0 {
			return err_result(.E_DIV)
		}
		d := math.mod(a.data.fnum, b.data.fnum)
		if !is_real(d) {
			return err_result(.E_FLOAT)
		}
		return ok_result(values.float_val(d))
	}
	return err_result(.E_TYPE)
}

// do_power ports numbers.c's do_power(): integer base requires an integer exponent (fast
// exponentiation-by-squaring, matching C `int` wraparound on overflow); negative integer
// exponents are special-cased (base -1/0/1) rather than producing a fraction, since MOO
// integers have no fractional representation. Float base accepts either an int or float
// exponent.
do_power :: proc(a, b: values.Var) -> Op_Result {
	if a.type == .Int {
		if b.type != .Int {
			return err_result(.E_TYPE)
		}
		base := a.data.num
		exp := b.data.num
		if exp < 0 {
			switch base {
			case -1:
				return ok_result(values.int_val(exp % 2 == 0 ? 1 : -1))
			case 0:
				return err_result(.E_DIV)
			case 1:
				return ok_result(values.int_val(1))
			case:
				return ok_result(values.int_val(0))
			}
		}
		r: i32 = 1
		aa := base
		bb := exp
		for bb != 0 {
			if bb % 2 != 0 {
				r *= aa
			}
			aa *= aa
			bb >>= 1
		}
		return ok_result(values.int_val(r))
	}
	if a.type == .Float {
		exp: f64
		#partial switch b.type {
		case .Int:
			exp = f64(b.data.num)
		case .Float:
			exp = b.data.fnum
		case:
			return err_result(.E_TYPE)
		}
		d := math.pow(a.data.fnum, exp)
		if !is_real(d) {
			return err_result(.E_FLOAT)
		}
		return ok_result(values.float_val(d))
	}
	return err_result(.E_TYPE)
}

do_unary_minus :: proc(a: values.Var) -> Op_Result {
	if a.type == .Int {
		return ok_result(values.int_val(-a.data.num))
	}
	if a.type == .Float {
		return ok_result(values.float_val(-a.data.fnum))
	}
	return err_result(.E_TYPE)
}

// compare_numbers ports numbers.c's compare_numbers()/compare_integers(): -1/0/1, requiring
// (again) exact type match -- `1 < 1.5` is E_TYPE, same strictness as arithmetic.
compare_numbers :: proc(a, b: values.Var) -> (cmp: int, err: values.Error) {
	if a.type != b.type {
		return 0, .E_TYPE
	}
	if a.type == .Int {
		return compare_ints(a.data.num, b.data.num), .E_NONE
	}
	x, y := a.data.fnum, b.data.fnum
	if x < y {
		return -1, .E_NONE
	} else if x == y {
		return 0, .E_NONE
	}
	return 1, .E_NONE
}

@(private = "file")
compare_ints :: proc(a, b: i32) -> int {
	if a < b {return -1}
	if a == b {return 0}
	return 1
}

// compare_ordered ports the OP_LT/LE/GT/GE opcode handler: numeric types compare via
// compare_numbers (still strict); OBJ/ERR/STR compare directly (STR case-insensitively);
// mismatched types or LIST are always E_TYPE (MOO has no `<` for lists).
compare_ordered :: proc(a, b: values.Var) -> (cmp: int, err: values.Error) {
	is_num :: proc(v: values.Var) -> bool {return v.type == .Int || v.type == .Float}
	if is_num(a) && is_num(b) {
		return compare_numbers(a, b)
	}
	if a.type != b.type || a.type == .List {
		return 0, .E_TYPE
	}
	switch a.type {
	case .Int:
		return compare_ints(a.data.num, b.data.num), .E_NONE
	case .Obj:
		return compare_ints(i32(a.data.obj), i32(b.data.obj)), .E_NONE
	case .Err:
		return int(a.data.err) - int(b.data.err), .E_NONE
	case .Str:
		return strings.compare(strings.to_lower(a.data.str.s, context.temp_allocator), strings.to_lower(b.data.str.s, context.temp_allocator)), .E_NONE
	case .Float, .List, .Clear, .None, .Catch, .Finally:
		return 0, .E_TYPE
	}
	return 0, .E_TYPE
}

// index_get ports OP_REF: 1-based indexing into a list or string. index must be INT; base
// must be LIST or STR; out-of-range (including empty) is E_RANGE, not silently clamped.
index_get :: proc(base, index: values.Var) -> Op_Result {
	if index.type != .Int || (base.type != .List && base.type != .Str) {
		return err_result(.E_TYPE)
	}
	i := index.data.num
	if base.type == .List {
		n := values.list_len(base)
		if i <= 0 || int(i) > n {
			return err_result(.E_RANGE)
		}
		return ok_result(values.var_ref(values.list_get(base, int(i))))
	}
	s := base.data.str.s
	if i <= 0 || int(i) > len(s) {
		return err_result(.E_RANGE)
	}
	return ok_result(values.str_val(strings.clone(s[i - 1:i])))
}

// range_get ports OP_RANGE_REF: base[from..to]. An empty range (from > to) always succeeds
// regardless of from/to's actual values (matching sub_list's convention); a non-empty range
// requires both endpoints within [1, len].
range_get :: proc(base, from, to: values.Var) -> Op_Result {
	if (base.type != .List && base.type != .Str) || from.type != .Int || to.type != .Int {
		return err_result(.E_TYPE)
	}
	f, t := int(from.data.num), int(to.data.num)
	n := base.type == .Str ? len(base.data.str.s) : values.list_len(base)
	if f <= t && (f <= 0 || f > n || t <= 0 || t > n) {
		return err_result(.E_RANGE)
	}
	if base.type == .Str {
		if f > t {
			return ok_result(values.str_val(strings.clone("")))
		}
		return ok_result(values.str_val(strings.clone(base.data.str.s[f - 1:t])))
	}
	return ok_result(values.sub_list(values.var_ref(base), f, t))
}

// index_set ports OP_INDEXSET (`base[index] = value`): consumes base, index, and value;
// returns the updated base. String targets require a single-character replacement value
// (E_INVARG otherwise) since MOO strings have no independent character type.
index_set :: proc(base, index, value: values.Var) -> Op_Result {
	if (base.type != .List && base.type != .Str) || index.type != .Int || (base.type == .Str && value.type != .Str) {
		values.free_var(base)
		values.free_var(index)
		values.free_var(value)
		return err_result(.E_TYPE)
	}
	i := int(index.data.num)
	n := base.type == .List ? values.list_len(base) : len(base.data.str.s)
	if i < 1 || i > n {
		values.free_var(base)
		values.free_var(index)
		values.free_var(value)
		return err_result(.E_RANGE)
	}
	if base.type == .Str {
		if len(value.data.str.s) != 1 {
			values.free_var(base)
			values.free_var(index)
			values.free_var(value)
			return err_result(.E_INVARG)
		}
		buf := make([]byte, len(base.data.str.s))
		copy(buf, base.data.str.s)
		buf[i - 1] = value.data.str.s[0]
		values.free_var(base)
		values.free_var(index)
		values.free_var(value)
		return ok_result(values.str_val(string(buf)))
	}
	result := base
	if base.data.list.rc != 1 {
		result = values.var_dup(base)
		values.free_var(base)
	}
	result = values.list_set(result, value, i)
	values.free_var(index)
	return ok_result(result)
}

// range_set ports EOP_RANGESET (`base[from..to] = value`) plus execute.c's
// rangeset_check(): unlike range_get's read-only bounds check, this is deliberately
// permissive -- `from == len+1` appends, `to == 0` prepends, allowing the range to grow or
// shrink the base. (The original's SVO_MAX_*_CONCAT quota check needs `$server_options`,
// which doesn't exist until Phase 4's object DB does; skipped here, same as do_string_concat.)
range_set :: proc(base, from, to, value: values.Var) -> Op_Result {
	if from.type != .Int || to.type != .Int || (base.type != .List && base.type != .Str) || (value.type != .List && value.type != .Str) || base.type != value.type {
		values.free_var(base)
		values.free_var(from)
		values.free_var(to)
		values.free_var(value)
		return err_result(.E_TYPE)
	}
	f, t := int(from.data.num), int(to.data.num)
	n := base.type == .Str ? len(base.data.str.s) : values.list_len(base)
	if f > n + 1 || t < 0 {
		values.free_var(base)
		values.free_var(from)
		values.free_var(to)
		values.free_var(value)
		return err_result(.E_RANGE)
	}
	if base.type == .Str {
		left := f > 1 ? base.data.str.s[:f - 1] : ""
		right := n > t ? base.data.str.s[t:] : ""
		joined := strings.concatenate({left, value.data.str.s, right})
		values.free_var(base)
		values.free_var(from)
		values.free_var(to)
		values.free_var(value)
		return ok_result(values.str_val(joined))
	}
	values.free_var(from)
	values.free_var(to)
	return ok_result(values.list_range_set(base, f, t, value))
}
