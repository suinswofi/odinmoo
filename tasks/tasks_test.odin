package tasks

// Concurrency correctness tests -- these exercise real OS threads, not just single-
// threaded logic, since that's the whole point of this package's design (see
// scheduler.odin's header). test_big_lock_serializes_concurrent_tasks in particular is a
// classic mutex-correctness test: if the big lock were broken, it would fail intermittently
// under a data race, not deterministically -- run it more than once when in doubt.
//
// Every manually-spawned thread below passes init_context = context. That is load-bearing:
// a freshly spawned Odin thread does not inherit the caller's context (allocator included)
// unless told to, and `odin test`'s tracking allocator is per-thread -- freeing memory
// across mismatched allocator contexts doesn't crash cleanly, it hangs. See fork.odin's
// do_fork for the long version of this note.

import "../compiler"
import "../values"
import "../vm"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// A trivial World for these tests: no properties/verbs, just enough to let fork/suspend
// exercise real bytecode (arithmetic, a shared counter via a package-level pointer smuggled
// through a closure-free builtin -- see counter_world_call_builtin below).
//
// IMPORTANT: this file's counter_target/counter_lock globals (the shared counter the
// big-lock tests assert on) assume one test runs at a time. Odin's test runner runs tests in
// parallel by default, so independent tests here would stomp on each other's counter and
// report bogus totals. ODIN_TEST_* knobs are compile-time defines, not env vars, so
// "remember the right flag" proved unreliable in practice (it locked up real sessions
// twice) -- instead every test below takes `serial_tests` for its whole body, so a plain
// `odin test tasks` is safe at any runner thread count.
//
// The do_fork wiring itself no longer needs this: the scheduler travels in each World's
// fork_data slot (see fork.odin's wire_do_fork), so two Schedulers in one process are fine.
@(private = "file")
serial_tests: sync.Mutex
@(private = "file")
counter_target: ^int
@(private = "file")
counter_lock: ^sync.Mutex

@(private = "file")
counter_world_call_builtin :: proc(w: ^vm.World, name: string, is_known: bool, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	if name == "bump_counter" {
		values.free_var(args)
		// Deliberately non-atomic read-modify-write with a small window, so that a broken
		// big lock (concurrent execution) would show up as a wrong final count.
		sync.mutex_lock(counter_lock)
		v := counter_target^
		time.sleep(10 * time.Microsecond)
		counter_target^ = v + 1
		sync.mutex_unlock(counter_lock)
		return vm.call_ok(values.int_val(0))
	}
	result, found := scheduler_builtin((^Scheduler)(w.user_data), name, args, ctx)
	if found {
		return result
	}
	values.free_var(args)
	return vm.Call_Result{raised = true, code = .E_VERBNF, msg = strings.clone("not found"), rvalue = values.int_val(0)}
}

@(private = "file")
make_test_world :: proc(s: ^Scheduler) -> vm.World {
	w := vm.World{user_data = s, call_builtin = counter_world_call_builtin}
	wire_do_fork(&w, s)
	return w
}

@(private = "file")
run_src :: proc(t: ^testing.T, world: ^vm.World, task_id: int, src: string) -> vm.Stmt_Result {
	r := compiler.parse_program(src, compiler.DBV_Float)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		for e in r.errors do delete(e)
		delete(r.errors)
	}
	for e in r.errors {
		testing.expectf(t, false, "parse error: %s", e)
	}
	act := vm.activation_make(len(r.names.names))
	act.task_id = task_id
	defer vm.activation_destroy(&act)
	return vm.run(r.body, &r.names, world, &act)
}

@(private = "file")
scheduler_from_test: ^Scheduler

@(test)
test_fork_runs_independently_and_does_not_block_caller :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	sync.mutex_lock(&serial_tests)
	defer sync.mutex_unlock(&serial_tests)
	s := scheduler_init()
	defer scheduler_destroy(&s)
	counter := 0
	lock: sync.Mutex
	counter_target = &counter
	counter_lock = &lock
	world := make_test_world(&s)

	sync.mutex_lock(&s.big_lock)
	r := run_src(t, &world, new_task_id(&s), `fork (0) bump_counter(); endfork return 1;`)
	sync.mutex_unlock(&s.big_lock)
	defer values.free_var(r.value)
	testing.expect(t, r.signal == .Return && r.value.data.num == 1) // caller didn't wait for the fork

	sync.wait_group_wait(&s.active_forks)
	testing.expect(t, counter == 1) // but the forked task did run, exactly once
}

@(test)
test_big_lock_serializes_concurrent_tasks :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	sync.mutex_lock(&serial_tests)
	defer sync.mutex_unlock(&serial_tests)
	s := scheduler_init()
	defer scheduler_destroy(&s)
	counter := 0
	lock: sync.Mutex
	counter_target = &counter
	counter_lock = &lock
	world := make_test_world(&s)

	// Fork N independent tasks that all race to bump the same counter. Each fork_thread_proc
	// acquires the scheduler's big lock before running its body, so even though N OS threads
	// really do exist concurrently, only one is ever inside `bump_counter` at a time.
	sync.mutex_lock(&s.big_lock)
	N :: 20
	for _ in 0 ..< N {
		r := run_src(t, &world, new_task_id(&s), `fork (0) bump_counter(); endfork return 0;`)
		values.free_var(r.value)
	}
	sync.mutex_unlock(&s.big_lock)

	sync.wait_group_wait(&s.active_forks)
	testing.expectf(t, counter == N, "expected %d, got %d (big lock did not serialize)", N, counter)
}

@(test)
test_suspend_blocks_until_resumed_from_another_thread :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	sync.mutex_lock(&serial_tests)
	defer sync.mutex_unlock(&serial_tests)
	s := scheduler_init()
	defer scheduler_destroy(&s)
	world := make_test_world(&s)
	task_id := new_task_id(&s)
	scheduler_from_test = &s

	Result_Box :: struct {
		r:    vm.Stmt_Result,
		done: sync.Wait_Group,
	}
	box := new(Result_Box)
	defer free(box)
	sync.wait_group_add(&box.done, 1)

	Args :: struct {
		t:       ^testing.T,
		world:   ^vm.World,
		task_id: int,
		box:     ^Result_Box,
	}
	args := new(Args)
	args.t = t
	args.world = &world
	args.task_id = task_id
	args.box = box

	runner :: proc(data: rawptr) {
		a := (^Args)(data)
		sync.mutex_lock(&scheduler_from_test.big_lock)
		a.box.r = run_src(a.t, a.world, a.task_id, `x = suspend(); return x + 1;`)
		sync.mutex_unlock(&scheduler_from_test.big_lock)
		// Freed BEFORE the wait group is signalled, not in a defer after it: `done` is what
		// the test body waits on before returning, and returning tears down the allocator
		// this free goes through.
		box := a.box
		free(a)
		sync.wait_group_done(&box.done)
	}
	spawn_worker(args, runner)

	// Give the suspending thread a moment to actually park, then confirm it's registered.
	for _ in 0 ..< 200 {
		if task_exists(&s, task_id) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, task_exists(&s, task_id))

	// Resume it from THIS thread (simulating "another task"), handing it a value.
	sync.mutex_lock(&s.big_lock)
	resume_args := make([]values.Var, 2)
	resume_args[0] = values.int_val(i32(task_id))
	resume_args[1] = values.int_val(41)
	rr := bf_resume(&s, values.list_val(resume_args))
	values.free_var(rr.value)
	sync.mutex_unlock(&s.big_lock)

	sync.wait_group_wait(&box.done)
	testing.expect(t, box.r.signal == .Return)
	testing.expect(t, box.r.value.data.num == 42)
	values.free_var(box.r.value)
}

@(test)
test_suspend_with_timeout :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	sync.mutex_lock(&serial_tests)
	defer sync.mutex_unlock(&serial_tests)
	s := scheduler_init()
	defer scheduler_destroy(&s)
	world := make_test_world(&s)

	sync.mutex_lock(&s.big_lock)
	start := time.now()
	r := run_src(t, &world, new_task_id(&s), `return suspend(0.05) + 1;`)
	elapsed := time.diff(start, time.now())
	sync.mutex_unlock(&s.big_lock)
	defer values.free_var(r.value)

	testing.expect(t, r.signal == .Return)
	testing.expect(t, r.value.data.num == 1) // timed out with default value 0, then +1
	testing.expectf(t, elapsed >= 40 * time.Millisecond, "suspend(0.05) returned too early: %v", elapsed)
}

@(test)
test_kill_task_raises_in_suspended_task :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	sync.mutex_lock(&serial_tests)
	defer sync.mutex_unlock(&serial_tests)
	s := scheduler_init()
	defer scheduler_destroy(&s)
	world := make_test_world(&s)
	task_id := new_task_id(&s)
	scheduler_from_test = &s

	Box :: struct {
		r:    vm.Stmt_Result,
		done: sync.Wait_Group,
	}
	box := new(Box)
	defer free(box)
	sync.wait_group_add(&box.done, 1)

	Args :: struct {
		t:       ^testing.T,
		world:   ^vm.World,
		task_id: int,
		box:     ^Box,
	}
	a := new(Args)
	a.t = t
	a.world = &world
	a.task_id = task_id
	a.box = box

	runner :: proc(data: rawptr) {
		args := (^Args)(data)
		sync.mutex_lock(&scheduler_from_test.big_lock)
		args.box.r = run_src(args.t, args.world, args.task_id, `suspend(); return 1;`)
		sync.mutex_unlock(&scheduler_from_test.big_lock)
		box := args.box // freed before signalling -- see the same pattern above
		free(args)
		sync.wait_group_done(&box.done)
	}
	spawn_worker(a, runner)

	for _ in 0 ..< 200 {
		if task_exists(&s, task_id) {
			break
		}
		time.sleep(time.Millisecond)
	}

	sync.mutex_lock(&s.big_lock)
	kill_args := make([]values.Var, 1)
	kill_args[0] = values.int_val(i32(task_id))
	kr := bf_kill_task(&s, values.list_val(kill_args))
	values.free_var(kr.value)
	sync.mutex_unlock(&s.big_lock)

	sync.wait_group_wait(&box.done)
	testing.expect(t, box.r.signal == .Raised)
	testing.expect(t, box.r.err.code == .E_INVARG)
	delete(box.r.err.msg)
	values.free_var(box.r.err.value)
}

@(test)
test_task_id_builtin :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	sync.mutex_lock(&serial_tests)
	defer sync.mutex_unlock(&serial_tests)
	s := scheduler_init()
	defer scheduler_destroy(&s)
	world := make_test_world(&s)

	sync.mutex_lock(&s.big_lock)
	r := run_src(t, &world, 12345, `return task_id();`)
	sync.mutex_unlock(&s.big_lock)
	defer values.free_var(r.value)
	testing.expect(t, r.signal == .Return && r.value.data.num == 12345)
}

// The timeout-vs-resume race: a resume() arriving just as the suspend times out must NOT
// have its value silently swallowed. bf_suspend now unregisters atomically with committing
// to the timeout, so the late resume gets a clean E_INVARG -- the caller (netio's
// wake_reader for a parked read()) keeps the line and can deliver it another way. The old
// unlock-then-unregister ordering let the resume "succeed" into a Task_Info about to be
// freed: value leaked, input line lost, nobody told.
@(test)
test_resume_after_timeout_is_invarg :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	sync.mutex_lock(&serial_tests)
	defer sync.mutex_unlock(&serial_tests)
	s := scheduler_init()
	defer scheduler_destroy(&s)
	world := make_test_world(&s)
	task_id := new_task_id(&s)

	sync.mutex_lock(&s.big_lock)
	r := run_src(t, &world, task_id, `return suspend(0);`)
	sync.mutex_unlock(&s.big_lock)
	testing.expect(t, r.signal == .Return)
	values.free_var(r.value)

	// The suspend has returned (timed out); its registry entry must already be gone, so a
	// late resume cleanly fails instead of writing into freed memory.
	resume_args := make([]values.Var, 2)
	resume_args[0] = values.int_val(i32(task_id))
	resume_args[1] = values.str_val(strings.clone("late line"))
	rr := bf_resume(&s, values.list_val(resume_args))
	if !testing.expect(t, rr.raised, "late resume must raise E_INVARG") {
		values.free_var(rr.value)
		return
	}
	testing.expectf(t, rr.code == .E_INVARG, "wanted E_INVARG, got %v", rr.code)
	delete(rr.msg)
	values.free_var(rr.rvalue)
}

// A second resume() before the first has been consumed is "not suspended" (matching the
// original's resume_task queue check) -- accepting it would overwrite and leak the first
// resume's value.
@(test)
test_double_resume_is_invarg :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	sync.mutex_lock(&serial_tests)
	defer sync.mutex_unlock(&serial_tests)
	s := scheduler_init()
	defer scheduler_destroy(&s)
	task_id := new_task_id(&s)

	// Register a parked task by hand -- no thread actually waits on it, which is exactly
	// the window this exercises: resumed but not yet torn down.
	info := register_task(&s, task_id, nil)

	first := make([]values.Var, 2)
	first[0] = values.int_val(i32(task_id))
	first[1] = values.str_val(strings.clone("first"))
	r1 := bf_resume(&s, values.list_val(first))
	testing.expect(t, !r1.raised)
	values.free_var(r1.value)

	second := make([]values.Var, 2)
	second[0] = values.int_val(i32(task_id))
	second[1] = values.str_val(strings.clone("second"))
	r2 := bf_resume(&s, values.list_val(second))
	if !testing.expect(t, r2.raised, "second resume must raise E_INVARG") {
		values.free_var(r2.value)
	} else {
		testing.expectf(t, r2.code == .E_INVARG, "wanted E_INVARG, got %v", r2.code)
		delete(r2.msg)
		values.free_var(r2.rvalue)
	}

	// Tear down what bf_suspend would have: consume the delivered value, drop the entry.
	sync.mutex_lock(&s.meta_lock)
	values.free_var(info.resume_value)
	delete_key(&s.tasks, task_id)
	sync.mutex_unlock(&s.meta_lock)
	free(info)
}

// ---- thread-safe test allocator ----
//
// Every test in this package starts real task threads (forks, and the threads that resume
// suspended tasks) and each of those inherits the calling test's `context`, allocator
// included. Under `odin test` that allocator is a per-test
// Tracking_Allocator over a Rollback_Stack -- neither of which is thread-safe -- so those
// threads and the test body allocate from one non-thread-safe allocator at once. That is not
// a theoretical hazard: it hands the same block out twice, and it showed up as a
// ThreadSanitizer report inside rollback_stack_allocator and in this package's sibling netio tests as
// roughly one-in-five spurious failures.
//
// The threads cannot simply be given a different allocator: they and the test body share
// ownership of the same values (a connection thread allocates a Var that database_destroy
// later frees on the test thread), so they must all use ONE allocator -- it just has to be a
// thread-safe one. In production it already is (the plain heap allocator); this makes it so
// under the test runner too, while keeping the tracking allocator's leak reporting intact.
//
// Usage, as the first two lines of a test:
//
//	mu: mem.Mutex_Allocator
//	context.allocator = thread_safe_allocator(&mu)
//
// `mu` lives on the test's stack, so every spawned thread must be joined before the test
// returns -- which they all are (scheduler_destroy waits for forks).
@(private = "file")
thread_safe_allocator :: proc(mu: ^mem.Mutex_Allocator) -> mem.Allocator {
	mem.mutex_allocator_init(mu, context.allocator)
	return mem.mutex_allocator(mu)
}

// ---- Regression: a Fork_Job must OWN the activation strings it carries ----
//
// Fork_Job copied ctx.activation.verb_name (and, once the command context was carried too,
// argstr and friends) as a BORROWED string. Every owner of that string is gone before a
// delayed fork runs: the caller's evaluated verb-name Var is freed when the calling expression
// finishes, a Parsed_Command.verb when dispatch_command returns, a literal inside an eval()'d
// AST when bf_eval returns. The forked task then handed the dangling pointer to register_task,
// where queued_tasks()/task_stack() clone from it and pass() re-searches by it.
//
// This was not theoretical: against a real server under ASan, `;#obj:verb()` on a verb
// containing `fork (2) suspend(60); endfork` followed by `;queued_tasks()` reported
// heap-use-after-free, reading the verb name out of the freed eval AST.
//
// What is asserted here is the OWNERSHIP INVARIANT -- that the forked task's string is a
// different allocation from the caller's -- not the use-after-free itself. That distinction
// matters: the obvious version of this test (free the caller's string, scribble over the
// memory, then read the fork's copy) was written first and PASSED against the unfixed code,
// because nothing guarantees the allocator hands that block back. Comparing the pointers is
// deterministic, and it fails the moment anyone reintroduces the borrow. Catching the
// dereference itself needs ASan, which is how the bug was found in the first place.
@(test)
test_fork_owns_the_activation_strings_it_carries :: proc(t: ^testing.T) {
	sync.mutex_lock(&serial_tests)
	defer sync.mutex_unlock(&serial_tests)

	s := scheduler_init()
	defer scheduler_destroy(&s)
	world := make_test_world(&s)

	VERB :: "forkyverbname"
	verb_name := strings.clone(VERB) // stands in for the caller-owned string a real call borrows
	defer delete(verb_name)

	r := compiler.parse_program(`fork (0) suspend(2); endfork return 1;`, compiler.DBV_Float)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		for e in r.errors do delete(e)
		delete(r.errors)
	}
	act := vm.activation_make(len(r.names.names))
	act.task_id = new_task_id(&s)
	act.verb_name = verb_name // borrowed by the Activation, exactly as a real verb call does
	defer vm.activation_destroy(&act)

	result := vm.run(r.body, &r.names, &world, &act)
	if result.signal == .Return {
		values.free_var(result.value)
	}

	got_name := ""
	got_data: [^]byte
	for _ in 0 ..< 200 {
		snaps := snapshot_tasks(&s)
		if len(snaps) == 1 {
			got_name = snaps[0].verb_name
			got_data = raw_data(snaps[0].verb_name)
			delete(snaps)
			break
		}
		delete(snaps)
		time.sleep(5 * time.Millisecond)
	}

	testing.expect(t, got_name != "")
	testing.expectf(t, got_name == VERB, "forked task reported verb_name %q, want %q", got_name, VERB)
	testing.expect(
		t,
		got_data != raw_data(verb_name),
		"the forked task is pointing at the CALLER'S verb-name string, not a clone of it -- " +
		"that pointer is dangling as soon as the calling verb returns",
	)

	scheduler_shutdown(&s) // kill the parked task and wait for the fork thread to exit
}
