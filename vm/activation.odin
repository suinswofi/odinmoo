package vm

// Activation record and the World interface, ported from execute.c's `activation` struct
// and the various db_find_property/db_find_verb/call_bi_func hooks it calls out to.
//
// Architecture note (a deliberate departure from the plan's original "flat bytecode + PC"
// design): the C server needs an explicit, heap-resident activation *array* with a program
// counter specifically so `suspend()` can snapshot "where execution was" as plain data and
// resume it later -- C has no coroutines. This port instead evaluates the AST directly via
// ordinary recursive Odin calls (see eval_expr.odin/exec_stmt.odin). That's correct and far
// less code for everything the language itself does (arithmetic, control flow, try/except
// across nested verb calls -- which falls out of Odin's own call stack for free, instead of
// needing the original's marker-scanning-across-activations trick). What it does NOT yet
// support is suspending in the middle of an expression, but that capability has no caller
// yet either: `suspend()`/`read()` are Phase 5 builtins that don't exist yet. The plan is to
// revisit this in Phase 6 (task scheduler) using real OS-thread blocking (core:thread) --
// each running task parks its thread when it calls a blocking builtin, which sidesteps
// hand-rolled continuation capture entirely, something 1996 C could have done too but didn't
// need to given its single-process cooperative-scheduling design target.

import "../compiler"
import "../values"

Activation :: struct {
	locals:     []values.Var, // indexed by compiler var_id; owned
	this:       values.Objid,
	player:     values.Objid,
	caller:     values.Objid,
	programmer: values.Objid, // permissions the running code executes as
	verb_loc:   values.Objid, // object the verb is defined on
	verb_name:  string, // borrowed
	debug:      bool, // controls whether operator errors raise (catchable) or become inline ERR values
	task_id:    int, // identifies the enclosing task (Phase 6); shared by every nested verb call within it
	depth:      int, // 0 = this activation is a task's root call (invoked directly by the
	// server, not by another verb); N = N verb calls deep. Lets callers() (see
	// builtins) distinguish "am I running as a top-level task" from "was I called by
	// another verb" -- e.g. #0:do_login_command's own `if (callers()) return E_PERM;`
	// guard, which refuses to run except as a server-invoked root call.
	caller_programmer: values.Objid, // the CALLING activation's `programmer` (NOTHING for a
	// root call) -- ports execute.c's bf_caller_perms() reading
	// activ_stack[top_activ_stack-1].progr; see world_call_verb's `act.caller_programmer =
	// ctx.activation.programmer`.

	parent: ^Activation, // the CALLING activation (nil for a task's root), giving callers()
	// the real frame chain to walk -- the explicit-pointer equivalent of the original's
	// activ_stack array indexing. Only valid while the callee is executing (each Activation
	// lives on its caller's native stack frame), which is exactly callers()'s window.

	// The rest mirror execute.c's SLOT_DOBJ/SLOT_IOBJ/SLOT_DOBJSTR/SLOT_IOBJSTR/
	// SLOT_PREPSTR/SLOT_ARGSTR environment slots -- the parsed-command context a typed
	// command line produces. An ordinary nested verb call (call_verb2 in the original)
	// COPIES these from its caller's activation rather than resetting them (ENV_COPY,
	// execute.c:611-616), so they stay visible to helper verbs several calls deep without
	// each one re-parsing anything; only a fresh top-level command dispatch (do_input_task)
	// overwrites them with newly-parsed values. See objdb/world.odin's call_verb_from,
	// which implements exactly this copy-unless-overridden rule.
	dobj:     values.Objid,
	iobj:     values.Objid,
	dobjstr:  string, // borrowed
	iobjstr:  string, // borrowed
	prepstr:  string, // borrowed
	argstr:   string, // borrowed
}

// activation_make allocates a fresh local-variable environment and pre-binds the built-in
// runtime constants (NUM, OBJ, STR, LIST, ERR, and -- DBV_Float+ -- INT, FLOAT) into their
// reserved slots, ports eval_env.c's fill_in_rt_consts(). Every other local starts `.None`
// (unassigned) and correctly raises E_VARNF if read before being written -- that part IS
// real MOO behavior, not a bug (see execute.c's OP_PUSH: TYPE_NONE => E_VARNF). Without this
// binding, ordinary verb code doing `typeof(x) == OBJ` would raise E_VARNF on `OBJ` itself,
// since names.odin guarantees every compiled verb's Name_Table reserves these slots first,
// but never populates them -- that part is this proc's job, not the compiler's.
activation_make :: proc(n_locals: int, names: ^compiler.Name_Table = nil) -> Activation {
	locals := make([]values.Var, n_locals)
	for i in 0 ..< n_locals {
		locals[i] = values.none_val()
	}
	if names != nil {
		bind := [?]struct {
			name: string,
			tag:  values.Var_Type,
		}{
			{"NUM", .Int}, {"OBJ", .Obj}, {"STR", .Str}, {"LIST", .List}, {"ERR", .Err},
			{"INT", .Int}, {"FLOAT", .Float},
		}
		for b in bind {
			if slot := compiler.find(names, b.name); slot >= 0 {
				locals[slot] = values.int_val(i32(b.tag))
			}
		}
	}
	return Activation{locals = locals, debug = true, dobj = values.NOTHING, iobj = values.NOTHING}
}

activation_destroy :: proc(a: ^Activation) {
	for v in a.locals {
		values.free_var(v)
	}
	delete(a.locals)
}

// Error_Info carries a MOO exception: (code, message, value) -- the same triple `raise()`
// takes and that gets bound (as a 4-element list, code/message/value/backtrace) to a
// try/except arm's variable. `backtrace` isn't populated yet (needs Phase 4's object DB to
// build meaningful stack-frame descriptions); callers that need the full tuple shape can
// still rely on `raised_tuple()` below, which pads it in.
Error_Info :: struct {
	code:  values.Error,
	msg:   string, // owned
	value: values.Var, // owned; the `value` argument to raise(), or int(0) by default
}

error_info_destroy :: proc(e: ^Error_Info) {
	delete(e.msg)
	values.free_var(e.value)
}

// Eval_Context threads per-evaluation state through eval_expr/exec_stmt: the current
// activation, the World callback table for anything needing the (not-yet-built) object DB,
// and the `$`-expression base stack (ports EOP_LENGTH's trick of reading the enclosing
// index/range base back off a known stack position -- here it's just an explicit stack of
// borrowed Var references instead of a computed operand-stack offset).
Eval_Context :: struct {
	activation:   ^Activation,
	world:        ^World,
	names:        ^compiler.Name_Table, // for resolving break/continue loop-name slots to strings
	dollar_stack: [dynamic]values.Var, // borrowed; do not free
}

// Call_Result is the uniform shape every World hook returns: either a value, or a raised
// error (same triple as Error_Info, kept separate to avoid a circular convenience-constructor
// dependency).
Call_Result :: struct {
	value:  values.Var,
	raised: bool,
	code:   values.Error,
	msg:    string, // owned iff raised
	rvalue: values.Var, // owned iff raised
}

call_ok :: proc(v: values.Var) -> Call_Result {return Call_Result{value = v}}

// World is the seam between the VM and everything that needs the object database (Phase 4),
// the built-in function library (Phase 5), and the task scheduler (Phase 6) -- none of which
// exist yet. A World is just a table of callbacks (Odin has no interfaces, this is the usual
// manual-vtable substitute) plus an opaque user_data pointer for whatever state the real
// implementation needs; vm_test.odin supplies a minimal mock so this package's own tests
// don't have to wait on those later phases.
World :: struct {
	user_data:    rawptr,
	// get_prop/set_prop receive the Eval_Context so the implementation can enforce the
	// original's property permission rules (execute.c's OP_GET_PROP/OP_PUT_PROP read
	// RUN_ACTIV.progr) -- same reason call_verb/call_builtin already take it.
	get_prop:     proc(w: ^World, obj: values.Objid, name: string, ctx: ^Eval_Context) -> Call_Result,
	set_prop:     proc(w: ^World, obj: values.Objid, name: string, value: values.Var, ctx: ^Eval_Context) -> Call_Result,
	call_verb:    proc(w: ^World, obj: values.Objid, name: string, args: values.Var, ctx: ^Eval_Context) -> Call_Result,
	call_builtin: proc(w: ^World, name: string, is_known: bool, args: values.Var, ctx: ^Eval_Context) -> Call_Result,
	// var_id is the `fork ident (...)` variable slot, or -1 for a plain `fork (...)`: the
	// implementation must bind the new task's id there in the CALLING activation's locals
	// before snapshotting them, so both the parent and the forked task see it (tasks.c's
	// enqueue_forked_task2 mutates the shared rt_env before copy_rt_env).
	do_fork:      proc(w: ^World, delay: values.Var, body: []compiler.Stmt, names: ^compiler.Name_Table, var_id: int, ctx: ^Eval_Context),
}
