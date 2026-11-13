package builtins

import "../values"
import "../vm"
import "core:c/libc"
import "core:sys/posix"
import "core:strings"
import "core:time"

bf_time :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 0 {
		return arg_count_error()
	}
	return vm.call_ok(values.int_val(i32(time.now()._nsec / 1_000_000_000)))
}

// bf_ctime ports bf_ctime(): strftime("%a %b %d %H:%M:%S %Y %Z") of localtime(timestamp)
// (default: now), with a leading zero in the day of the month turned into a space -- "Thu Jan
// 1 00:00:00 1970 PST" with two spaces, ctime(3)'s layout. Done through the C library so the
// time zone (and its name) is the server host's, exactly as the original's is.
bf_ctime :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	n := nargs(args)
	if n > 1 {
		return arg_count_error()
	}
	ts: libc.time_t
	if n == 1 {
		v := nth(args, 1)
		if v.type != .Int {
			return arg_type_error()
		}
		ts = libc.time_t(v.data.num)
	} else {
		ts = libc.time(nil)
	}
	tm: libc.tm
	buf: [64]byte
	if posix.localtime_r(&ts, &tm) == nil {
		return raise_err(.E_INVARG, "Invalid argument")
	}
	length := libc.strftime(raw_data(buf[:]), len(buf), "%a %b %d %H:%M:%S %Y %Z", &tm)
	if length > 8 && buf[8] == '0' {
		buf[8] = ' '
	}
	return vm.call_ok(values.str_val(strings.clone(string(buf[:length]))))
}

// bf_raise ports raise(code [, message [, value]]): explicitly triggers the same catchable-
// exception machinery as an operator error. message defaults to the code's own English
// description (vm.error_message), value defaults to 0.
bf_raise :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	n := nargs(args)
	if n < 1 || n > 3 {
		return arg_count_error()
	}
	code_v := nth(args, 1)
	if code_v.type != .Err {
		return arg_type_error()
	}
	msg := vm.error_message(code_v.data.err)
	if n >= 2 {
		mv := nth(args, 2)
		if mv.type != .Str {
			return arg_type_error()
		}
		msg = mv.data.str.s
	}
	rvalue := values.int_val(0)
	if n == 3 {
		rvalue = values.var_ref(nth(args, 3))
	}
	return vm.Call_Result{raised = true, code = code_v.data.err, msg = strings.clone(msg), rvalue = rvalue}
}
