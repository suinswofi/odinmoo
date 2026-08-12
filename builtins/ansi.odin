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
bf_ansify :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 1 {
		return arg_count_error()
	}
	v := nth(args, 1)
	if v.type != .Str {
		return arg_type_error()
	}
	return vm.call_ok(values.str_val(ansi.translate(v.data.str.s, true)))
}
