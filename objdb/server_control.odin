package objdb

// Server-control built-ins: server_log() (log.c), shutdown()/dump_database() (server.c, via
// Server_Hooks -- see world.odin's header note on why this needs a hook rather than direct
// access), load_server_options() (functions.c).

import "../values"
import "../vm"
import "core:fmt"

// bf_server_log ports log.c's bf_server_log(): wizard-only, writes to stdout (or stderr for
// the is_error form) with the same "> message" prefix the original's oklog/errlog use.
bf_server_log :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	n := values.list_len(args)
	if n < 1 || n > 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	msg_v := values.list_get(args, 1)
	if msg_v.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	if !is_wizard(w.db, ctx.activation.programmer) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	is_error := n == 2 && values.is_true(values.list_get(args, 2))
	if is_error {
		fmt.eprintfln("> %s", msg_v.data.str.s)
	} else {
		fmt.printfln("> %s", msg_v.data.str.s)
	}
	return ok_result(values.int_val(0))
}

// bf_shutdown ports server.c's bf_shutdown(): wizard-only, asks the real server loop
// (Server_Hooks.request_shutdown) to begin a clean shutdown -- this call itself returns
// normally, matching the original (the actual shutdown happens once the calling task yields
// back to the main loop, not synchronously inside this builtin).
bf_shutdown :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	n := values.list_len(args)
	if n > 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	if !is_wizard(w.db, ctx.activation.programmer) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	message := ""
	if n == 1 {
		msg_v := values.list_get(args, 1)
		if msg_v.type != .Str {
			return err_result_local(.E_TYPE, "Type mismatch")
		}
		message = msg_v.data.str.s
	}
	if w.server_ctl.request_shutdown != nil {
		w.server_ctl.request_shutdown(w.server_ctl.user_data, message)
	}
	return ok_result(values.int_val(0))
}

// bf_dump_database ports server.c's bf_dump_database(): wizard-only, asks the real server
// loop to write a checkpoint at its next opportunity (the same request SIGUSR2 makes).
bf_dump_database :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 0 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	if !is_wizard(w.db, ctx.activation.programmer) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	if w.server_ctl.request_checkpoint != nil {
		w.server_ctl.request_checkpoint(w.server_ctl.user_data)
	}
	return ok_result(values.int_val(0))
}

// bf_load_server_options ports functions.c's bf_load_server_options(): wizard-only,
// refreshes the original's in-memory `$server_options`-derived caches (protect_* flags,
// misc numeric options). This port doesn't maintain any such cache -- there's no per-builtin
// "protected" table (see introspection_stats.odin's function_description note) and no
// $server_options-driven tick/second-budget or fairness-queue system (see
// tasks/scheduler.odin's header "Scope cut" note) -- so there is genuinely nothing to
// refresh. A true, honest no-op: permission-checked, does nothing, matching what the original
// itself would do if none of its cached options had changed.
bf_load_server_options :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 0 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	if !is_wizard(w.db, ctx.activation.programmer) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	return ok_result(values.int_val(0))
}
