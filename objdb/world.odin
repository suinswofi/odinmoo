package objdb

// Real vm.World implementation, replacing vm package's own test-only Mock_World. This is
// the seam where Phase 3's VM meets Phase 1's DB, Phase 4's inheritance/permission logic,
// Phase 5's built-in function library, and (when a Scheduler is supplied) Phase 6's task
// scheduler for fork/suspend/resume/kill_task/task_id.

import "../builtins"
import "../compiler"
import "../dbfile"
import "../tasks"
import "../values"
import "../vm"
import "core:fmt"
import "core:strings"

// Connection_Hooks is how notify()/connection_name()/boot_player() reach an actual network
// connection: objdb has no notion of sockets (netio owns that), so netio fills this in
// after constructing the World, the same seam pattern as Scheduler for fork/suspend. A
// zero-valued Connection_Hooks (all nil procs) is valid -- those three builtins just report
// "no such connection" / are no-ops, which is exactly right for, say, a forked task not
// backed by any live connection.
Connection_Hooks :: struct {
	user_data:        rawptr,
	notify:           proc(user_data: rawptr, player: values.Objid, text: string) -> bool,
	notify_raw:       proc(user_data: rawptr, player: values.Objid, text: string) -> bool, // backs notify_raw() -- see connection_io.odin
	connection_name:  proc(user_data: rawptr, player: values.Objid) -> (name: string, found: bool), // name owned if found
	boot_player:      proc(user_data: rawptr, player: values.Objid),
	connected_players: proc(user_data: rawptr, include_all: bool) -> []values.Objid, // owned slice
	connected_seconds: proc(user_data: rawptr, player: values.Objid) -> (secs: i64, found: bool),

	// Back read()/force_input()/flush_input()/set_connection_option()/connection_option(s)()
	// -- see netio/input_queue.odin's header for the full design these implement.
	try_dequeue_input:    proc(user_data: rawptr, player: values.Objid) -> (line: string, ok: bool), // owned if ok
	register_reader:      proc(user_data: rawptr, player: values.Objid, task_id: int) -> bool,
	unregister_reader:    proc(user_data: rawptr, player: values.Objid, task_id: int),
	force_input:          proc(user_data: rawptr, player: values.Objid, line: string, at_front: bool) -> bool,
	flush_input:          proc(user_data: rawptr, player: values.Objid, show_messages: bool) -> bool,
	set_connection_option: proc(user_data: rawptr, player: values.Objid, option: string, value: values.Var) -> bool,
	connection_option:    proc(user_data: rawptr, player: values.Objid, option: string) -> (value: values.Var, found: bool), // owned if found
	connection_options:   proc(user_data: rawptr, player: values.Objid) -> (list: values.Var, found: bool), // owned if found

	// output_delimiters backs output_delimiters() -- the PREFIX/SUFFIX intrinsic commands
	// set these (netio/command.odin), owned strings returned empty ("") if never set.
	output_delimiters: proc(user_data: rawptr, player: values.Objid) -> (prefix: string, suffix: string, found: bool),
}

// Server_Hooks is how shutdown()/dump_database() reach the actual process-level server loop:
// objdb has no notion of "the main loop" (server/main.odin owns that, and can't be imported
// here -- it already imports objdb), so server/main.odin fills this in at startup, same seam
// pattern as Connection_Hooks. A zero-valued Server_Hooks is valid -- those two builtins just
// silently have no effect (e.g. under `-e` emergency mode, which never wires this up), rather
// than crashing.
Server_Hooks :: struct {
	user_data:          rawptr,
	request_shutdown:   proc(user_data: rawptr, message: string),
	request_checkpoint: proc(user_data: rawptr),
}

Object_World :: struct {
	db:         ^dbfile.Database,
	cache:      Compile_Cache,
	scheduler:  ^tasks.Scheduler, // nil is valid: fork/suspend/resume/kill_task/task_id just won't be available
	conn:       Connection_Hooks, // zero value is valid: notify/connection_name/boot_player just won't be available
	server_ctl: Server_Hooks, // zero value is valid: shutdown/dump_database just won't be available
}

object_world_init :: proc(db: ^dbfile.Database, scheduler: ^tasks.Scheduler = nil) -> Object_World {
	return Object_World{db = db, cache = compile_cache_init(), scheduler = scheduler}
}

object_world_destroy :: proc(w: ^Object_World) {
	compile_cache_destroy(&w.cache)
}

make_world :: proc(w: ^Object_World) -> vm.World {
	do_fork: proc(w: ^vm.World, delay: values.Var, body: []compiler.Stmt, names: ^compiler.Name_Table, var_id: int, ctx: ^vm.Eval_Context)
	if w.scheduler != nil {
		do_fork = tasks.make_do_fork(w.scheduler)
	}
	return vm.World{
		user_data = w,
		get_prop = world_get_prop,
		set_prop = world_set_prop,
		call_verb = world_call_verb,
		call_builtin = world_call_builtin,
		do_fork = do_fork,
	}
}

@(private = "file")
err_result :: proc(code: values.Error, msg: string) -> vm.Call_Result {
	return vm.Call_Result{raised = true, code = code, msg = strings.clone(msg), rvalue = values.int_val(0)}
}

@(private = "file")
world_get_prop :: proc(vw: ^vm.World, obj: values.Objid, name: string, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	w := (^Object_World)(vw.user_data)
	if !valid(w.db, obj) {
		return err_result(.E_INVIND, "Invalid indirection")
	}
	h := find_property(w.db, obj, name)
	if !h.found {
		return err_result(.E_PROPNF, "Property not found")
	}
	// Ports OP_GET_PROP's permission check (execute.c:1443-1446): built-in pseudo-properties
	// are always readable (bi_prop_protected() only bites when $server_options.protect_* is
	// set, which this port -- like a stock LambdaCore -- never has), regular properties need
	// PF_READ / ownership / wizardliness.
	if h.builtin == .None && !prop_allows(w.db, h.value_perms, h.value_owner, ctx.activation.programmer, .Read) {
		return err_result(.E_PERM, "Permission denied")
	}
	// property_value already returns an owned value (see its own comment) -- no extra
	// var_ref here.
	return vm.call_ok(property_value(w.db, obj, h))
}

// world_set_prop ports OP_PUT_PROP (execute.c:1483-1577), including the per-built-in-property
// permission/type matrix, verbatim:
//   regular property        PF_WRITE / owner / wizard, else E_PERM
//   .name                   E_TYPE unless STR; wizards always; owners only for NON-player
//                           objects (renaming a player is a wizard-only act)
//   .owner                  E_TYPE unless OBJ; wizard-only
//   .programmer, .wizard    wizard-only (wizard-bit changes are logged: "WIZARDED:")
//   .r/.w/.f                owner or wizard
//   .location, .contents    E_PERM always (they change via move(), never plain assignment)
// (An earlier version skipped ALL of this -- every read and write succeeded "matching a
// wizard-level caller", which let any code set .wizard on anything. That was a placeholder
// from before Eval_Context was threaded through, not a documented scope cut.)
@(private = "file")
world_set_prop :: proc(vw: ^vm.World, obj: values.Objid, name: string, value: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	w := (^Object_World)(vw.user_data)
	if !valid(w.db, obj) {
		values.free_var(value)
		return err_result(.E_INVIND, "Invalid indirection")
	}
	h := find_property(w.db, obj, name)
	if !h.found {
		values.free_var(value)
		return err_result(.E_PROPNF, "Property not found")
	}
	progr := ctx.activation.programmer
	owner := w.db.objects[obj].owner
	err := values.Error.E_NONE
	switch h.builtin {
	case .None:
		if !prop_allows(w.db, h.value_perms, h.value_owner, progr, .Write) {
			err = .E_PERM
		}
	case .Name:
		if value.type != .Str {
			err = .E_TYPE
		} else if !is_wizard(w.db, progr) && (is_user(w.db, obj) || progr != owner) {
			err = .E_PERM
		}
	case .Owner:
		if value.type != .Obj {
			err = .E_TYPE
		} else if !is_wizard(w.db, progr) {
			err = .E_PERM
		}
	case .Programmer:
		if !is_wizard(w.db, progr) {
			err = .E_PERM
		}
	case .Wizard:
		if !is_wizard(w.db, progr) {
			err = .E_PERM
		} else if values.is_true(value) != is_wizard(w.db, obj) {
			// Notify only on changes in state, matching the original's oklog().
			fmt.printfln("%sWIZARDED: #%d by programmer #%d",
				is_wizard(w.db, obj) ? "DE" : "", obj, progr)
		}
	case .R, .W, .F:
		if !is_wizard(w.db, progr) && progr != owner {
			err = .E_PERM
		}
	case .Location, .Contents:
		err = .E_PERM
	}
	if err != .E_NONE {
		values.free_var(value)
		msg := err == .E_TYPE ? "Type mismatch" : "Permission denied"
		return err_result(err, msg)
	}
	// set_property_value consumes `value` (storing it for a regular property, or extracting a
	// scalar/string and freeing the wrapper for a built-in like .name/.wizard). Take our own
	// reference for the return value BEFORE calling it.
	result_ref := values.var_ref(value)
	set_property_value(w.db, obj, h, value)
	return vm.call_ok(result_ref)
}

@(private = "file")
world_call_verb :: proc(vw: ^vm.World, obj: values.Objid, name: string, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	w := (^Object_World)(vw.user_data)
	return call_verb_from(w, vw, obj, obj, name, args, ctx)
}

// MAX_VERB_DEPTH caps how deep MOO verb calls may nest before E_MAXREC, matching the
// original's DEFAULT_MAX_STACK_DEPTH (options.h) exactly -- so verb code that runs on the C
// server hits the same ceiling here rather than a different one.
//
// This is load-bearing, not a tidiness limit. Because this port runs nested verb calls on the
// NATIVE call stack (see vm/activation.odin's header on why that's what makes suspend/resume
// simple), a runaway recursion isn't a growable heap array overflowing into a clean error the
// way it is in the original -- it's a native stack overflow, i.e. an immediate segfault that
// takes the whole server (and every other player's session) down with it. And it's trivially
// reachable: `.program me:loop` / `this:loop();` is enough for anyone with a programmer bit.
// So the check has to happen before recursing, and it's checked here because this is the one
// funnel every verb call goes through -- ordinary `obj:verb()`, pass(), and command dispatch
// alike. The original's $server_options.max_stack_depth override isn't supported (this port has
// no $server_options plumbing); the fixed default is the conservative direction to differ in.
MAX_VERB_DEPTH :: 50

// call_verb_from is world_call_verb's body, generalized with a separate `search_from`
// (where verb lookup starts) distinct from `this_obj` (what `this` is bound to in the
// callee). For an ordinary `obj:verb(...)` call these are the same object (world_call_verb
// above). pass()'s whole purpose is that they're NOT the same: pass(@args) re-invokes the
// same-named verb starting the inheritance search at the CURRENT verb's definer's parent
// (search_from), while `this` stays whatever it already was (this_obj) -- see
// object_builtins.odin's bf_pass.
//
// `cmd`, when non-nil, overrides dobj/iobj/dobjstr/iobjstr/prepstr/argstr with a freshly
// parsed command's values instead of copying them from the caller's activation -- this is
// do_input_task's ENV_COPY-vs-fresh-bind distinction (execute.c:611-616 vs 2369-2378): a
// brand new top-level command dispatch overwrites this context, every ordinary nested verb
// call just inherits it unchanged from whoever called it. See netio/command.odin.
//
// `vh_hint`, when its .found is true, is used directly instead of re-searching via
// find_callable_verb. This matters, not just saves a lookup: find_callable_verb requires
// VF_EXEC (the `x` permission bit), but command verbs matched via find_command_verb
// (db_find_command_verb in the original) are deliberately NOT required to have it set --
// that's real behavior, not a gap (see command.odin's find_command_verb comment). A command
// verb without VF_EXEC would be correctly matched by dispatch_command's find_verb_on and then
// wrongly rejected as E_VERBNF by a second, stricter search here if this function re-searched
// on its own; passing the already-resolved handle through keeps the two searches from
// disagreeing.
call_verb_from :: proc(w: ^Object_World, vw: ^vm.World, this_obj, search_from: values.Objid, name: string, args: values.Var, ctx: ^vm.Eval_Context, cmd: ^Parsed_Command = nil, vh_hint: Verb_Handle = {}) -> vm.Call_Result {
	defer values.free_var(args)
	if ctx.activation.depth + 1 >= MAX_VERB_DEPTH {
		return err_result(.E_MAXREC, "Too many verb calls")
	}
	if !valid(w.db, this_obj) {
		return err_result(.E_INVIND, "Invalid indirection")
	}
	vh := vh_hint
	if !vh.found {
		vh = find_callable_verb(w.db, search_from, name)
	}
	if !vh.found {
		return err_result(.E_VERBNF, "Verb not found")
	}
	cv, ok := get_compiled_verb(w.db, &w.cache, vh)
	if !ok {
		return err_result(.E_VERBNF, "Verb does not compile")
	}

	definer_obj := w.db.objects[vh.definer]
	vd := definer_obj.verbdefs[vh.index]

	act := vm.activation_make(len(cv.names.names), &cv.names)
	defer vm.activation_destroy(&act)
	act.this = this_obj
	act.player = ctx.activation.player
	act.caller = ctx.activation.this
	act.programmer = vd.owner
	act.caller_programmer = ctx.activation.programmer
	act.task_id = ctx.activation.task_id
	act.depth = ctx.activation.depth + 1
	act.parent = ctx.activation
	act.verb_loc = vh.definer
	// The DISPATCH name (`name`, e.g. "find_only" -- what the caller actually wrote), not
	// vd.name (the verbdef's full alias-list string, e.g. "find* _only* _every*"). This is
	// exactly the C server's RUN_ACTIV.verb vs RUN_ACTIV.verbname distinction
	// (execute.c:625-626) -- pass() re-searches using RUN_ACTIV.verb specifically
	// (execute.c:2606), so getting this backwards makes pass() search for a verb matching
	// the wrong string and silently dead-end with E_VERBNF.
	act.verb_name = name
	act.debug = (vd.perms & (1 << uint(Verb_Flag.Debug))) != 0

	if cmd != nil {
		act.dobj = cmd.dobj
		act.iobj = cmd.iobj
		act.dobjstr = cmd.dobjstr
		act.iobjstr = cmd.iobjstr
		act.prepstr = cmd.prepstr
		act.argstr = cmd.argstr
	} else {
		act.dobj = ctx.activation.dobj
		act.iobj = ctx.activation.iobj
		act.dobjstr = ctx.activation.dobjstr
		act.iobjstr = ctx.activation.iobjstr
		act.prepstr = ctx.activation.prepstr
		act.argstr = ctx.activation.argstr
	}

	if slot := compiler.find(&cv.names, "args"); slot >= 0 {
		act.locals[slot] = values.var_ref(args)
	}
	if slot := compiler.find(&cv.names, "this"); slot >= 0 {
		act.locals[slot] = values.obj_val(this_obj)
	}
	if slot := compiler.find(&cv.names, "player"); slot >= 0 {
		act.locals[slot] = values.obj_val(act.player)
	}
	if slot := compiler.find(&cv.names, "caller"); slot >= 0 {
		act.locals[slot] = values.obj_val(act.caller)
	}
	if slot := compiler.find(&cv.names, "verb"); slot >= 0 {
		act.locals[slot] = values.str_val(strings.clone(name))
	}
	if slot := compiler.find(&cv.names, "dobj"); slot >= 0 {
		act.locals[slot] = values.obj_val(act.dobj)
	}
	if slot := compiler.find(&cv.names, "iobj"); slot >= 0 {
		act.locals[slot] = values.obj_val(act.iobj)
	}
	if slot := compiler.find(&cv.names, "dobjstr"); slot >= 0 {
		act.locals[slot] = values.str_val(strings.clone(act.dobjstr))
	}
	if slot := compiler.find(&cv.names, "iobjstr"); slot >= 0 {
		act.locals[slot] = values.str_val(strings.clone(act.iobjstr))
	}
	if slot := compiler.find(&cv.names, "prepstr"); slot >= 0 {
		act.locals[slot] = values.str_val(strings.clone(act.prepstr))
	}
	if slot := compiler.find(&cv.names, "argstr"); slot >= 0 {
		act.locals[slot] = values.str_val(strings.clone(act.argstr))
	}

	r := vm.run(cv.body, &cv.names, vw, &act)
	switch r.signal {
	case .Return:
		return vm.call_ok(r.value)
	case .Raised:
		return vm.Call_Result{raised = true, code = r.err.code, msg = r.err.msg, rvalue = r.err.value}
	case .Normal, .Break, .Continue:
		return vm.call_ok(values.int_val(0))
	}
	return vm.call_ok(values.int_val(0))
}

// world_call_builtin tries builtins' pure dispatch table first, then this package's own
// small set of object-aware built-ins (which need `w.db` and so can't live in builtins
// without creating a package cycle -- see builtins/dispatch.odin's header note), then (if a
// Scheduler was supplied) tasks' suspend/resume/kill_task/task_id.
@(private = "file")
world_call_builtin :: proc(vw: ^vm.World, name: string, is_known: bool, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	if result, found := builtins.call(name, args); found {
		return result
	}
	w := (^Object_World)(vw.user_data)
	if result, found := object_builtin(w, name, args, ctx); found {
		return result
	}
	if w.scheduler != nil {
		if result, found := tasks.scheduler_builtin(w.scheduler, name, args, ctx); found {
			return result
		}
	}
	values.free_var(args)
	return err_result(.E_VERBNF, "Unknown built-in function")
}
