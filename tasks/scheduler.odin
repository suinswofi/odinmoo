package tasks

// Task scheduler, re-engineered rather than ported line-for-line from tasks.c/timers.c.
//
// The original runs every task cooperatively on a single OS process/thread: exactly one
// task executes at a time, `suspend()` works by snapshotting the whole bytecode activation
// stack as plain data (PC included) and later replaying it, and `fork()` just appends a
// closure-like record to a queue that the same single loop picks up later. That design
// exists because 1996 C had no practical portable coroutines.
//
// This port takes the approach flagged back in vm/activation.odin: since Phase 0-5 already
// give every task its own native Odin call stack (the tree-walking interpreter), a
// suspended task can just be a real OS thread blocked on a condition variable -- no
// continuation capture needed. Concurrency is real (multiple threads exist for
// concurrently-forked/suspended tasks), but MOO semantics are preserved exactly as before:
// a single shared Mutex (`Scheduler.big_lock`) ensures only one task is ever actively
// executing MOO code (and thus touching the object DB) at a time, which is exactly the
// guarantee the original's single-threaded loop gave for free. A suspended task releases
// the big lock before blocking and reacquires it before resuming execution, so "suspended"
// genuinely means "not competing for the DB," not just "not making progress."
//
// Scope cut, stated plainly: this does not reproduce the original's per-connection round-
// robin fairness queues or $server_options tick/second budgets -- those are entangled with
// Phase 7's networking layer (which connection a task belongs to) and aren't meaningful
// without it. What's here is the concurrency core: fork, suspend, resume, kill_task,
// task_id, all genuinely working and tested under real concurrent load.

import "../values"
import "../vm"
import "core:sync"
import "core:time"

Scheduler :: struct {
	big_lock:    sync.Mutex, // held by whichever task is actively executing MOO code
	meta_lock:   sync.Mutex, // protects `tasks` and `next_id`; paired with every Task_Info's Cond
	tasks:       map[int]^Task_Info,
	next_id:     int,
	active_forks: sync.Wait_Group, // lets tests/shutdown wait for outstanding forked tasks
}

Task_Info :: struct {
	id:           int,
	cond:         sync.Cond,
	woken:        bool,
	killed:       bool,
	resume_value: values.Var, // set by resume(), consumed by the waiting suspend() call

	// Snapshot of the suspending activation, captured once at register_task() time -- lets
	// queued_tasks()/task_stack() (tasks/introspection.odin) report real (if single-frame,
	// see that file's header note) info instead of stubs. start_time is Unix seconds,
	// matching the original's list_for_suspended_task().
	start_time: i64,
	owner:      values.Objid,
	this_obj:   values.Objid,
	player:     values.Objid,
	verb_loc:   values.Objid,
	verb_name:  string, // borrowed from the Activation; only valid while the task is suspended
}

scheduler_init :: proc() -> Scheduler {
	return Scheduler{tasks = make(map[int]^Task_Info)}
}

scheduler_destroy :: proc(s: ^Scheduler) {
	sync.mutex_lock(&s.meta_lock)
	for _, info in s.tasks {
		free(info)
	}
	delete(s.tasks)
	sync.mutex_unlock(&s.meta_lock)
}

new_task_id :: proc(s: ^Scheduler) -> int {
	sync.mutex_lock(&s.meta_lock)
	defer sync.mutex_unlock(&s.meta_lock)
	s.next_id += 1
	return s.next_id
}

// register_task records a task as suspended/waiting, so resume()/kill_task() (called from
// a different thread) can find it, and so queued_tasks()/task_stack() can report on it.
// Teardown happens inside bf_suspend itself -- the entry must be removed atomically with
// reading the wait's outcome (under the same meta_lock hold), so there is deliberately no
// separate unregister helper to reach for.
register_task :: proc(s: ^Scheduler, id: int, act: ^vm.Activation) -> ^Task_Info {
	info := new(Task_Info)
	info.id = id
	if act != nil {
		info.start_time = time.to_unix_seconds(time.now())
		info.owner = act.programmer
		info.this_obj = act.this
		info.player = act.player
		info.verb_loc = act.verb_loc
		info.verb_name = act.verb_name
	}
	sync.mutex_lock(&s.meta_lock)
	s.tasks[id] = info
	sync.mutex_unlock(&s.meta_lock)
	return info
}

// task_exists reports whether a task is currently registered (i.e. suspended and waiting) --
// used by resume()/kill_task() to give a clean E_INVARG for an unknown/already-resumed id.
task_exists :: proc(s: ^Scheduler, id: int) -> bool {
	sync.mutex_lock(&s.meta_lock)
	defer sync.mutex_unlock(&s.meta_lock)
	_, ok := s.tasks[id]
	return ok
}

// Task_Snapshot is a read-only copy of a Task_Info's reportable fields -- what
// objdb/task_introspection.odin's queued_tasks()/task_stack() builtins need. A plain data
// copy (not a ^Task_Info) so callers can't touch the live Cond/lock state; permission
// filtering (is_wizard/owner) is the caller's job since this package has no DB access.
Task_Snapshot :: struct {
	id:         int,
	start_time: i64,
	owner:      values.Objid,
	this_obj:   values.Objid,
	player:     values.Objid,
	verb_loc:   values.Objid,
	verb_name:  string,
}

@(private = "file")
snapshot_of :: proc(info: ^Task_Info) -> Task_Snapshot {
	return Task_Snapshot{
		id = info.id,
		start_time = info.start_time,
		owner = info.owner,
		this_obj = info.this_obj,
		player = info.player,
		verb_loc = info.verb_loc,
		verb_name = info.verb_name,
	}
}

// snapshot_tasks returns every currently-suspended task, in no particular order.
snapshot_tasks :: proc(s: ^Scheduler) -> []Task_Snapshot {
	sync.mutex_lock(&s.meta_lock)
	defer sync.mutex_unlock(&s.meta_lock)
	out := make([]Task_Snapshot, len(s.tasks))
	i := 0
	for _, info in s.tasks {
		out[i] = snapshot_of(info)
		i += 1
	}
	return out
}

// task_snapshot looks up a single suspended task by id.
task_snapshot :: proc(s: ^Scheduler, id: int) -> (Task_Snapshot, bool) {
	sync.mutex_lock(&s.meta_lock)
	defer sync.mutex_unlock(&s.meta_lock)
	info, ok := s.tasks[id]
	if !ok {
		return {}, false
	}
	return snapshot_of(info), true
}
