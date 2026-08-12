package builtins

// Math built-ins. abs/min/max operate on either int or float (matching both operands'
// type, like the arithmetic operators); the transcendental functions all require float
// arguments (MOO's math library operates purely in double precision, matching numbers.c's
// MATH_FUNC macro instantiations).

import "../values"
import "../vm"
import "core:math"
import "core:math/rand"

bf_abs :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 1 {
		return arg_count_error()
	}
	v := nth(args, 1)
	#partial switch v.type {
	case .Int:
		n := v.data.num
		return vm.call_ok(values.int_val(n < 0 ? -n : n))
	case .Float:
		return vm.call_ok(values.float_val(math.abs(v.data.fnum)))
	}
	return arg_type_error()
}

@(private = "file")
minmax :: proc(args: values.Var, want_min: bool) -> vm.Call_Result {
	defer values.free_var(args)
	n := nargs(args)
	if n < 1 {
		return arg_count_error()
	}
	best := nth(args, 1)
	if best.type != .Int && best.type != .Float {
		return arg_type_error()
	}
	for i in 2 ..= n {
		v := nth(args, i)
		if v.type != best.type {
			return arg_type_error()
		}
		less: bool
		if v.type == .Int {
			less = v.data.num < best.data.num
		} else {
			less = v.data.fnum < best.data.fnum
		}
		if less == want_min {
			best = v
		}
	}
	return vm.call_ok(values.var_ref(best))
}

bf_min :: proc(args: values.Var) -> vm.Call_Result {return minmax(args, true)}
bf_max :: proc(args: values.Var) -> vm.Call_Result {return minmax(args, false)}

@(private = "file")
require_float :: proc(args: values.Var) -> (f: f64, ok: bool) {
	if nargs(args) != 1 {
		return 0, false
	}
	v := nth(args, 1)
	if v.type != .Float {
		return 0, false
	}
	return v.data.fnum, true
}

bf_floor :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	f, ok := require_float(args)
	if !ok {
		return arg_type_error()
	}
	return vm.call_ok(values.float_val(math.floor(f)))
}

bf_ceil :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	f, ok := require_float(args)
	if !ok {
		return arg_type_error()
	}
	return vm.call_ok(values.float_val(math.ceil(f)))
}

bf_trunc :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	f, ok := require_float(args)
	if !ok {
		return arg_type_error()
	}
	return vm.call_ok(values.float_val(math.trunc(f)))
}

@(private = "file")
math1 :: proc(args: values.Var, fn: proc(f64) -> f64) -> vm.Call_Result {
	defer values.free_var(args)
	f, ok := require_float(args)
	if !ok {
		return arg_type_error()
	}
	d := fn(f)
	if !(d >= -max(f64) && d <= max(f64)) {
		return raise_err(.E_FLOAT, "Floating-point arithmetic error")
	}
	return vm.call_ok(values.float_val(d))
}

@(private = "file")
f64_sqrt :: proc(f: f64) -> f64 {return math.sqrt(f)}
@(private = "file")
f64_sin :: proc(f: f64) -> f64 {return math.sin(f)}
@(private = "file")
f64_cos :: proc(f: f64) -> f64 {return math.cos(f)}
@(private = "file")
f64_tan :: proc(f: f64) -> f64 {return math.tan(f)}
@(private = "file")
f64_asin :: proc(f: f64) -> f64 {return math.asin(f)}
@(private = "file")
f64_acos :: proc(f: f64) -> f64 {return math.acos(f)}
@(private = "file")
f64_atan :: proc(f: f64) -> f64 {return math.atan(f)}
@(private = "file")
f64_exp :: proc(f: f64) -> f64 {return math.exp(f)}
@(private = "file")
f64_ln :: proc(f: f64) -> f64 {return math.ln(f)}
@(private = "file")
f64_log10 :: proc(f: f64) -> f64 {return math.log10(f)}

bf_sqrt :: proc(args: values.Var) -> vm.Call_Result {return math1(args, f64_sqrt)}
bf_sin :: proc(args: values.Var) -> vm.Call_Result {return math1(args, f64_sin)}
bf_cos :: proc(args: values.Var) -> vm.Call_Result {return math1(args, f64_cos)}
bf_tan :: proc(args: values.Var) -> vm.Call_Result {return math1(args, f64_tan)}
bf_asin :: proc(args: values.Var) -> vm.Call_Result {return math1(args, f64_asin)}
bf_acos :: proc(args: values.Var) -> vm.Call_Result {return math1(args, f64_acos)}
bf_atan :: proc(args: values.Var) -> vm.Call_Result {return math1(args, f64_atan)}
bf_exp :: proc(args: values.Var) -> vm.Call_Result {return math1(args, f64_exp)}
bf_log :: proc(args: values.Var) -> vm.Call_Result {return math1(args, f64_ln)}
bf_log10 :: proc(args: values.Var) -> vm.Call_Result {return math1(args, f64_log10)}

// bf_random ports random([mod]): a uniformly random integer in [1, mod], default mod is
// MAXINT (matching the original's default upper bound).
bf_random :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	n := nargs(args)
	if n > 1 {
		return arg_count_error()
	}
	mod: i32 = max(i32)
	if n == 1 {
		v := nth(args, 1)
		if v.type != .Int {
			return arg_type_error()
		}
		mod = v.data.num
	}
	if mod < 1 {
		return raise_err(.E_INVARG, "Invalid argument")
	}
	return vm.call_ok(values.int_val(i32(rand.int31_max(mod)) + 1))
}
