package builtins

// ansi_strip()/ansi_len()/ansify(): built-ins exposing Phase 9's %-code color markup to MOO
// verb code directly, alongside the automatic translation netio applies to all outbound
// text (see netio/connection.odin). Letting verb authors call these explicitly matters for
// things like padding a colored string to a fixed column width, where the padding math
// needs the *visible* length, not the length including invisible markup/escapes.

import "../ansi"
import "../values"
import "../vm"

// ansi_strip(text) removes %-code markup, returning plain text.
bf_ansi_strip :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 1 {
		return arg_count_error()
	}
	v := nth(args, 1)
	if v.type != .Str {
		return arg_type_error()
	}
	return vm.call_ok(values.str_val(ansi.strip(v.data.str.s)))
}

// ansi_len(text) returns the display width of text, ignoring %-code markup and real ANSI
// escapes alike (whichever form the string is in).
bf_ansi_len :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 1 {
		return arg_count_error()
	}
	v := nth(args, 1)
	if v.type != .Str {
		return arg_type_error()
	}
	return vm.call_ok(values.int_val(i32(ansi.visible_len(v.data.str.s))))
}

// ansify(text) translates %-code markup into real ANSI escape sequences.
//
// This is a GROWING transform -- every markup code it consumes is shorter than the escape
// sequence it emits (`%r` is two bytes in and five out), so the result runs about 2.5x the
// input at worst. That is a constant factor rather than substitute()'s product, but the input
// is already allowed to be values.MAX_STR_LEN, so the output ran straight past it: measured,
// ansify() on 8MB of "%r" returned 20MB, against a 16MB cap. tostr, toliteral, strsub and
// substitute all carry this check; ansify is a string-builder like them and was simply missed,
// being the one built-in here the original C server never had. Unlike those, the overshoot
// cannot compound -- the result holds no markup, so a second ansify() is the identity, and `+`
// checks before concatenating -- but a value over the cap still reaches a property and then a
// checkpoint, which is the invariant values.MAX_STR_LEN exists to keep.
bf_ansify :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 1 {
		return arg_count_error()
	}
	v := nth(args, 1)
	if v.type != .Str {
		return arg_type_error()
	}
	out := ansi.translate(v.data.str.s, true)
	if len(out) > values.MAX_STR_LEN {
		delete(out)
		return raise_err(.E_QUOTA, "Value too large")
	}
	return vm.call_ok(values.str_val(out))
}
