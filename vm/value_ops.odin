package vm

// Arithmetic/comparison/indexing operations, ported from numbers.c and the corresponding
// opcode handlers in execute.c. The single most surprising fact captured here (confirmed by
// numbers.c's own header comment: "All of the following implementations are strict, not
// performing any coercions between integer and floating-point operands"): MOO does NOT
// auto-convert between int and float. `1 + 1.5` is a genuine E_TYPE error, not 2.5 -- every
// arithmetic op below requires both operands to already be the same type.

import "../values"
import "core:sync"
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

// do_string_concat ports OP_ADD's TYPE_STR branch, with the length ceiling the original
// gets from $server_options.max_string_concat applied as a fixed constant instead (see
// values.MAX_STR_LEN). Checking BEFORE concatenating, not after, is the point: `x = x + x`
// in a loop is the construction this exists to stop, and by the time the allocation has
// been made the damage is done.
do_string_concat :: proc(a, b: values.Var) -> Op_Result {
	if len(a.data.str.s) + len(b.data.str.s) > values.MAX_STR_LEN {
		return err_result(.E_QUOTA)
	}
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
		if a.data.num == min(i32) && b.data.num == -1 {
			// The one division that is neither zero-divisor nor representable: |INT_MIN| has
			// no positive counterpart, so INT_MIN / -1 overflows. On x86 that is not a wrong
			// answer, it is a hardware trap -- the same SIGFPE as dividing by zero -- and it
			// takes the whole server down, from any MOO expression, with no error to catch.
			// (The C original divides two ints here and traps identically; there is no
			// upstream behavior to preserve, only a crash to not reproduce.) Wrapping matches
			// what this port already does elsewhere at the same boundary: -(-2147483648) and
			// abs(-2147483648) both yield -2147483648.
			return ok_result(values.int_val(min(i32)))
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
		if a.data.num == min(i32) && b.data.num == -1 {
			// Same overflow as in do_divide, same trap on the same instruction -- the
			// remainder just happens to be the exactly-representable half of the answer.
			return ok_result(values.int_val(0))
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
		return values.ascii_compare_fold(a.data.str.s, b.data.str.s), .E_NONE
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

// index_set_error is index_set's validation on its own: the error `base[index] = value` would
// raise, or .E_NONE, consuming nothing. Separate so that assign_indexed can prove an update will
// succeed BEFORE it hands a variable's value over to be mutated in place (see its header).
index_set_error :: proc(base, index, value: values.Var) -> values.Error {
	if (base.type != .List && base.type != .Str) || index.type != .Int || (base.type == .Str && value.type != .Str) {
		return .E_TYPE
	}
	i := int(index.data.num)
	n := base.type == .List ? values.list_len(base) : len(base.data.str.s)
	if i < 1 || i > n {
		return .E_RANGE
	}
	if base.type == .Str {
		return len(value.data.str.s) == 1 ? .E_NONE : .E_INVARG
	}
	// `l[i] = v` nests v one level inside l, so it can grow depth exactly like a list literal
	// can -- see values.MAX_VALUE_DEPTH. Via nests_too_deep rather than off values.value_depth
	// directly, because that cached bound over-estimates once a list has been mutated in
	// place, and deciding off it rejected shallow values outright. And `l[1] = {l[1], l[1]}`
	// doubles l's expanded size without lengthening it -- see values.MAX_VALUE_SIZE.
	if values.nests_too_deep(value) || values.grows_too_big(base, value, values.list_get(base, i), false) {
		return .E_QUOTA
	}
	return .E_NONE
}

// index_set ports OP_INDEXSET (`base[index] = value`): consumes base, index, and value;
// returns the updated base. String targets require a single-character replacement value
// (E_INVARG otherwise) since MOO strings have no independent character type.
//
// A list base whose refcount is 1 is updated in place, in O(1); a shared one is copied first,
// which is what makes the update invisible to every other holder (MOO's value semantics).
index_set :: proc(base, index, value: values.Var) -> Op_Result {
	if e := index_set_error(base, index, value); e != .E_NONE {
		values.free_var(base)
		values.free_var(index)
		values.free_var(value)
		return err_result(e)
	}
	i := int(index.data.num)
	if base.type == .Str {
		buf := make([]byte, len(base.data.str.s))
		copy(buf, base.data.str.s)
		buf[i - 1] = value.data.str.s[0]
		values.free_var(base)
		values.free_var(index)
		values.free_var(value)
		return ok_result(values.str_val(string(buf)))
	}
	result := base
	if sync.atomic_load(&base.data.list.rc) != 1 { // atomic: see values.odin's refcount note
		result = values.var_dup(base)
		values.free_var(base)
	}
	result = values.list_set(result, value, i)
	values.free_var(index)
	return ok_result(result)
}

// range_set_error is range_set's validation on its own, consuming nothing -- index_set_error's
// counterpart, for the same reason.
range_set_error :: proc(base, from, to, value: values.Var) -> values.Error {
	if from.type != .Int || to.type != .Int || (base.type != .List && base.type != .Str) || (value.type != .List && value.type != .Str) || base.type != value.type {
		return .E_TYPE
	}
	f, t := int(from.data.num), int(to.data.num)
	n := base.type == .Str ? len(base.data.str.s) : values.list_len(base)
	if f > n + 1 || t < 0 {
		return .E_RANGE
	}
	left_n := f > 1 ? f - 1 : 0
	right_n := n > t ? n - t : 0
	if base.type == .Str {
		// The other half of the doubling guard in do_string_concat: `s[1..0] = s` grows a
		// string just as fast as `s + s` does.
		if left_n + len(value.data.str.s) + right_n > values.MAX_STR_LEN {
			return .E_QUOTA
		}
		return .E_NONE
	}
	// `l[1..0] = l` doubles the expanded size (values.MAX_VALUE_SIZE) as well as the length.
	if left_n + values.list_len(value) + right_n > values.MAX_LIST_LEN || range_set_size(base, f, t, value) > values.MAX_VALUE_SIZE {
		return .E_QUOTA
	}
	// list_range_set splices value's ELEMENTS in rather than nesting value itself, so the
	// result can be no deeper than its two inputs already were -- no depth check needed.
	return .E_NONE
}

// range_set_size is the exact expanded size (values.MAX_VALUE_SIZE) of `base[f..t] = value` for
// a list base: the elements kept on the left, value's, and the elements kept on the right,
// counted from the parts rather than as base's less the dropped range, because a reversed
// range (`l[3..1] = v`) keeps an element on BOTH sides and so drops a negative number.
range_set_size :: proc(base: values.Var, f, t: int, value: values.Var) -> int {
	n := values.list_len(base)
	left_n := f > 1 ? f - 1 : 0
	right_n := n > t ? n - t : 0
	size := values.value_size(value)
	for k in 0 ..< left_n {
		size = values.size_add(size, 1 + values.value_size(values.list_get(base, k + 1)))
	}
	for k in n - right_n ..< n {
		size = values.size_add(size, 1 + values.value_size(values.list_get(base, k + 1)))
	}
	return size
}

// range_set ports EOP_RANGESET (`base[from..to] = value`) plus execute.c's
// rangeset_check(): unlike range_get's read-only bounds check, this is deliberately
// permissive -- `from == len+1` appends, `to == 0` prepends, allowing the range to grow or
// shrink the base. (The original's SVO_MAX_*_CONCAT quota check needs `$server_options`,
// which doesn't exist until Phase 4's object DB does; skipped here, same as do_string_concat.)
range_set :: proc(base, from, to, value: values.Var) -> Op_Result {
	if e := range_set_error(base, from, to, value); e != .E_NONE {
		values.free_var(base)
		values.free_var(from)
		values.free_var(to)
		values.free_var(value)
		return err_result(e)
	}
	f, t := int(from.data.num), int(to.data.num)
	values.free_var(from)
	values.free_var(to)
	if base.type == .Str {
		n := len(base.data.str.s)
		left := f > 1 ? base.data.str.s[:f - 1] : ""
		right := n > t ? base.data.str.s[t:] : ""
		joined := strings.concatenate({left, value.data.str.s, right})
		values.free_var(base)
		values.free_var(value)
		return ok_result(values.str_val(joined))
	}
	return ok_result(values.list_range_set(base, f, t, value))
}
