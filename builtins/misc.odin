package builtins

import "../values"
import "../vm"
import "core:fmt"
import "core:strings"
import "core:time"

bf_time :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 0 {
		return arg_count_error()
	}
	return vm.call_ok(values.int_val(i32(time.now()._nsec / 1_000_000_000)))
}

@(private = "file")
weekday_names := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
@(private = "file")
month_names := [13]string{"", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

// bf_ctime ports ctime([timestamp]): formats a UNIX timestamp (default: now) as
// "Www Mon DD HH:MM:SS YYYY ZZZ", matching the original's `strftime(..., "%a %b %d %H:%M:%S
// %Y %Z", localtime(&c))`. Simplified to always report UTC (%Z becomes the literal "UTC")
// rather than the server host's local timezone -- core:time has no timezone database to
// consult, and MOO code almost never depends on the specific zone name, just the format.
bf_ctime :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	n := nargs(args)
	if n > 1 {
		return arg_count_error()
	}
	ts: i64
	if n == 1 {
		v := nth(args, 1)
		if v.type != .Int {
			return arg_type_error()
		}
		ts = i64(v.data.num)
	} else {
		ts = time.now()._nsec / 1_000_000_000
	}
	t := time.unix(ts, 0)
	year, mon, day := time.date(t)
	hour, minute, sec := time.clock(t)
	wd := time.weekday(t)
	s := fmt.tprintf(
		"%s %s %02d %02d:%02d:%02d %d UTC",
		weekday_names[int(wd)], month_names[int(mon)], day, hour, minute, sec, year,
	)
	return vm.call_ok(values.str_val(strings.clone(s)))
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
