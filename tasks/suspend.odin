package tasks

// suspend()/resume()/kill_task()/task_id(), the built-ins that make the scheduler visible
// to MOO code. Ported in spirit from execute.c's bf_suspend/tasks.c's resume_task(), not
// line-for-line -- see scheduler.odin's header for why this can be genuine OS-thread
// blocking instead of a saved bytecode continuation.

import "../values"
import "../vm"
import "core:strings"
import "core:sync"
import "core:time"

@(private = "file")
raise_err :: proc(code: values.Error, msg: string) -> vm.Call_Result {
	return vm.Call_Result{raised = true, code = code, msg = strings.clone(msg), rvalue = values.int_val(0)}
}

// scheduler_builtin dispatches suspend/resume/kill_task/task_id. Like builtins.call() and
// objdb's object_builtin(), found=false leaves `args` unconsumed so callers can keep
// chaining fallback dispatchers.
scheduler_builtin :: proc(s: ^Scheduler, name: string, args: values.Var, ctx: ^vm.Eval_Context) -> (result: vm.Call_Result, found: bool) {
	switch name {
	case "suspend":
		return bf_suspend(s, args, ctx), true
	case "resume":
		return bf_resume(s, args), true
	case "kill_task":
		return bf_kill_task(s, args), true
	case "task_id":
		return bf_task_id(args, ctx), true
	}
	return {}, false
}

// bf_suspend ports bf_suspend(): releases the big lock (letting some other task run),
// blocks the calling thread until resume() is called or `seconds` elapses (negative or
// absent means "forever, until an explicit resume()"), then reacquires the big lock before
// returning -- from the calling MOO code's perspective, indistinguishable from the
// original's cooperative suspend/resume except that it's backed by a real OS wait instead
// of a saved bytecode PC.
@(private = "file")
bf_suspend :: proc(s: ^Scheduler, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	n := values.list_len(args)
	seconds := -1.0
	if n >= 1 {
		v := values.list_get(args, 1)
		#partial switch v.type {
		case .Int:
			seconds = f64(v.data.num)
		case .Float:
			seconds = v.data.fnum
		case:
			values.free_var(args)
			return raise_err(.E_TYPE, "Type mismatch")
		}
	}
	values.free_var(args)

	id := ctx.activation.task_id
	info := register_task(s, id, ctx.activation)

	sync.mutex_lock(&s.meta_lock)
	sync.mutex_unlock(&s.big_lock) // stop competing for the DB while parked
	if seconds < 0 {
		for !info.woken && !info.killed {
			sync.cond_wait(&info.cond, &s.meta_lock)
		}
	} else {
		deadline := time.time_add(time.now(), time.Duration(seconds * f64(time.Second)))
		for !info.woken && !info.killed {
			remaining := time.diff(time.now(), deadline)
			if remaining <= 0 {
				break // timed out -- resumes with the default value, same as the original
			}
			sync.cond_wait_with_timeout(&info.cond, &s.meta_lock, remaining)
		}
	}
	resume_value := info.resume_value
	killed := info.killed
	sync.mutex_unlock(&s.meta_lock)
	unregister_task(s, id)
	free(info)

	sync.mutex_lock(&s.big_lock) // reacquire before touching the DB again

	if killed {
		values.free_var(resume_value)
		return raise_err(.E_INVARG, "Task killed")
	}
	// resume_value's zero value is Var{type: .Int, data: 0} (Int is Var_Type's zero
	// value) -- exactly the right default when nobody ever called resume() with a value
	// (a timeout, or a bare `resume(id)`), so no separate "was it set" check is needed.
	return vm.call_ok(resume_value)
}

// bf_resume ports resume_task(): wakes a suspended task, handing it `value` (default 0) as
// its suspend() call's return value. Does NOT touch the big lock -- the resumed task
// reacquires that itself once it wakes and returns from suspend().
bf_resume :: proc(s: ^Scheduler, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	n := values.list_len(args)
	if n < 1 || n > 2 {
		return raise_err(.E_ARGS, "Incorrect number of arguments")
	}
	id_v := values.list_get(args, 1)
	if id_v.type != .Int {
		return raise_err(.E_TYPE, "Type mismatch")
	}
	id := int(id_v.data.num)

	sync.mutex_lock(&s.meta_lock)
	info, ok := s.tasks[id]
	if !ok {
		sync.mutex_unlock(&s.meta_lock)
		return raise_err(.E_INVARG, "Task is not suspended")
	}
	if n == 2 {
		info.resume_value = values.var_ref(values.list_get(args, 2))
	}
	info.woken = true
	sync.cond_signal(&info.cond)
	sync.mutex_unlock(&s.meta_lock)
	return vm.call_ok(values.int_val(0))
}

// bf_kill_task ports kill_task(): only meaningful for a currently-suspended task (wakes it
// with `killed` set, so its suspend() call raises instead of returning a value). Killing an
// actively-running task on another thread isn't supported -- there's no safe preemption
// point to interrupt it at, the same fundamental limitation the original has for tasks
// blocked inside a built-in function, just with a different shape here.
bf_kill_task :: proc(s: ^Scheduler, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return raise_err(.E_ARGS, "Incorrect number of arguments")
	}
	id_v := values.list_get(args, 1)
	if id_v.type != .Int {
		return raise_err(.E_TYPE, "Type mismatch")
	}
	id := int(id_v.data.num)

	sync.mutex_lock(&s.meta_lock)
	info, ok := s.tasks[id]
	if !ok {
		sync.mutex_unlock(&s.meta_lock)
		return raise_err(.E_INVARG, "Task is not suspended")
	}
	info.killed = true
	sync.cond_signal(&info.cond)
	sync.mutex_unlock(&s.meta_lock)
	return vm.call_ok(values.int_val(0))
}

@(private = "file")
bf_task_id :: proc(args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 0 {
		return raise_err(.E_ARGS, "Incorrect number of arguments")
	}
	return vm.call_ok(values.int_val(i32(ctx.activation.task_id)))
}
