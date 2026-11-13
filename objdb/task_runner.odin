package objdb

// Starting tasks and finishing them badly, ported from tasks.c's run_server_task() /
// run_server_task_setting_id(), execute.c's do_server_verb_task() / do_input_task(), and the
// tail of execute.c's run_interpreter().
//
// Every task the server starts on its own initiative -- a typed command, a login line,
// #0:user_connected and the other notifications, #0:server_started, a checkpoint notice, an
// out-of-band command -- goes through run_root_verb, which gives it a foreground budget from
// $server_options and, if it dies with an error nobody caught, hands the error to
// #0:handle_uncaught_error (or a timeout to #0:handle_task_timeout). If that verb doesn't exist
// or doesn't return true, the traceback is printed to the task's player:
//
//	#6:l*ook_self (this == #2), line 4:  Type mismatch
//	... called from #3:look, line 2
//	(End of traceback)
//
// All of it runs MOO code, so the caller holds big_lock.

import "../tasks"
import "../values"
import "../vm"
import "core:fmt"
import "core:strings"

// Root_Call describes a server-initiated task's root activation (do_server_program_task's and
// do_input_task's environment). Zero values give the server-task defaults.
Root_Call :: struct {
	player:   values.Objid,
	this:     values.Objid, // the object the verb runs on
	verb:     string, // the name it is called by
	args:     values.Var, // owned; consumed
	argstr:   string,
	// For a typed command (do_input_task): the parsed command, the already-matched verb, and
	// `caller` == the player rather than #-1.
	cmd:      ^Parsed_Command,
	vh:       Verb_Handle,
	// task_id 0 allocates a fresh one.
	task_id:  int,
	// no_tracebacks is do_db_tracebacks == 0: used only for running the error handlers
	// themselves, so a failing handler can't recurse.
	no_tracebacks: bool,
}

Root_Outcome :: enum {
	Done, // returned normally (or there was no such verb: "simulate an empty verb")
	Aborted, // died with an error or ran out of ticks/seconds, or was killed
}

// run_root_verb runs `rc.this:rc.verb(@rc.args)` as a new task and returns its value (owned;
// 0 unless Done).
run_root_verb :: proc(w: ^Object_World, vw: ^vm.World, rc: Root_Call) -> (value: values.Var, outcome: Root_Outcome) {
	task_id := rc.task_id
	if task_id == 0 && w.scheduler != nil {
		task_id = tasks.new_task_id(w.scheduler)
	}
	vh := rc.vh
	if rc.cmd == nil && !vh.found {
		// run_server_task_setting_id: no callable verb means "simulate an empty verb".
		if !valid(w.db, rc.this) {
			values.free_var(rc.args)
			return values.int_val(0), .Done
		}
		vh = find_callable_verb(w.db, rc.this, rc.verb)
		if !vh.found {
			values.free_var(rc.args)
			return values.int_val(0), .Done
		}
	}

	root := vm.Activation{
		this       = rc.cmd != nil ? rc.player : values.NOTHING, // becomes the callee's `caller`
		player     = rc.player,
		caller     = values.NOTHING,
		programmer = values.NOTHING,
		verb_loc   = values.NOTHING,
		task_id    = task_id,
		depth      = -1, // server scaffolding: the verb itself lands at depth 0
		dobj       = values.NOTHING,
		iobj       = values.NOTHING,
		argstr     = rc.argstr,
	}
	budget: vm.Task_Budget
	vm.budget_open(&budget, vw, false) // a task started by input or by the server is foreground
	defer vm.budget_close(&budget)
	root.budget = &budget
	ctx := vm.Eval_Context{activation = &root, world = vw}

	r := call_verb_from(w, vw, rc.this, rc.this, rc.verb, rc.args, &ctx, rc.cmd, vh)
	if !r.raised {
		return r.value, .Done
	}
	if !rc.no_tracebacks {
		err := vm.Error_Info{code = r.code, msg = r.msg, value = r.rvalue, uncatchable = r.uncatchable, serial = r.serial}
		task_aborted(w, vw, &err, &root)
	}
	delete(r.msg)
	values.free_var(r.rvalue)
	return values.int_val(0), .Aborted
}

// world_task_aborted backs vm.World.task_aborted, for tasks whose runner lives outside objdb
// (forked tasks, in the scheduler).
world_task_aborted :: proc(vw: ^vm.World, err: ^vm.Error_Info, root: ^vm.Activation) {
	task_aborted(cast(^Object_World)vw.user_data, vw, err, root)
}

// task_aborted ports run_interpreter's handling of an aborted task: a killed task vanishes
// silently; otherwise #0:handle_task_timeout(resource, stack, traceback) or
// #0:handle_uncaught_error(code, message, value, stack, traceback) gets first refusal, and if
// it doesn't exist or returns false the traceback goes to the task's player.
task_aborted :: proc(w: ^Object_World, vw: ^vm.World, err: ^vm.Error_Info, root: ^vm.Activation) {
	b := root.budget
	if b != nil && b.killed {
		return
	}
	timed_out := b != nil && b.out_of != .None
	msg := err.msg
	if timed_out {
		msg = b.out_of == .Seconds ? "Task ran out of seconds" : "Task ran out of ticks"
	}

	frames, owned := vm.error_frames(root, err.serial)
	defer vm.release_frames(&frames, owned)
	lines := vm.traceback_lines(frames, msg)
	player := root.player
	if w.trace_errors {
		for l in lines {
			trace_line(l)
		}
	}

	handler := timed_out ? "handle_task_timeout" : "handle_uncaught_error"
	if vh := find_callable_verb(w.db, values.SYSTEM_OBJECT, handler); vh.found {
		args: values.Var
		if timed_out {
			items := make([]values.Var, 3)
			items[0] = values.str_val(strings.clone(b.out_of == .Seconds ? "seconds" : "ticks"))
			items[1] = vm.stack_list(frames, 0)
			items[2] = traceback_value(lines)
			args = values.list_val(items)
		} else {
			items := make([]values.Var, 5)
			items[0] = values.err_val(err.code)
			items[1] = values.str_val(strings.clone(err.msg))
			items[2] = values.var_ref(err.value)
			items[3] = vm.stack_list(frames, 0)
			items[4] = traceback_value(lines)
			args = values.list_val(items)
		}
		handled, outcome := run_root_verb(w, vw, Root_Call{
			player = player, this = values.SYSTEM_OBJECT, verb = handler, args = args, vh = vh,
			no_tracebacks = true,
		})
		is_handled := outcome == .Done && values.is_true(handled)
		values.free_var(handled)
		if is_handled {
			delete_lines(lines)
			return
		}
	}
	if w.conn.notify != nil {
		for l in lines {
			w.conn.notify(w.conn.user_data, player, l)
		}
	}
	delete_lines(lines)
}

@(private = "file")
traceback_value :: proc(lines: [dynamic]string) -> values.Var {
	items := make([]values.Var, len(lines))
	for l, i in lines {
		items[i] = values.str_val(strings.clone(l))
	}
	return values.list_val(items)
}

@(private = "file")
delete_lines :: proc(lines: [dynamic]string) {
	for l in lines {
		delete(l)
	}
	delete(lines)
}

@(private = "file")
trace_line :: proc(l: string) {
	// stderr, with MOO_TRACE_ERRORS -- the log's copy of what the player is shown.
	fmt.eprintfln("TRACEBACK: %s", l)
}
