package vm

// Per-task resource budget: the tick and wall-clock ceilings that stop a single task from
// running forever, porting the effect of tasks.c's task_timeout/out-of-ticks handling
// (options.h's DEFAULT_MAX_TICKS/DEFAULT_MAX_SECONDS) onto this port's very different
// execution model.
//
// Why this exists at all, stated plainly, because an earlier revision of this server
// deliberately did without it and said so in several headers: every task here is a real OS
// thread, and a running task holds Scheduler.big_lock for as long as it is executing MOO
// code. That makes an unterminating loop not a slow task but a dead SERVER -- `while (1)
// x = 1; endwhile` from any player who can get MOO code to run parks the one lock every
// other task needs, forever. Nothing else in the system can preempt it: kill_task() only
// works on tasks that are suspended (tasks/suspend.odin), and scheduler_shutdown() waits on
// exactly the thread that is spinning, so even SIGINT can't get the process down. The
// original never has this exposure, because its interpreter counts down a tick budget in its
// own opcode loop and aborts the task when it hits zero.
//
// What a "tick" is here differs from the original of necessity: there is no bytecode and no
// opcode loop to hang a counter off (see activation.odin's architecture note), so the unit is
// one executed STATEMENT (exec_stmt.odin charges exactly one per statement). That is coarser
// than a bytecode op but has the property that actually matters -- every loop iteration and
// every verb call costs at least one -- so no amount of MOO code can run unboundedly without
// being charged. It also means the count is not comparable op-for-op with the original's; the
// limits are the original's numbers anyway (DEFAULT_FG_TICKS etc., overridden by
// $server_options exactly as there), on the grounds that core code compares ticks_left()
// against thresholds picked for them ($command_utils:suspend_if_needed and its callers), and
// a statement costs at least one bytecode op, so the same number is never stricter here.
//
// The seconds limit is the second half of the budget, and its limits must be stated honestly because
// an earlier version of this comment overstated them. It is checked every CLOCK_CHECK_TICKS
// charges -- and a charge only happens BETWEEN statements, so the deadline is unreachable while
// a single built-in runs. It therefore bounds a task that executes many slow statements; it does
// NOT bound one statement that is slow by itself.
//
// That distinction was not academic. The regex engine used to reset its step budget once per
// start position, so a single match() cost len(subject) x MAX_STEPS -- 52 seconds for a
// 2000-byte subject, charged one tick, with big_lock held throughout, which is precisely the
// server-wedging this file exists to prevent. The fix was in regex.odin (the budget is now
// per-call), not here. The invariant to preserve when adding a built-in: it must do work
// bounded by its inputs, and its inputs are bounded by values.MAX_STR_LEN / MAX_LIST_LEN. A
// built-in that can loop on its own recognizance needs its own internal ceiling.
//
// An exhausted budget aborts the task UNCATCHABLY (Error_Info.uncatchable, honored by
// exec_try_except/exec_try_finally). That is not fastidiousness about matching the original,
// which aborts the whole task rather than raising anything: a catchable abort would be
// useless here, since `while (1) try x = 1; except (ANY) endtry endwhile` would swallow it
// and keep the lock exactly as before.
//
// Two consequences of that, both deliberate and neither free:
//
//   - `try ... finally` handlers do NOT run on a budget abort (exec_try_finally). Core code
//     uses finally to restore set_task_perms, locks and "in use" flags, and those are left
//     unrestored. Running the handler is not an option -- the task is already out of budget, so
//     every statement in it re-aborts and a loop in it would spin -- and the original doesn't
//     face the question at all, because it kills an out-of-ticks task where it stands with no
//     unwind. Skipping is the closest available behaviour, not a costless one.
//   - budget_renew resets exhaustion completely rather than topping the allowance up, so a task
//     that calls suspend() can never be terminated by the budget: `while (1) suspend(0);
//     endwhile` runs forever. That matches the original, where a resumed task is requeued as a
//     new background task with a full budget of its own, and it is safe here for the reason the
//     budget exists at all -- a suspended task is not holding big_lock.

import "../values"
import "core:strings"
import "core:time"

// DEFAULT_FG_TICKS/... are the original's options.h defaults. As in the original they are only
// defaults: $server_options.fg_ticks/fg_seconds/bg_ticks/bg_seconds override them, looked up
// anew every time a task begins or resumes (execute.c's run_interpreter), through
// World.task_limits. "fg" is a task started by player input or by the server itself that has
// never suspended; "bg" is a forked task, or any task resuming from suspend()/read().
DEFAULT_FG_TICKS :: 30_000
DEFAULT_BG_TICKS :: 15_000
DEFAULT_FG_SECONDS :: 5
DEFAULT_BG_SECONDS :: 3
// DEFAULT_MAX_STACK_DEPTH is options.h's DEFAULT_MAX_STACK_DEPTH, overridable by
// $server_options.max_stack_depth and fixed for a task when it is created.
DEFAULT_MAX_STACK_DEPTH :: 50

// MAX_TICKS/MAX_SECONDS are kept as names for the foreground defaults (tests and tools refer to
// them).
MAX_TICKS :: DEFAULT_FG_TICKS
MAX_SECONDS :: f64(DEFAULT_FG_SECONDS)

// Task_Limits is what World.task_limits answers: the allowance a task gets for one run.
Task_Limits :: struct {
	ticks:     int,
	seconds:   f64,
	max_depth: int,
}

default_limits :: proc(background: bool) -> Task_Limits {
	if background {
		return Task_Limits{DEFAULT_BG_TICKS, f64(DEFAULT_BG_SECONDS), DEFAULT_MAX_STACK_DEPTH}
	}
	return Task_Limits{DEFAULT_FG_TICKS, f64(DEFAULT_FG_SECONDS), DEFAULT_MAX_STACK_DEPTH}
}

// How many charges may happen between two wall-clock checks. Reading the clock is orders of
// magnitude more expensive than decrementing a counter, and this runs on every statement and
// every loop iteration; 256 keeps that cost negligible while still bounding how far past
// the seconds limit a task of pathologically slow individual statements can get.
@(private = "file")
CLOCK_CHECK_TICKS :: 256

Budget_Exhaustion :: enum {
	None,
	Ticks,
	Seconds,
}

// Task_Budget is the per-task state every activation of one task shares (call_verb_from and
// bf_eval copy the pointer): the tick/second allowance, the verb-depth ceiling, and the record
// of where the most recent error was raised (see traceback.odin).
Task_Budget :: struct {
	ticks_left: int,
	max_seconds: f64,
	started:    time.Tick,
	out_of:     Budget_Exhaustion, // sticky once set: the abort must not be retryable
	max_depth:  int, // $server_options.max_stack_depth as of the task's creation

	// killed is set when kill_task() ends this task while it is parked. The original simply
	// frees a killed task's VM: nothing runs, nothing is reported. Here the parked thread has to
	// unwind, so it does so uncatchably and the task's runner reports nothing.
	killed: bool,

	// world lets budget_renew look up the background limits a resumed task gets.
	world: ^World,

	// Where the most recent error raised in this task came from -- see traceback.odin.
	err_serial: int,
	err_frames: [dynamic]Frame,
}

// budget_open initializes a task's budget with the limits World.task_limits reports (or the
// defaults if there is no such hook). Pair with budget_close.
budget_open :: proc(b: ^Task_Budget, world: ^World, background: bool) {
	b^ = {}
	b.world = world
	limits := default_limits(background)
	if world != nil && world.task_limits != nil {
		limits = world.task_limits(world, background)
	}
	b.max_depth = limits.max_depth
	budget_set(b, limits)
}

budget_close :: proc(b: ^Task_Budget) {
	frames_clear(&b.err_frames)
	delete(b.err_frames)
	b.err_frames = nil
}

@(private = "file")
budget_set :: proc(b: ^Task_Budget, limits: Task_Limits) {
	b.ticks_left = limits.ticks
	b.max_seconds = limits.seconds
	b.started = time.tick_now()
	b.out_of = .None
}

// budget_init gives b the default foreground allowance with no World. Kept for callers that
// drive the interpreter directly (tests).
budget_init :: proc(b: ^Task_Budget) {
	budget_set(b, default_limits(false))
	if b.max_depth == 0 {
		b.max_depth = DEFAULT_MAX_STACK_DEPTH
	}
}

// budget_renew hands the task a fresh allowance. Called when a task comes back from
// suspend()/read(): the time it spent parked was not spent holding big_lock, so charging it
// against the budget would be charging the task for someone else's work. The original does the
// same thing from the other direction: a resumed task is re-queued as a new BACKGROUND task, so
// it gets the bg limits, looked up afresh.
budget_renew :: proc(b: ^Task_Budget) {
	if b == nil {
		return
	}
	limits := default_limits(true)
	if b.world != nil && b.world.task_limits != nil {
		limits = b.world.task_limits(b.world, true)
	}
	budget_set(b, limits)
}

// budget_charge bills one statement and reports whether the task may continue. A nil budget
// means "unmetered", which is what vm_test.odin's direct exec_stmt calls and any other
// embedding that never goes through run() get.
budget_charge :: proc(b: ^Task_Budget) -> bool {
	if b == nil {
		return true
	}
	if b.out_of != .None {
		return false
	}
	if b.ticks_left <= 0 {
		b.out_of = .Ticks
		return false
	}
	b.ticks_left -= 1
	if b.ticks_left % CLOCK_CHECK_TICKS == 0 {
		if time.duration_seconds(time.tick_since(b.started)) > b.max_seconds {
			b.out_of = .Seconds
			return false
		}
	}
	return true
}

// budget_seconds_left reports the wall-clock remainder, for the seconds_left() built-in.
// Never negative: a task that has overrun but not yet been charged again reads 0.
budget_seconds_left :: proc(b: ^Task_Budget) -> int {
	if b == nil {
		return int(MAX_SECONDS)
	}
	remaining := b.max_seconds - time.duration_seconds(time.tick_since(b.started))
	if remaining < 0 {
		return 0
	}
	return int(remaining)
}

budget_ticks_left :: proc(b: ^Task_Budget) -> int {
	if b == nil {
		return MAX_TICKS
	}
	return b.ticks_left
}

// budget_abort_message names the limit that was hit, for the uncatchable Error_Info the
// interpreter unwinds with (and, with MOO_TRACE_ERRORS, for the log line).
budget_abort_message :: proc(b: ^Task_Budget) -> string {
	if b != nil && b.out_of == .Seconds {
		return "Task ran out of seconds"
	}
	return "Task ran out of ticks"
}

// budget_abort_error builds that Error_Info. E_QUOTA ("Resource limit exceeded") is the
// closest the MOO error set comes; the original raises nothing at all here, it just kills
// the task, so there is no upstream code to match -- and because the abort is uncatchable
// the code is only ever seen in a log line or a task's final unwind, never by a handler.
budget_abort_error :: proc(b: ^Task_Budget) -> Error_Info {
	return Error_Info {
		code = .E_QUOTA,
		msg = strings.clone(budget_abort_message(b)), // owned, like every other Error_Info msg
		value = values.int_val(0),
		uncatchable = true,
	}
}
