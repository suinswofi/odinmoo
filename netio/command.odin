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
import "../values"
import "core:strings"
import "core:sync"

// handle_intrinsic_command ports do_intrinsic_command(): the parsed verb is checked against
// the server's own commands -- `.program` (matched like the verb name ".pr*ogram") and the
// exact-case PREFIX/SUFFIX/OUTPUTPREFIX/OUTPUTSUFFIX -- each only if the connection's
// "intrinsic-commands" option still enables it. Returns true iff handled. `.program` falls
// through for a non-programmer, exactly like the original.
@(private = "file")
handle_intrinsic_command :: proc(conn: ^Connection, ow: ^objdb.Object_World, pc: ^objdb.Parsed_Command) -> bool {
	icmd, ok := icmd_index(pc.verb)
	if !ok {
		return false
	}
	sync.mutex_lock(&conn.io_lock)
	enabled := icmd in conn.options.icmds
	sync.mutex_unlock(&conn.io_lock)
	if !enabled {
		return false
	}
	switch icmd {
	case .Program:
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
	case .Prefix, .Outputprefix:
		set_output_delimiter(conn, &conn.output_prefix, pc.argstr)
	case .Suffix, .Outputsuffix:
		set_output_delimiter(conn, &conn.output_suffix, pc.argstr)
	}
	return true
}

// dispatch_command ports do_command_task(): parse the line; an intrinsic command is handled
// here; otherwise, bracketed by the PREFIX/SUFFIX lines, #0:do_command(@words) gets first
// refusal (it runs as a server task with argstr = the whole line, and a true result -- or the
// task not completing -- means it handled the line), then the parsed verb is looked for on
// the player, their location, the direct object and the indirect object, then `huh` on the
// location, and failing all of those the player is told "I couldn't understand that.". The
// matched verb runs as a new task (do_input_task); an error it doesn't catch is reported the
// way every task's is (objdb.task_aborted: #0:handle_uncaught_error, or a traceback).
dispatch_command :: proc(conn: ^Connection, line: string) {
	s := conn.server
	ow := (^objdb.Object_World)(s.world.user_data)

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

	// Snapshot both under io_lock rather than reading conn.output_prefix/suffix directly at
	// each use: output_delimiters() reads them from another thread (login.odin's
	// hook_output_delimiters) and a PREFIX command frees the old string as it installs a new
	// one, so the value has to be copied out under the lock that orders those two.
	prefix, suffix := output_delimiters_snapshot(conn)
	defer delete(prefix)
	defer delete(suffix)
	if len(prefix) > 0 {
		send_line(conn, prefix)
	}
	defer {
		if len(suffix) > 0 {
			send_line(conn, suffix)
		}
	}

	sync.mutex_lock(&s.scheduler.big_lock)
	defer sync.mutex_unlock(&s.scheduler.big_lock)

	handled, outcome := objdb.run_root_verb(ow, s.world, objdb.Root_Call{
		player = conn.player, this = SYSTEM_OBJECT, verb = "do_command",
		args = words_to_list(split_command_words(line)), argstr = line,
	})
	is_handled := outcome != .Done || values.is_true(handled)
	values.free_var(handled)
	if is_handled {
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

	// do_input_task: `verb` is what was typed (even for a `huh` fallback), `caller` is the
	// player, and the parsed command's dobj/iobj/...str are bound.
	result, _ := objdb.run_root_verb(ow, s.world, objdb.Root_Call{
		player = conn.player, this = this_obj, verb = pc.verb, args = words_to_owned_list(pc.args),
		argstr = pc.argstr, cmd = &pc, vh = vh,
	})
	values.free_var(result)
}

// dispatch_oob ports do_out_of_band_command(): #0:do_out_of_band_command(@words), argstr =
// the line, as a server task for this connection's player (logged in or not). Not
// file-private: input_queue.odin's drain worker calls it. Consumes `line`.
dispatch_oob :: proc(conn: ^Connection, line: string) {
	defer delete(line)
	s := conn.server
	sync.mutex_lock(&s.scheduler.big_lock)
	v, _ := objdb.run_root_verb(world_of(s), s.world, objdb.Root_Call{
		player = conn.player, this = SYSTEM_OBJECT, verb = "do_out_of_band_command",
		args = words_to_list(split_command_words(line)), argstr = line,
	})
	sync.mutex_unlock(&s.scheduler.big_lock)
	values.free_var(v)
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

// set_output_delimiter installs a new PREFIX/SUFFIX string, freeing the one it replaces,
// under io_lock -- see output_delimiters_snapshot.
@(private = "file")
set_output_delimiter :: proc(conn: ^Connection, slot: ^string, text: string) {
	replacement := strings.clone(text)
	sync.mutex_lock(&conn.io_lock)
	old := slot^
	slot^ = replacement
	sync.mutex_unlock(&conn.io_lock)
	delete(old)
}

// output_delimiters_snapshot returns owned copies of this connection's PREFIX and SUFFIX.
// These two strings are the one piece of per-connection state that is both written by the
// connection's own drain worker (a PREFIX/SUFFIX command) and read by arbitrary MOO tasks on
// other threads (the output_delimiters() builtin), so unlike the rest of the `.program`/
// prefix block in Connection they need a lock; io_lock is the connection's existing one.
@(private = "file")
output_delimiters_snapshot :: proc(conn: ^Connection) -> (prefix: string, suffix: string) {
	sync.mutex_lock(&conn.io_lock)
	defer sync.mutex_unlock(&conn.io_lock)
	return strings.clone(conn.output_prefix), strings.clone(conn.output_suffix)
}
