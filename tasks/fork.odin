package tasks

// fork, ported in spirit from tasks.c's enqueue_forked_task()/do_forked_task(). The parent
// task doesn't wait: `fork (delay) ... endfork` schedules the body to run as an independent
// task and control returns to the statement right after the fork block immediately, exactly
// like the original. Here "schedules" means "spawns an OS thread that competes for the big
// lock like any other task" -- see scheduler.odin's header.
//
// A DELAYED fork does not get its thread until its start time. It waits in the scheduler's
// pending_forks heap, and a single fork-timer thread starts each one when it comes due. Each
// delayed fork used to be its own thread asleep in time.sleep from the moment it was forked,
// which cost three things at once: shutdown waited out the longest pending delay (nothing
// could interrupt the sleep), kill_task() couldn't reach a fork that hadn't started (it wasn't
// registered anywhere), and every pending fork held an OS thread -- 10000 `fork (2)`s ran into
// the process thread limit and 2113 of them were silently dropped, sharing that limit with
// connections and their writer threads. Now a pending fork is a heap entry and a registry
// entry, whatever its delay.
//
// And a fork that is due -- a `fork (0)`, or a delayed one whose time has come -- does not get
// a thread of its own either: it joins the scheduler's run queue, which a pool of fork workers
// drains in order. Only one task can hold big_lock at a time, so a thread per runnable fork
// buys nothing but threads: moving the sleep into a timer alone just moved the thread storm to
// the deadline, when 10000 due forks became 10000 threads queued on big_lock and 2107 were
// still dropped. The pool keeps ONE worker runnable, and starts another only when a worker's
// task parks in suspend() or read() (park_wait's fork_worker_parked) -- a parked task needs its
// thread, and the queue must not wait on it. So threads scale with parked tasks, as they
// already did, and never with forks. Draining in order is also the original's behavior: its
// forked tasks run from one queue, in the order they came due.

import "../compiler"
import "../values"
import "../vm"
import "core:container/queue"
import "core:strings"
import "core:sync"
import "core:time"

// wire_do_fork points a vm.World's fork hook at this scheduler. objdb's Object_World wiring
// calls this in place of the nil stub from earlier phases.
//
// The scheduler travels in the World's own fork_data slot rather than a package-level
// global. It used to be a global -- vm.World's do_fork is a plain proc pointer with no
// closure, and one server process has exactly one scheduler -- but "exactly one scheduler"
// is an assumption the type system never enforced, and every additional World silently
// re-pointed the global at ITS scheduler: whichever was wired last won, and forks belonging
// to the others then took the wrong big_lock, i.e. ran MOO code against a database no lock
// was serializing, and signalled the wrong active_forks group, so scheduler_destroy no
// longer waited for them. Two Worlds in one process is exactly what `odin test` produces
// when it runs tests in parallel, which is how this surfaced (as ~20% flaky netio runs,
// and a ThreadSanitizer report on the global itself).
wire_do_fork :: proc(w: ^vm.World, s: ^Scheduler) {
	w.do_fork = do_fork
	w.fork_data = s
}

@(private = "file")
Fork_Job :: struct {
	s:          ^Scheduler,
	w:          ^vm.World,
	body:       []compiler.Stmt, // owned deep copy (see do_fork) -- freed by run_fork_job
	names:      compiler.Name_Table, // owned copy, same lifetime story
	locals:     []values.Var,
	delay_secs: f64,
	this:       values.Objid,
	player:     values.Objid,
	caller:     values.Objid,
	programmer: values.Objid,
	verb_loc:   values.Objid,
	debug:      bool,
	task_id:    int,

	// Every string below is an OWNED clone, and that is the whole point of them being here.
	// The Activation they are copied from BORROWS all of them, from owners that are gone long
	// before this job runs: verb_name points at the caller's evaluated verb-name Var (freed
	// when the calling expression finishes), at a Parsed_Command.verb (freed when
	// dispatch_command returns), or at a string literal inside an eval()'d AST (freed when
	// bf_eval returns) -- while a fork may not start for another delay_secs seconds, and then
	// hands the pointer straight to register_task, which queued_tasks()/task_stack() clone
	// from and pass() re-searches by. Borrowing it was a genuine use-after-free, reachable
	// from an ordinary `;#obj:verb()` where the verb forks: ASan caught the read in objdb's
	// queued_task_entry, against memory freed by the eval AST's teardown.
	//
	// The command-context strings have exactly the same owners and exactly the same problem;
	// they are carried at all because the original's enqueue_forked_task() copies the whole
	// activation, so a forked task's callees see the dobj/argstr context the forking verb had
	// (this port used to leave them empty, and dobj/iobj defaulted to Objid(0) -- i.e. #0, the
	// System Object, not #-1).
	verb_name:  string,
	dobjstr:    string,
	iobjstr:    string,
	prepstr:    string,
	argstr:     string,
	dobj:       values.Objid,
	iobj:       values.Objid,
}

// fork_job_release_strings frees the owned clones above. Shared by the thread proc's normal
// exit and by do_fork's "couldn't start the thread" unwind, so the two can't drift.
@(private = "file")
fork_job_release_strings :: proc(job: ^Fork_Job) {
	delete(job.verb_name)
	delete(job.dobjstr)
	delete(job.iobjstr)
	delete(job.prepstr)
	delete(job.argstr)
}

@(private = "file")
do_fork :: proc(w: ^vm.World, delay: values.Var, body: []compiler.Stmt, names: ^compiler.Name_Table, var_id: int, ctx: ^vm.Eval_Context) {
	s := (^Scheduler)(w.fork_data)
	delay_secs := 0.0
	#partial switch delay.type {
	case .Int:
		delay_secs = f64(delay.data.num)
	case .Float:
		delay_secs = delay.data.fnum
	}

	// `fork ident (...)`: bind the new task's id into the PARENT's environment first, so the
	// snapshot below carries it into the forked task too -- exactly enqueue_forked_task2's
	// order (assign into the shared rt_env, then copy_rt_env).
	task_id := new_task_id(s)
	if var_id >= 0 && var_id < len(ctx.activation.locals) {
		values.free_var(ctx.activation.locals[var_id])
		ctx.activation.locals[var_id] = values.int_val(i32(task_id))
	}

	// The forked task gets its OWN independent copy of the current variable bindings --
	// mutations in the parent after this point (or in the fork, concurrently once it
	// starts) never cross back, matching the original's rt_env snapshot in
	// enqueue_forked_task().
	locals := make([]values.Var, len(ctx.activation.locals))
	for v, i in ctx.activation.locals {
		locals[i] = values.var_ref(v)
	}

	// Deep-copy the fork body and name table: the original refcounts the enclosing Program
	// (enqueue_forked_task2's program_ref()) so a queued fork survives whatever happens to
	// the code that spawned it -- set_verb_code() swapping the verb out from under it,
	// eval()'s program being freed when eval() returns. This port's ASTs aren't refcounted,
	// so the fork takes its own copy instead; without this, the fork thread would race the
	// AST owner's teardown and run freed memory.
	job := Fork_Job{
		s          = s,
		w          = w,
		body       = compiler.clone_stmts(body),
		names      = names != nil ? compiler.name_table_clone(names) : compiler.Name_Table{},
		locals     = locals,
		delay_secs = delay_secs,
		this       = ctx.activation.this,
		player     = ctx.activation.player,
		caller     = ctx.activation.this, // the forking verb becomes the forked task's caller
		programmer = ctx.activation.programmer,
		verb_loc   = ctx.activation.verb_loc,
		debug      = ctx.activation.debug,
		task_id    = task_id,
		// Cloned, never borrowed -- see Fork_Job's comment on why this is load-bearing.
		verb_name  = strings.clone(ctx.activation.verb_name),
		dobjstr    = strings.clone(ctx.activation.dobjstr),
		iobjstr    = strings.clone(ctx.activation.iobjstr),
		prepstr    = strings.clone(ctx.activation.prepstr),
		argstr     = strings.clone(ctx.activation.argstr),
		dobj       = ctx.activation.dobj,
		iobj       = ctx.activation.iobj,
	}

	sync.wait_group_add(&s.active_forks, 1)
	// Fork_Job is too large for thread.run_with_poly_data's inline (register-sized) data
	// slots, so it's heap-allocated and passed as a raw pointer instead; the thread proc
	// takes ownership and frees it.
	//
	// init_context = context is load-bearing, not decoration: a freshly spawned Odin
	// thread does NOT inherit the calling thread's context (allocator included) unless
	// told to. Without this, the forked thread would free memory allocated under the
	// caller's context.allocator (e.g. under `odin test`'s per-thread tracking allocator)
	// using a different, uninitialized default context -- which doesn't crash cleanly, it
	// hangs. Cost a good hour to track down via a bisected trace; worth a paragraph so it
	// doesn't get "cleaned up" as noise later.
	job_ptr := new_clone(job)
	if delay_secs > 0 {
		schedule_fork(s, job_ptr)
		return
	}
	sync.mutex_lock(&s.meta_lock)
	enqueue_runnable_locked(s, job_ptr)
	sync.mutex_unlock(&s.meta_lock)
}

// enqueue_runnable_locked adds a due fork to the run queue, starting a fork worker if none is
// runnable. Caller holds meta_lock.
@(private = "file")
enqueue_runnable_locked :: proc(s: ^Scheduler, job: ^Fork_Job) {
	if s.shutting_down {
		discard_fork_job(job)
		return
	}
	queue.push_back(&s.run_queue, rawptr(job))
	if s.runners == 0 {
		start_runner_locked(s)
	}
}

// start_runner_locked starts a fork worker. Caller holds meta_lock. If no thread can be had,
// the queue waits for the next enqueue or park to try again; shutdown discards it either way.
start_runner_locked :: proc(s: ^Scheduler) {
	s.runners += 1
	sync.wait_group_add(&s.service_wg, 1)
	if !spawn_worker(s, fork_worker_proc) {
		s.runners -= 1
		sync.wait_group_done(&s.service_wg)
	}
}

// fork_worker_proc runs queued forks in order until the queue is empty -- or until another
// worker is runnable too (one whose task came back from suspend()), so the pool settles back
// to one.
@(private = "file")
fork_worker_proc :: proc(data: rawptr) {
	s := (^Scheduler)(data)
	// Registered first so it runs last: shutdown and destroy wait on service_wg before tearing
	// down the scheduler this thread is still touching.
	defer sync.wait_group_done(&s.service_wg)
	fork_worker_of = s

	sync.mutex_lock(&s.meta_lock)
	for {
		if s.shutting_down {
			drop_runnable_forks_locked(s)
		}
		if queue.len(s.run_queue) == 0 {
			break
		}
		job := (^Fork_Job)(queue.pop_front(&s.run_queue))
		sync.mutex_unlock(&s.meta_lock)
		run_fork_job(job)
		sync.mutex_lock(&s.meta_lock)
		if s.runners > 1 {
			break
		}
	}
	s.runners -= 1
	sync.mutex_unlock(&s.meta_lock)
}

// fork_worker_of marks a fork-worker thread, with the scheduler it serves, so park_wait can
// tell when the task that is parking is holding up that scheduler's run queue.
@(thread_local)
fork_worker_of: ^Scheduler

// fork_worker_parked/fork_worker_unparked are park_wait's hooks around the wait itself; both
// are called with meta_lock held. A parked worker stops counting as runnable, and if that
// leaves the queue with no one to drain it, another worker starts.
fork_worker_parked :: proc(s: ^Scheduler) {
	if fork_worker_of != s {
		return
	}
	s.runners -= 1
	if s.runners == 0 && queue.len(s.run_queue) > 0 {
		start_runner_locked(s)
	}
}

fork_worker_unparked :: proc(s: ^Scheduler) {
	if fork_worker_of == s {
		s.runners += 1
	}
}

// discard_fork_job gives back everything a fork that will never run had reserved: the job's
// owned AST/name-table/locals copies, and above all the active_forks count, which
// scheduler_shutdown would otherwise wait on forever.
@(private = "file")
discard_fork_job :: proc(job: ^Fork_Job) {
	s := job.s
	compiler.free_stmts(job.body)
	compiler.name_table_destroy(&job.names)
	fork_job_release_strings(job)
	for v in job.locals {
		values.free_var(v)
	}
	delete(job.locals)
	free(job)
	sync.wait_group_done(&s.active_forks)
}

// schedule_fork queues a delayed fork for the fork timer, registering it as a task so
// kill_task() and queued_tasks() can see it, and starts the timer thread if none is running.
@(private = "file")
schedule_fork :: proc(s: ^Scheduler, job: ^Fork_Job) {
	deadline := time.time_add(time.now(), time.Duration(job.delay_secs * f64(time.Second)))
	info := new(Task_Info)
	info.id = job.task_id
	info.fork_pending = true
	info.start_time = time.to_unix_seconds(deadline) // when it will run, as the original reports
	info.owner = job.programmer
	info.this_obj = job.this
	info.player = job.player
	info.verb_loc = job.verb_loc
	info.verb_name = job.verb_name // the job's own clone, which outlives this registry entry

	sync.mutex_lock(&s.meta_lock)
	if s.shutting_down {
		sync.mutex_unlock(&s.meta_lock)
		free(info)
		discard_fork_job(job)
		return
	}
	s.tasks[info.id] = info
	pending_push(s, Pending_Fork{deadline = deadline, job = job, info = info})
	start_timer := !s.timer_running
	if start_timer {
		s.timer_running = true
		sync.wait_group_add(&s.service_wg, 1)
	}
	sync.cond_signal(&s.timer_cond)
	sync.mutex_unlock(&s.meta_lock)

	if start_timer && !spawn_worker(s, fork_timer_proc) {
		// No timer thread: this fork -- and anything already pending -- is dropped, the same
		// outcome as a fork that can't get its own thread.
		sync.mutex_lock(&s.meta_lock)
		s.timer_running = false
		drop_pending_forks_locked(s)
		sync.mutex_unlock(&s.meta_lock)
		sync.wait_group_done(&s.service_wg)
	}
}

// fork_timer_proc starts each pending fork when its deadline arrives, and exits as soon as none
// are pending (the next delayed fork starts a new one), so an idle server has no timer thread.
@(private = "file")
fork_timer_proc :: proc(data: rawptr) {
	s := (^Scheduler)(data)
	// Registered first so it runs last: shutdown and destroy wait on service_wg before tearing
	// down the scheduler this thread is still touching.
	defer sync.wait_group_done(&s.service_wg)

	sync.mutex_lock(&s.meta_lock)
	for {
		if len(s.pending_forks) == 0 {
			s.timer_running = false
			break
		}
		if s.shutting_down {
			drop_pending_forks_locked(s)
			continue
		}
		head := s.pending_forks[0]
		if head.info.killed {
			pending_pop(s)
			release_pending_locked(s, head)
			continue
		}
		if remaining := time.diff(time.now(), head.deadline); remaining > 0 {
			// Woken early by a new, sooner deadline, a kill, or shutdown -- the loop re-checks.
			sync.cond_wait_with_timeout(&s.timer_cond, &s.meta_lock, remaining)
			continue
		}
		pending_pop(s)
		unregister_pending_locked(s, head.info)
		enqueue_runnable_locked(s, (^Fork_Job)(head.job))
	}
	sync.mutex_unlock(&s.meta_lock)
}

// drop_runnable_forks_locked discards every fork in the run queue. Caller holds meta_lock.
drop_runnable_forks_locked :: proc(s: ^Scheduler) {
	for queue.len(s.run_queue) > 0 {
		discard_fork_job((^Fork_Job)(queue.pop_front(&s.run_queue)))
	}
}

// drop_pending_forks_locked discards every pending fork. Caller holds meta_lock.
drop_pending_forks_locked :: proc(s: ^Scheduler) {
	for len(s.pending_forks) > 0 {
		release_pending_locked(s, pending_pop(s))
	}
}

@(private = "file")
release_pending_locked :: proc(s: ^Scheduler, pf: Pending_Fork) {
	unregister_pending_locked(s, pf.info)
	discard_fork_job((^Fork_Job)(pf.job))
}

// unregister_pending_locked removes a pending fork's registry entry, if kill_task() hasn't
// already, and frees it.
@(private = "file")
unregister_pending_locked :: proc(s: ^Scheduler, info: ^Task_Info) {
	if cur, ok := s.tasks[info.id]; ok && cur == info {
		delete_key(&s.tasks, info.id)
	}
	free(info)
}

// pending_push/pending_pop keep s.pending_forks a binary min-heap on deadline.
@(private = "file")
pending_push :: proc(s: ^Scheduler, pf: Pending_Fork) {
	h := &s.pending_forks
	append(h, pf)
	i := len(h) - 1
	for i > 0 {
		parent := (i - 1) / 2
		if time.diff(h[parent].deadline, h[i].deadline) >= 0 {
			break
		}
		h[i], h[parent] = h[parent], h[i]
		i = parent
	}
}

@(private = "file")
pending_pop :: proc(s: ^Scheduler) -> Pending_Fork {
	h := &s.pending_forks
	top := h[0]
	last := pop(h)
	if len(h) == 0 {
		return top
	}
	h[0] = last
	i := 0
	for {
		l, r := 2 * i + 1, 2 * i + 2
		m := i
		if l < len(h) && time.diff(h[l].deadline, h[m].deadline) > 0 {
			m = l
		}
		if r < len(h) && time.diff(h[r].deadline, h[m].deadline) > 0 {
			m = r
		}
		if m == i {
			break
		}
		h[i], h[m] = h[m], h[i]
		i = m
	}
	return top
}

// run_fork_job runs one forked task to completion on the calling fork worker, and frees it.
@(private = "file")
run_fork_job :: proc(job: ^Fork_Job) {
	s := job.s
	// active_forks is signalled LAST, after every one of this thread's own frees. Defers are
	// LIFO, so this one is registered FIRST. The order matters: active_forks is what
	// scheduler_destroy (and tests) wait on before tearing down the scheduler and the
	// allocator this thread has been using, so announcing "done" while frees are still
	// pending invites those frees to land in an allocator that no longer exists.
	defer sync.wait_group_done(&s.active_forks)
	defer free(job)
	defer compiler.free_stmts(job.body)
	defer compiler.name_table_destroy(&job.names)
	// Registered after free(job), so LIFO runs it BEFORE the struct holding the pointers goes.
	defer fork_job_release_strings(job)
	// Reclaim the worker's scratch arena after each task -- context.temp_allocator is
	// per-thread and only ever reclaimed explicitly, so without this every forked task would
	// leave its scratch memory behind for the life of the worker.
	defer free_all(context.temp_allocator)

	sync.mutex_lock(&s.big_lock)
	defer sync.mutex_unlock(&s.big_lock)

	act := vm.Activation{
		locals     = job.locals,
		this       = job.this,
		player     = job.player,
		caller     = job.caller,
		programmer = job.programmer,
		verb_loc   = job.verb_loc,
		verb_name  = job.verb_name,
		debug      = job.debug,
		task_id    = job.task_id,
		// The forking verb's command context, carried across so a verb CALLED by the forked
		// body sees what the original's ENV_COPY would have given it (objdb's call_verb_from
		// copies these from the caller's activation). Without them dobj/iobj defaulted to
		// Objid(0) -- #0, not #-1 -- and every *str was empty.
		dobj       = job.dobj,
		iobj       = job.iobj,
		dobjstr    = job.dobjstr,
		iobjstr    = job.iobjstr,
		prepstr    = job.prepstr,
		argstr     = job.argstr,
	}
	defer vm.activation_destroy(&act)

	r := vm.run(job.body, &job.names, job.w, &act)
	switch r.signal {
	case .Return:
		values.free_var(r.value)
	case .Raised:
		// No caller left to propagate to -- a forked task's uncaught error just ends the
		// task. The original logs it via #0:handle_uncaught_error; that needs Phase 4/5's
		// full object-DB dispatch machinery wired up to mean anything here, so for now the
		// error is simply discarded (its allocations still freed, not leaked).
		delete(r.err.msg)
		values.free_var(r.err.value)
	case .Normal, .Break, .Continue:
	}
}
