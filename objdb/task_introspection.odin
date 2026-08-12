package objdb

// queued_tasks()/task_stack(), ported from tasks.c's bf_queued_tasks()/execute.c's
// bf_task_stack(). Scope cut from the original: this port's scheduler (see
// tasks/scheduler.odin's header) represents a suspended task as a real blocked OS thread,
// not a serialized activation stack, so only the ONE activation active at the moment
// suspend() was called is ever captured (tasks.Task_Info, populated in
// tasks/suspend.odin's bf_suspend via register_task) -- not the full chain of verb calls
// beneath it, and not a real source line number (this port's tree-walking interpreter has no
// per-statement PC to read one back from). task_stack() therefore always returns a
// single-frame list instead of the original's full call stack, and its line-number field is
// always 0. Forked-but-not-yet-started tasks (still sleeping out their delay in
// tasks/fork.odin) also aren't visible here, since they aren't registered with the scheduler
// until they'd suspend -- the original's queued_tasks() does show these. Both are honest,
// narrow divergences given the architecture, not silent stubs: real suspended tasks report
// real ids/owners/verb/this/player/start-time.

import "../tasks"
import "../values"
import "../vm"
import "core:strings"

// bf_queued_tasks ports bf_queued_tasks(): every suspended task, filtered to the caller's own
// unless they're a wizard (who sees everything). Field layout matches the original's
// list_for_vm()/list_for_suspended_task() 10-tuple: {id, start_time, 0, 20000, owner,
// verb_loc, verb_name, line, this, bytes} -- fields 3/4 are the original's own documented
// OBSOLETE placeholders, and 8/10 (line, byte-size) are unavailable in this port (see header).
bf_queued_tasks :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 0 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	if w.scheduler == nil {
		return ok_result(values.empty_list())
	}
	progr := ctx.activation.programmer
	show_all := is_wizard(w.db, progr)

	snaps := tasks.snapshot_tasks(w.scheduler)
	defer delete(snaps)
	items: [dynamic]values.Var
	for s in snaps {
		if !show_all && s.owner != progr {
			continue
		}
		append(&items, queued_task_entry(s))
	}
	return ok_result(values.list_val(items[:]))
}

@(private = "file")
queued_task_entry :: proc(s: tasks.Task_Snapshot) -> values.Var {
	fields := make([]values.Var, 10)
	fields[0] = values.int_val(i32(s.id))
	fields[1] = values.int_val(i32(s.start_time))
	fields[2] = values.int_val(0) // OBSOLETE: was clock ID
	fields[3] = values.int_val(20000) // OBSOLETE: was clock ticks
	fields[4] = values.obj_val(s.owner)
	fields[5] = values.obj_val(s.verb_loc)
	fields[6] = values.str_val(strings.clone(s.verb_name))
	fields[7] = values.int_val(0) // line number: unavailable, see header note
	fields[8] = values.obj_val(s.this_obj)
	fields[9] = values.int_val(0) // byte size: unavailable, see header note
	return values.list_val(fields)
}

// bf_task_stack ports bf_task_stack(): (task-id, [include-line-numbers]) -> a single-frame
// stack list for a currently-suspended task (see header for why it's one frame, not the full
// call chain). Requires the caller be the task's owner or a wizard, matching the original.
bf_task_stack :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	n := values.list_len(args)
	if n < 1 || n > 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	id_v := values.list_get(args, 1)
	if id_v.type != .Int {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	with_lines := n == 2 && values.is_true(values.list_get(args, 2))

	if w.scheduler == nil {
		return err_result_local(.E_INVARG, "No such task")
	}
	snap, ok := tasks.task_snapshot(w.scheduler, int(id_v.data.num))
	if !ok {
		return err_result_local(.E_INVARG, "No such task")
	}
	progr := ctx.activation.programmer
	if !is_wizard(w.db, progr) && progr != snap.owner {
		return err_result_local(.E_PERM, "Permission denied")
	}

	n_fields := 6 if with_lines else 5
	frame := make([]values.Var, n_fields)
	frame[0] = values.obj_val(snap.this_obj)
	frame[1] = values.str_val(strings.clone(snap.verb_name))
	frame[2] = values.obj_val(snap.owner)
	frame[3] = values.obj_val(snap.verb_loc)
	frame[4] = values.obj_val(snap.player)
	if with_lines {
		frame[5] = values.int_val(0) // unavailable, see header note
	}
	items := make([]values.Var, 1)
	items[0] = values.list_val(frame)
	return ok_result(values.list_val(items))
}
