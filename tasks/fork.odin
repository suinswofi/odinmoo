package tasks

// fork, ported in spirit from tasks.c's enqueue_forked_task()/do_forked_task(). The parent
// task doesn't wait: `fork (delay) ... endfork` schedules the body to run as an independent
// task and control returns to the statement right after the fork block immediately, exactly
// like the original. Here "schedules" means "spawns an OS thread that sleeps (if delay > 0)
// then competes for the big lock like any other task" -- see scheduler.odin's header.

import "../compiler"
import "../values"
import "../vm"
import "core:sync"
import "core:thread"
import "core:time"

// make_do_fork returns a vm.World-compatible do_fork hook bound to this scheduler. objdb's
// Object_World wiring passes this in place of the nil stub from earlier phases.
make_do_fork :: proc(s: ^Scheduler) -> proc(w: ^vm.World, delay: values.Var, body: []compiler.Stmt, names: ^compiler.Name_Table, ctx: ^vm.Eval_Context) {
	scheduler_for_fork = s
	return do_fork
}

// A package-level binding for the active scheduler, since vm.World's do_fork field is a
// plain proc pointer with no closure/user-data slot of its own (the other hooks thread
// state through `w.user_data`; do_fork historically didn't need to). Fine for a single
// server process with one scheduler, which is the only configuration this port targets.
@(private = "file")
scheduler_for_fork: ^Scheduler

@(private = "file")
Fork_Job :: struct {
	s:          ^Scheduler,
	w:          ^vm.World,
	body:       []compiler.Stmt,
	names:      ^compiler.Name_Table,
	locals:     []values.Var,
	delay_secs: f64,
	this:       values.Objid,
	player:     values.Objid,
	caller:     values.Objid,
	programmer: values.Objid,
	verb_loc:   values.Objid,
	verb_name:  string,
	debug:      bool,
	task_id:    int,
}

@(private = "file")
do_fork :: proc(w: ^vm.World, delay: values.Var, body: []compiler.Stmt, names: ^compiler.Name_Table, ctx: ^vm.Eval_Context) {
	s := scheduler_for_fork
	delay_secs := 0.0
	#partial switch delay.type {
	case .Int:
		delay_secs = f64(delay.data.num)
	case .Float:
		delay_secs = delay.data.fnum
	}

	// The forked task gets its OWN independent copy of the current variable bindings --
	// mutations in the parent after this point (or in the fork, concurrently once it
	// starts) never cross back, matching the original's rt_env snapshot in
	// enqueue_forked_task().
	locals := make([]values.Var, len(ctx.activation.locals))
	for v, i in ctx.activation.locals {
		locals[i] = values.var_ref(v)
	}

	job := Fork_Job{
		s          = s,
		w          = w,
		body       = body,
		names      = names,
		locals     = locals,
		delay_secs = delay_secs,
		this       = ctx.activation.this,
		player     = ctx.activation.player,
		caller     = ctx.activation.this, // the forking verb becomes the forked task's caller
		programmer = ctx.activation.programmer,
		verb_loc   = ctx.activation.verb_loc,
		verb_name  = ctx.activation.verb_name,
		debug      = ctx.activation.debug,
		task_id    = new_task_id(s),
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
	thread.create_and_start_with_data(job_ptr, fork_thread_proc, init_context = context, self_cleanup = true)
}

@(private = "file")
fork_thread_proc :: proc(data: rawptr) {
	job := (^Fork_Job)(data)
	defer free(job)
	defer sync.wait_group_done(&job.s.active_forks)
	// This thread exists only to run one forked task, so reclaim its scratch arena on the way
	// out -- context.temp_allocator is per-thread and only ever reclaimed explicitly, so
	// without this every forked task would leave its scratch memory behind for good.
	defer free_all(context.temp_allocator)

	if job.delay_secs > 0 {
		time.sleep(time.Duration(job.delay_secs * f64(time.Second)))
	}

	sync.mutex_lock(&job.s.big_lock)
	defer sync.mutex_unlock(&job.s.big_lock)

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
	}
	defer vm.activation_destroy(&act)

	r := vm.run(job.body, job.names, job.w, &act)
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
