package netio

// The real post-login command loop, ported from tasks.c's do_command_task(): parse the typed
// line (objdb.parse_command), check for an intrinsic command (`.program`/PREFIX/SUFFIX/
// OUTPUTPREFIX/OUTPUTSUFFIX -- see do_intrinsic_command()/program_editor.odin), give
// #0:do_command first refusal, then fall back to matching a verb on the player/their
// location/the parsed dobj/the parsed iobj (in that order), or location:huh, or else "I
// couldn't understand that." -- exactly what makes typed commands like `look`, `news`,
// `help`, `get sword from chest` work against the real database, instead of only raw
// MOO-expression evaluation (which was never the real interaction model; see
// connection.odin's header note on what's left of that as a `.eval` debugging escape hatch).

import "../objdb"
import "../tasks"
import "../values"
import "../vm"
import "core:strings"
import "core:sync"

// handle_intrinsic_command ports do_intrinsic_command(): checks the parsed command's verb
// against the small, fixed set of server-level (not database) commands, matching
// case-insensitively rather than the original's verbcasecmp-with-wildcard-abbreviation
// (".pr*ogram" etc.) -- a documented simplification; ".program"/"PREFIX"/etc. typed in full
// is the overwhelmingly common case. Returns true iff handled (caller does nothing further
// for this line); `.program` specifically falls through (returns false) for a non-programmer,
// exactly like the original -- PREFIX/SUFFIX have no such restriction.
@(private = "file")
handle_intrinsic_command :: proc(conn: ^Connection, ow: ^objdb.Object_World, pc: ^objdb.Parsed_Command) -> bool {
	switch {
	case strings.equal_fold(pc.verb, ".program"):
		sync.mutex_lock(&conn.server.scheduler.big_lock)
		is_programmer := objdb.is_programmer(ow.db, conn.player)
		sync.mutex_unlock(&conn.server.scheduler.big_lock)
		if !is_programmer {
			return false
		}
		if len(pc.args) != 1 {
			send_line(conn, "Usage:  .program object:verb")
		} else {
			start_programming(conn, ow, pc.args[0])
		}
		return true
	case strings.equal_fold(pc.verb, "PREFIX"), strings.equal_fold(pc.verb, "OUTPUTPREFIX"):
		delete(conn.output_prefix)
		conn.output_prefix = strings.clone(pc.argstr)
		return true
	case strings.equal_fold(pc.verb, "SUFFIX"), strings.equal_fold(pc.verb, "OUTPUTSUFFIX"):
		delete(conn.output_suffix)
		conn.output_suffix = strings.clone(pc.argstr)
		return true
	}
	return false
}

// dispatch_command parses `line` and runs the real command dispatch algorithm against
// `conn.player`. All visible output happens via the dispatched verb's own notify() calls
// (matching the original -- typed commands don't have a meaningful "return value" the client
// sees); this only speaks up directly for the "nothing matched" / uncaught-error cases.
dispatch_command :: proc(conn: ^Connection, line: string) {
	s := conn.server
	ow := (^objdb.Object_World)(s.world.user_data)

	// parse_command is a DB read like any other -- dobj/iobj matching walks the player's and
	// the room's contents chains -- so it can't run unlocked on this connection thread while
	// other tasks mutate the object graph. Locked separately from the dispatch block below
	// because handle_intrinsic_command takes the (non-reentrant) lock itself.
	sync.mutex_lock(&s.scheduler.big_lock)
	pc := objdb.parse_command(ow.db, line, conn.player)
	sync.mutex_unlock(&s.scheduler.big_lock)
	defer objdb.parsed_command_destroy(&pc)
	if !pc.ok {
		return
	}

	if handle_intrinsic_command(conn, ow, &pc) {
		return
	}

	// PREFIX/OUTPUTPREFIX and SUFFIX/OUTPUTSUFFIX bracket every ORDINARY command's output
	// (not an intrinsic command's own reply, which already returned above) -- matches
	// do_command_task() sending output_prefix before and output_suffix after everything
	// else, unconditionally, regardless of which of #0:do_command/verb-dispatch/"I couldn't
	// understand that" ends up handling the line below.
	if len(conn.output_prefix) > 0 {
		send_line(conn, conn.output_prefix)
	}
	defer {
		if len(conn.output_suffix) > 0 {
			send_line(conn, conn.output_suffix)
		}
	}

	task_id := tasks.new_task_id(s.scheduler)

	sync.mutex_lock(&s.scheduler.big_lock)
	defer sync.mutex_unlock(&s.scheduler.big_lock)

	if call_do_command_hook(ow, s.world, conn.player, line, pc.args, task_id) {
		// #0:do_command returned true -- assume it handled everything itself.
		return
	}

	location := values.NOTHING
	if objdb.valid(ow.db, conn.player) {
		location = ow.db.objects[conn.player].location
	}

	this_obj := values.NOTHING
	vh: objdb.Verb_Handle
	found := false
	for candidate in ([]values.Objid{conn.player, location, pc.dobj, pc.iobj}) {
		h := objdb.find_verb_on(ow.db, candidate, &pc)
		if h.found {
			this_obj = candidate
			vh = h
			found = true
			break
		}
	}
	if !found && objdb.valid(ow.db, location) {
		// tasks.c uses db_find_callable_verb(location, "huh"): ANY callable verb of that name,
		// its argument specs ignored. Both stock cores define $root_class:huh as `this none
		// this`, so requiring `any any any` here would silently skip $command_utils:do_huh
		// (feature objects, room :here_huh, exit-name recovery) and print the server fallback.
		h := objdb.find_callable_verb(ow.db, location, "huh")
		if h.found {
			this_obj = location
			vh = h
			found = true
		}
	}

	if !found {
		send_line(conn, "I couldn't understand that.")
		return
	}

	result := call_command_verb(ow, s.world, this_obj, &pc, conn.player, task_id, vh)
	if result.raised {
		msg := strings.concatenate({"%r** ", result.msg, " **%n"})
		defer delete(msg)
		send_line(conn, msg)
		delete(result.msg)
		values.free_var(result.rvalue)
	} else {
		values.free_var(result.value)
	}
}

// call_do_command_hook ports the #0:do_command probe in do_command_task(): a fresh root task
// (run_server_task_setting_id's generic environment -- argstr is the raw line, dobj/iobj/etc
// default to NOTHING/"", NOT the parsed pc values; do_input_task is the one that binds those,
// only for the actual matched command verb below). Returns whether it was truthy (verb
// existing and returning a true value means "handled, do nothing more"); a missing verb or
// any raised error both mean "not handled," matching run_server_task_setting_id's "simulate
// an empty verb" fallback.
@(private = "file")
call_do_command_hook :: proc(ow: ^objdb.Object_World, world: ^vm.World, player: values.Objid, line: string, words: []string, task_id: int) -> bool {
	args := words_to_owned_list(words)
	root_act := vm.Activation{
		this       = values.NOTHING,
		player     = player,
		caller     = values.NOTHING,
		programmer = values.NOTHING,
		verb_loc   = values.NOTHING,
		task_id    = task_id,
		depth      = -1,
		dobj       = values.NOTHING,
		iobj       = values.NOTHING,
		argstr     = line,
	}
	ctx := vm.Eval_Context{activation = &root_act, world = world}
	result := objdb.call_verb_from(ow, world, SYSTEM_OBJECT, SYSTEM_OBJECT, "do_command", args, &ctx)
	if result.raised {
		delete(result.msg)
		values.free_var(result.rvalue)
		return false
	}
	defer values.free_var(result.value)
	return values.is_true(result.value)
}

// call_command_verb ports do_input_task(): a fresh root task whose `this` is whichever
// candidate object find_verb_on matched on, with the parsed command's dobj/iobj/dobjstr/
// iobjstr/prepstr/argstr bound into the callee's locals (call_verb_from's `cmd` override --
// see world.odin). Root depth=-1 so the callee lands at depth=0, a true top-level command,
// not a nested call.
//
// `vh` is the Verb_Handle dispatch_command already resolved via find_verb_on -- passed
// straight through as call_verb_from's vh_hint rather than searched for again by name, since
// a second search (find_callable_verb) would wrongly require VF_EXEC on a verb that command
// dispatch never needed it on (see world.odin's call_verb_from comment). `name` stays
// pc.verb (what the player actually typed) even when `vh` is a `huh` fallback -- do_input_task
// binds RUN_ACTIV.verb/SLOT_VERB from pc->verb unconditionally, so a `huh` handler sees what
// was really typed, not the literal word "huh".
@(private = "file")
call_command_verb :: proc(ow: ^objdb.Object_World, world: ^vm.World, this_obj: values.Objid, pc: ^objdb.Parsed_Command, player: values.Objid, task_id: int, vh: objdb.Verb_Handle) -> vm.Call_Result {
	args := words_to_owned_list(pc.args)
	root_act := vm.Activation{
		this       = player,
		player     = player,
		caller     = values.NOTHING,
		programmer = values.NOTHING,
		verb_loc   = values.NOTHING,
		task_id    = task_id,
		depth      = -1,
	}
	ctx := vm.Eval_Context{activation = &root_act, world = world}
	return objdb.call_verb_from(ow, world, this_obj, this_obj, pc.verb, args, &ctx, pc, vh)
}

// words_to_owned_list builds a fresh MOO list of strings from a []string, cloning each word
// (the []string itself, and each `Parsed_Command.args` element, stays owned by its caller).
@(private = "file")
words_to_owned_list :: proc(words: []string) -> values.Var {
	items := make([]values.Var, len(words))
	for w, i in words {
		items[i] = values.str_val(strings.clone(w))
	}
	return values.list_val(items)
}
