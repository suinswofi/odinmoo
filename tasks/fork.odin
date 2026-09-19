package tasks

// fork, ported in spirit from tasks.c's enqueue_forked_task()/do_forked_task(). The parent
// task doesn't wait: `fork (delay) ... endfork` schedules the body to run as an independent
// task and control returns to the statement right after the fork block immediately, exactly
// like the original. Here "schedules" means "spawns an OS thread that sleeps (if delay > 0)
// then competes for the big lock like any other task" -- see scheduler.odin's header.

import "../compiler"
import "../values"
import "../vm"
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
	body:       []compiler.Stmt, // owned deep copy (see do_fork) -- freed by fork_thread_proc
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
	if !spawn_worker(job_ptr, fork_thread_proc) {
		// The fork simply doesn't happen (the original drops a task it can't queue too), but
		// everything this one had already reserved has to be given back by hand: the job's
		// owned AST/name-table/locals copies, and above all the active_forks count, which
		// scheduler_destroy would otherwise wait on forever.
		compiler.free_stmts(job_ptr.body)
		compiler.name_table_destroy(&job_ptr.names)
		fork_job_release_strings(job_ptr)
		for v in job_ptr.locals {
			values.free_var(v)
		}
		delete(job_ptr.locals)
		free(job_ptr)
		sync.wait_group_done(&s.active_forks)
	}
}

@(private = "file")
fork_thread_proc :: proc(data: rawptr) {
	job := (^Fork_Job)(data)
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
	// This thread exists only to run one forked task, so reclaim its scratch arena on the way
	// out -- context.temp_allocator is per-thread and only ever reclaimed explicitly, so
	// without this every forked task would leave its scratch memory behind for good.
	defer free_all(context.temp_allocator)

	if job.delay_secs > 0 {
		time.sleep(time.Duration(job.delay_secs * f64(time.Second)))
	}

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
