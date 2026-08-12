package netio

// The `.program <object>:<verb-name>` intrinsic editor, ported from tasks.c's
// start_programming()/end_programming()/find_verb_for_programming(). Unlike ordinary
// command dispatch, this is a SERVER-level (not database-level) feature: once a connection
// types `.program obj:verb` successfully, every subsequent line it sends is captured
// VERBATIM (not parsed as a command, not run through notify()/ansi.translate() at all in
// either direction) until a line that is exactly "." on its own, at which point the
// accumulated lines are compiled and installed as that verb's new body -- reusing
// objdb.bf_set_verb_code directly rather than re-implementing verb installation, so this
// stays in lockstep with the same compile/install path MOO-level set_verb_code() calls use.
//
// Why lines are captured raw instead of going through send_line/ansi.translate: this is
// exactly the "verb source is being displayed/typed, not rendered as game output" case
// notify_raw() (objdb/connection_io.odin) exists for -- a verb body containing a literal
// `%r` or `|15` string constant must never be color-mangled while it's being entered or
// echoed back, since that's not what the wizard typed. Capture itself never sends anything
// back (real terminals echo locally), and the "existing source" listing before you start
// typing over it uses send_line_raw directly.

import "../objdb"
import "../tasks"
import "../values"
import "../vm"
import "core:fmt"
import "core:strings"
import "core:sync"

// program_state_destroy frees whatever `.program` state a connection was holding, called
// unconditionally from connection_handler's teardown (an abandoned `.program` session --
// the connection dropped mid-edit -- simply discards its buffer, matching the original's
// free_stream(tq->program_stream) on connection close; nothing is installed).
program_state_destroy :: proc(conn: ^Connection) {
	delete(conn.program_verb_name)
	for l in conn.program_lines {
		delete(l)
	}
	delete(conn.program_lines)
	delete(conn.output_prefix)
	delete(conn.output_suffix)
}

// handle_programming_line is handle_line's very first check (before anything else, even
// blank-line trimming -- a blank line is legitimate verb-body text): capture the line, or
// end programming on a lone ".".
handle_programming_line :: proc(conn: ^Connection, line: string) {
	if line == "." {
		finish_programming(conn)
		return
	}
	append(&conn.program_lines, strings.clone(line))
}

// start_programming ports find_verb_for_programming() + start_programming(): resolve
// "object:verb" (object is `$name` for a #0 property, `#N`, `me`/`here`, or a name matched
// against the player's own environment via objdb.match_object; verb is matched by name
// against the resolved object's OWN verbdefs only -- no inheritance walk, matching
// find_defined_verb's contract, since a verb is edited on whichever object actually defines
// it) and, on success, enters programming mode: send the confirmation message, then echo
// back the verb's current source (raw, via bf_verb_code + send_line_raw) before capture
// begins, exactly like a real `.program` session shows you what you're about to overwrite.
start_programming :: proc(conn: ^Connection, ow: ^objdb.Object_World, verbref: string) {
	colon := strings.index_byte(verbref, ':')
	if colon < 0 || colon == len(verbref) - 1 {
		send_line(conn, "You must specify a verb; use the format object:verb.")
		return
	}
	obj_part := verbref[:colon]
	verb_part := verbref[colon + 1:]

	// All of resolve_program_object/find_defined_verb/verb_allows read ow.db -- shared,
	// mutable state that other tasks (running concurrently on other threads, per this port's
	// one-thread-per-suspended/forked-task design -- see tasks/scheduler.odin's header) touch
	// only ever while holding the scheduler's big lock. This is the one DB-reading path in
	// netio that isn't itself inside a builtin call (which always arrives already holding it)
	// -- so it has to take the lock explicitly here, same as every other direct ow.db access
	// in this package (dispatch_command, login_dispatch, ...).
	sync.mutex_lock(&conn.server.scheduler.big_lock)
	oid, resolve_ok := resolve_program_object(ow, conn.player, obj_part)
	if !resolve_ok {
		sync.mutex_unlock(&conn.server.scheduler.big_lock)
		send_line(conn, program_object_error_message(oid, obj_part))
		return
	}
	h := objdb.find_defined_verb(ow.db, oid, verb_part)
	if !h.found {
		sync.mutex_unlock(&conn.server.scheduler.big_lock)
		send_line(conn, "That object does not have that verb definition.")
		return
	}
	vd := ow.db.objects[h.definer].verbdefs[h.index]
	if !objdb.verb_allows(ow.db, vd.perms, vd.owner, conn.player, .Write) {
		sync.mutex_unlock(&conn.server.scheduler.big_lock)
		send_line(conn, "Permission denied.")
		return
	}
	confirmation := fmt.tprintf(`Now programming %s (#%d):%s.  Use "." to end.`, ow.db.objects[h.definer].name, h.definer, vd.name)
	confirmation_owned := strings.clone(confirmation)
	sync.mutex_unlock(&conn.server.scheduler.big_lock)

	conn.programming = true
	conn.program_obj = h.definer
	conn.program_verb_name = strings.clone(verb_part)
	conn.program_lines = make([dynamic]string)

	send_line(conn, confirmation_owned)
	delete(confirmation_owned)

	echo_existing_source(conn, ow, h)
}

@(private = "file")
resolve_program_object :: proc(ow: ^objdb.Object_World, player: values.Objid, obj_part: string) -> (oid: values.Objid, ok: bool) {
	if len(obj_part) > 0 && obj_part[0] == '$' {
		h := objdb.find_property(ow.db, SYSTEM_OBJECT, obj_part[1:])
		if !h.found {
			return values.FAILED_MATCH, false
		}
		v := objdb.property_value(ow.db, SYSTEM_OBJECT, h)
		defer values.free_var(v)
		if v.type != .Obj || !objdb.valid(ow.db, v.data.obj) {
			return values.FAILED_MATCH, false
		}
		return v.data.obj, true
	}
	oid = objdb.match_object(ow.db, player, obj_part)
	return oid, objdb.valid(ow.db, oid)
}

@(private = "file")
program_object_error_message :: proc(oid: values.Objid, obj_part: string) -> string {
	switch oid {
	case values.FAILED_MATCH:
		return fmt.tprintf("I don't see \"%s\" here.", obj_part)
	case values.AMBIGUOUS:
		return fmt.tprintf("I don't know which \"%s\" you mean.", obj_part)
	case:
		return fmt.tprintf("\"%s\" is not a valid object.", obj_part)
	}
}

// echo_existing_source shows the verb's current body before capture begins, raw (no color
// translation) -- reuses bf_verb_code exactly like a MOO-level listing tool would, run as
// the connected player so the same read-permission check applies.
@(private = "file")
echo_existing_source :: proc(conn: ^Connection, ow: ^objdb.Object_World, h: objdb.Verb_Handle) {
	args := make([]values.Var, 2)
	args[0] = values.obj_val(h.definer)
	args[1] = values.str_val(strings.clone(conn.program_verb_name))
	act := vm.Activation{this = values.NOTHING, player = conn.player, programmer = conn.player, task_id = tasks.new_task_id(conn.server.scheduler), depth = -1}
	ctx := vm.Eval_Context{activation = &act, world = conn.server.world}

	sync.mutex_lock(&conn.server.scheduler.big_lock)
	result := objdb.bf_verb_code(ow, values.list_val(args), &ctx)
	sync.mutex_unlock(&conn.server.scheduler.big_lock)

	if result.raised {
		delete(result.msg)
		values.free_var(result.rvalue)
		return
	}
	defer values.free_var(result.value)
	n := values.list_len(result.value)
	for i in 1 ..= n {
		send_line_raw(conn, values.list_get(result.value, i).data.str.s)
	}
}

// finish_programming ports end_programming(): re-resolve the verb (it may have been
// deleted while typing), then install the accumulated body via bf_set_verb_code -- the same
// compile-and-install path set_verb_code() uses, so `.program` and MOO-level programming
// tools can never disagree about what "successfully installed" means.
@(private = "file")
finish_programming :: proc(conn: ^Connection) {
	ow := (^objdb.Object_World)(conn.server.world.user_data)
	defer {
		conn.programming = false
		delete(conn.program_verb_name)
		conn.program_verb_name = ""
		for l in conn.program_lines {
			delete(l)
		}
		delete(conn.program_lines)
		conn.program_lines = nil
	}

	act := vm.Activation{this = values.NOTHING, player = conn.player, programmer = conn.player, task_id = tasks.new_task_id(conn.server.scheduler), depth = -1}
	ctx := vm.Eval_Context{activation = &act, world = conn.server.world}

	// Held across the disappeared-object/-verb re-checks too, not just bf_set_verb_code --
	// same reasoning as start_programming's lock comment: these read ow.db directly, outside
	// any builtin call that would otherwise already hold it.
	sync.mutex_lock(&conn.server.scheduler.big_lock)
	if !objdb.valid(ow.db, conn.program_obj) {
		sync.mutex_unlock(&conn.server.scheduler.big_lock)
		send_line(conn, "That object appears to have disappeared ...")
		return
	}
	h := objdb.find_defined_verb(ow.db, conn.program_obj, conn.program_verb_name)
	if !h.found {
		sync.mutex_unlock(&conn.server.scheduler.big_lock)
		send_line(conn, "That verb appears to have disappeared ...")
		return
	}

	code_items := make([]values.Var, len(conn.program_lines))
	for l, i in conn.program_lines {
		code_items[i] = values.str_val(strings.clone(l))
	}
	args := make([]values.Var, 3)
	args[0] = values.obj_val(conn.program_obj)
	args[1] = values.str_val(strings.clone(conn.program_verb_name))
	args[2] = values.list_val(code_items)

	result := objdb.bf_set_verb_code(ow, values.list_val(args), &ctx)
	sync.mutex_unlock(&conn.server.scheduler.big_lock)

	if result.raised {
		send_line(conn, result.msg)
		delete(result.msg)
		values.free_var(result.rvalue)
		return
	}
	defer values.free_var(result.value)
	nerrs := values.list_len(result.value)
	send_line(conn, fmt.tprintf("%d error(s).", nerrs))
	if nerrs == 0 {
		send_line(conn, "Verb programmed.")
	} else {
		send_line(conn, "Verb not programmed.")
	}
}
