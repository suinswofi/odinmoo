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
import "base:runtime"
import "core:sync"
import "core:thread"
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

// scheduler_shutdown brings outstanding tasks to an end and waits for them, so the caller can
// safely tear down the database they are running against. Call it once, after the network
// layer has stopped (so nothing new arrives), and before destroying the World/Database.
//
// Without this, shutdown races every forked task still in flight: `active_forks` existed to be
// waited on but nothing ever waited on it, so a `fork` body could still be executing verb code
// against the object DB while main() was freeing it. The final checkpoint is unaffected (it is
// taken under big_lock), but the process could still crash on the way out, and a task could
// still be halfway through mutating the DB at the instant it was dumped.
//
// Suspended tasks are killed rather than waited for: they are threads parked on a condition
// variable with no deadline, so waiting would simply never return. They are not lost work in
// any sense the DB file records either -- this port cannot serialize a native call stack, so
// the "suspended tasks" trailer is written back exactly as it was loaded regardless (see
// dbfile/task_queue.odin). Killing them makes each one's suspend() raise, which unwinds it
// normally, which is what lets the wait below terminate.
//
// One thing it cannot bound: a forked task in an unterminating loop. This port has no tick
// budget to cut one off with, so shutdown would wait on it. That is the same exposure the
// server already has while running, not a new one introduced here.
scheduler_shutdown :: proc(s: ^Scheduler) {
	sync.mutex_lock(&s.meta_lock)
	for _, info in s.tasks {
		info.killed = true
		sync.cond_signal(&info.cond)
	}
	sync.mutex_unlock(&s.meta_lock)
	sync.wait_group_wait(&s.active_forks)
	reap_workers()
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

// spawn_worker starts a background thread running `fn(data)`, with two deliberate choices
// that every worker thread in this server depends on.
//
// 1. The thread BODY inherits the caller's context, allocator included, and that is
//    required: a worker and the thread that spawned it co-own MOO values (a connection's
//    drain worker allocates Vars that end up in the database, which some other thread frees
//    later), so they have to allocate and free through one and the same allocator.
//
//    The thread's own bookkeeping struct does not, and must not: core:thread allocates it
//    from context.allocator at create time and frees it in the thread's epilogue -- AFTER
//    `fn` has returned, and therefore after whatever wait group `fn` used to announce that
//    it was finished. Any allocator narrower than the process itself can be torn down
//    between those two points. In the server proper this never bites (context.allocator is
//    the heap allocator and outlives everything), but it does under `odin test`, whose
//    allocator is per-test. Pinning the bookkeeping allocation to the heap allocator costs
//    nothing and makes the lifetime obviously correct rather than incidentally correct.
//
// 2. Threads are NOT created with core:thread's `self_cleanup`, even though these are all
//    fire-and-forget workers that nobody joins, because that path has a use-after-free:
//    a self-cleaning thread frees its own ^Thread as its last act, while thread.start() is
//    still touching that same struct from the spawning thread (it posts the start
//    semaphore the new thread was waiting on, and a semaphore post keeps reading the
//    semaphore after the waiter is released). ThreadSanitizer reports it as a write-to-freed
//    race between free() and sync.atomic_sema_post, and this server's hottest spawn sites
//    are per-connection and per-input-burst, so it is not a corner nobody reaches.
//
//    Instead each handle is kept and destroyed later, by a subsequent spawn, once the
//    thread has actually finished (thread.destroy joins first). Reaping on spawn keeps the
//    list bounded without a dedicated reaper thread: anything finished is collected the next
//    time any worker anywhere is started, and reap_workers() below covers shutdown.
@(private = "file")
worker_lock: sync.Mutex
@(private = "file")
workers: [dynamic]^thread.Thread

//
// Returns false if the thread could not be started at all (the OS refusing a new thread under
// load or an rlimit is the realistic case). Callers MUST handle that: every one of them
// registers the worker with a wait group BEFORE starting it, and something else later blocks
// until that group drains -- a connection's teardown on its drains and its output writer,
// server_stop on every connection, scheduler_destroy on outstanding forks. Silently dropping
// a failed spawn leaves the corresponding counter permanently above zero, which is not a lost
// worker but a server that never finishes shutting down.
spawn_worker :: proc(data: rawptr, fn: proc(data: rawptr)) -> (ok: bool) {
	body_context := context
	context.allocator = runtime.heap_allocator() // see (1): bookkeeping only, not the body

	sync.mutex_lock(&worker_lock)
	defer sync.mutex_unlock(&worker_lock)
	reap_finished_locked()
	t := thread.create_and_start_with_data(data, fn, init_context = body_context)
	if t == nil {
		return false
	}
	append(&workers, t)
	return true
}

// reap_workers joins and frees every worker thread that has finished. Called on spawn (so
// the list self-limits during normal operation) and worth calling at shutdown, after the
// waits that guarantee the workers are done, to leave nothing outstanding.
reap_workers :: proc() {
	sync.mutex_lock(&worker_lock)
	defer sync.mutex_unlock(&worker_lock)
	reap_finished_locked()
}

@(private = "file")
reap_finished_locked :: proc() {
	// `workers` is heap-allocated (spawn_worker pins the allocator before the first append),
	// so the resize below has to be made through the same allocator no matter which thread --
	// and which context -- got here. Freeing a heap block through a caller's arena is the
	// allocator mismatch this file's header is otherwise about avoiding.
	context.allocator = runtime.heap_allocator()
	kept := 0
	for t in workers {
		if thread.is_done(t) {
			thread.destroy(t) // joins, then frees the handle
		} else {
			workers[kept] = t
			kept += 1
		}
	}
	resize(&workers, kept)
}
