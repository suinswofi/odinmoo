package netio

// Per-connection handler: reads bytes, splits into lines (tolerating both "\r\n" and bare
// "\n", matching net_multi.c's pull_input()), and -- once logged in -- runs each line through
// the real command dispatch loop (command.odin's dispatch_command, porting
// tasks.c's do_command_task()/parse_command()/match_object()/find_verb_on()): `look`,
// `news`, `help`, `get sword from chest`, and so on are matched against real verbs on the
// player/their location/the objects they named, exactly like the original. `.ansi on/off`
// and `.eval <expr>` (raw MOO-expression evaluation, for debugging) are netio's own
// `.`-prefixed local commands, never sent to the database as typed input.
//
// Every line sent back to the client passes through ansi.translate() (Phase 9): MOO strings
// may contain %-code color markup (see ansi/ansi.odin), which becomes real ANSI escapes
// here if the connection has color enabled (the default -- telnet/nc/any real terminal
// handles SGR escapes fine) or is stripped to plain text if the client asked for it off via
// `.ansi off`, degrading gracefully rather than spraying escape codes at a client that
// doesn't want them.
//
// Each server-to-client message is exactly one line (matching the netio wire protocol
// throughout): where a message mixes a fixed color-coded prefix with dynamic content (an
// error message, a parsed value), the prefix's %-codes and the dynamic text share one
// translate() call. This means a literal '%' in dynamic content immediately followed by a
// recognized code letter (e.g. a raise()'d message containing "...10%red...") would be
// misread as markup -- the same escaping tradeoff (`%%` for a literal percent) that every
// %-code MU* convention this is modeled on makes; not treated as a bug to design around.

import "../ansi"
import "../builtins"
import "../compiler"
import "../dbfile"
import "../tasks"
import "../values"
import "../vm"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

Connection :: struct {
	socket:       net.TCP_Socket,
	server:       ^Server,
	ansi_enabled: bool,
	player:       values.Objid, // a negative placeholder ID until do_login_command() returns a valid player (id >= 0)
	connect_time: time.Time, // set by finish_login(); zero until then -- backs connected_seconds()

	// Input-queue state backing read()/force_input()/flush_input()/set_connection_option()
	// (see input_queue.odin's header for the full design). Protected by io_lock throughout.
	io_lock:        sync.Mutex,
	reader_task_id: int, // 0 = no task currently parked in read() on this connection
	pending_lines:  [dynamic]string, // queued while "hold-input" is set, or awaiting a non-blocking read()
	options:        map[string]values.Var, // connection-option store, see input_queue.odin's option_defaults

	// `.program` intrinsic editor state (see program_editor.odin). Only ever touched by this
	// connection's own recv-loop thread, so unlike the fields above it needs no lock.
	programming:        bool,
	program_obj:        values.Objid, // the verb's DEFINER (h.definer from find_defined_verb), not necessarily the object named in ".program obj:verb"
	program_verb_name:  string, // owned; the verb name as typed, re-resolved against program_obj when programming ends
	program_lines:      [dynamic]string, // owned strings; raw body lines accumulated so far

	// PREFIX/OUTPUTPREFIX and SUFFIX/OUTPUTSUFFIX intrinsic commands (see command.odin's
	// handle_intrinsic_command): text sent immediately before/after every ordinary command's
	// output. Empty string ("") means unset, matching the original's NULL-slot convention.
	output_prefix: string, // owned
	output_suffix: string, // owned
}

// send_line translates conn's %-code/pipe-code markup per its current ansi_enabled setting,
// then writes text + "\r\n" to the socket. Not file-private: login.odin's connection hooks
// and finish_login() also write directly to a connection's socket.
send_line :: proc(conn: ^Connection, text: string) {
	colored := ansi.translate(text, conn.ansi_enabled)
	defer delete(colored)
	msg := strings.concatenate({colored, "\r\n"})
	defer delete(msg)
	net.send_tcp(conn.socket, transmute([]byte)msg)
}

// send_line_raw writes text + "\r\n" straight to the socket with NO color translation at
// all -- for displaying text that must be shown byte-for-byte as typed, like a verb's
// source or a property's raw value while it's being reviewed/edited, where a `%r` or `|15`
// occurring as ordinary characters inside the text must not be silently eaten and replaced
// with a color escape (see notify_raw()'s header in objdb/connection_io.odin for the full
// story). Not file-private: also used directly by the `.program` intrinsic editor to echo
// back existing verb source before editing.
send_line_raw :: proc(conn: ^Connection, text: string) {
	msg := strings.concatenate({text, "\r\n"})
	defer delete(msg)
	net.send_tcp(conn.socket, transmute([]byte)msg)
}

connection_handler :: proc(data: rawptr) {
	conn := (^Connection)(data)
	defer free(conn)
	defer net.close(conn.socket)
	defer unregister_player(conn.server, conn.player)
	defer sync.wait_group_done(&conn.server.conns_done)
	defer connection_io_destroy(conn)
	defer program_state_destroy(conn)
	conn.ansi_enabled = true
	conn.options = init_option_defaults()
	conn.player = allocate_connection_id(conn.server, conn)

	// Mirrors server_new_connection() dispatching an empty command through do_login_task():
	// this is what makes $login:welcome's notify()-based banner appear, rather than netio
	// hardcoding any welcome text of its own.
	login_dispatch(conn, "")

	buf: [4096]byte
	pending := strings.builder_make()
	defer strings.builder_destroy(&pending)

	for {
		n, err := net.recv_tcp(conn.socket, buf[:])
		if err != nil || n == 0 {
			return
		}
		for i in 0 ..< n {
			c := buf[i]
			if c == '\n' {
				line := strings.trim_right(strings.to_string(pending), "\r")
				on_incoming_line(conn, line)
				strings.builder_reset(&pending)
			} else {
				strings.write_byte(&pending, c)
			}
		}
	}
}

// login_dispatch ports do_login_task(): word-split the line, call #0:do_login_command(words)
// as a fresh root task, and -- if it returns a valid player object -- complete the login via
// finish_login(). Any other return (an error, an int, an invalid object) just means "stay in
// login mode," exactly like the original: do_login_command is expected to notify() its own
// prompts/errors, not netio.
//
// Not file-private: input_queue.odin's dispatch_now() calls this too, for a queued/forced
// line arriving on a still-logging-in connection.
login_dispatch :: proc(conn: ^Connection, line: string) {
	s := conn.server
	words := split_command_words(line)
	args := words_to_list(words)
	task_id := tasks.new_task_id(s.scheduler)

	sync.mutex_lock(&s.scheduler.big_lock)
	result := call_root_verb(s.world, SYSTEM_OBJECT, "do_login_command", args, conn.player, task_id)
	sync.mutex_unlock(&s.scheduler.big_lock)

	if result.raised {
		// "simulate an empty verb" (run_server_task_setting_id's fallback when the verb is
		// missing) or any other uncaught error -- either way, not a login, stay in login mode.
		delete(result.msg)
		values.free_var(result.rvalue)
		return
	}
	defer values.free_var(result.value)

	if result.value.type == .Obj && is_player_object(s.world, result.value.data.obj) {
		finish_login(s, conn, result.value.data.obj)
	}
}

// Not file-private: input_queue.odin's dispatch_now() calls this too.
handle_line :: proc(conn: ^Connection, line: string) {
	if conn.programming {
		// Checked before ANYTHING else, including the blank-line discard below: a blank
		// line is legitimate verb-body text while `.program`-ing, not "nothing to do."
		handle_programming_line(conn, line)
		return
	}

	trimmed := strings.trim_space(line)
	if len(trimmed) == 0 {
		return
	}

	switch trimmed {
	case ".ansi off":
		conn.ansi_enabled = false
		send_line(conn, "ANSI color disabled.")
		return
	case ".ansi on":
		conn.ansi_enabled = true
		send_line(conn, "%h%gANSI color enabled.%n")
		return
	}
	if strings.has_prefix(trimmed, ".eval ") {
		eval_expr(conn, trimmed[len(".eval "):])
		return
	}

	dispatch_command(conn, line)
}

// eval_expr is netio's own debugging escape hatch (`.eval <expr>`): evaluates `expr` as a
// raw MOO expression and prints its value, bypassing command dispatch entirely. Not a real
// MOO feature -- `player`/`caller`/`programmer` are bound to the connected player (so
// permission checks and `player`-referencing code behave sensibly), but there's no `this`/
// `dobj`/`iobj`/`args` command context -- ordinary play goes through dispatch_command in
// command.odin.
@(private = "file")
eval_expr :: proc(conn: ^Connection, trimmed: string) {
	src := strings.concatenate({"return (", trimmed, ");"})
	defer delete(src)
	r := compiler.parse_program(src, dbfile.Current_DB_Version)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		for e in r.errors {
			delete(e)
		}
		delete(r.errors)
	}
	if len(r.errors) > 0 {
		msg := strings.concatenate({"%rParse error: %n", r.errors[0]})
		defer delete(msg)
		send_line(conn, msg)
		return
	}

	act := vm.activation_make(len(r.names.names), &r.names)
	defer vm.activation_destroy(&act)
	act.task_id = tasks.new_task_id(conn.server.scheduler)
	act.debug = true
	// Impersonate the connected player's own permissions -- without this, `programmer`
	// defaults to #0 (the System Object, not a programmer in stock LambdaCore), so anything
	// permission-checked (eval(), $-property writes, etc.) would spuriously E_PERM even for a
	// logged-in wizard using this debug escape hatch.
	act.player = conn.player
	act.programmer = conn.player
	act.caller = conn.player
	if slot := compiler.find(&r.names, "player"); slot >= 0 {
		act.locals[slot] = values.obj_val(conn.player)
	}
	if slot := compiler.find(&r.names, "caller"); slot >= 0 {
		act.locals[slot] = values.obj_val(conn.player)
	}
	if slot := compiler.find(&r.names, "this"); slot >= 0 {
		act.locals[slot] = values.obj_val(values.NOTHING)
	}

	sync.mutex_lock(&conn.server.scheduler.big_lock)
	result := vm.run(r.body, &r.names, conn.server.world, &act)
	sync.mutex_unlock(&conn.server.scheduler.big_lock)

	switch result.signal {
	case .Return:
		defer values.free_var(result.value)
		lit_args := make([]values.Var, 1)
		lit_args[0] = values.var_ref(result.value)
		lit_result, _ := builtins.call("toliteral", values.list_val(lit_args))
		defer values.free_var(lit_result.value)
		send_line(conn, lit_result.value.data.str.s)
	case .Raised:
		msg := strings.concatenate({"%r** Error: %n", compiler.error_name(result.err.code), " (", result.err.msg, ")"})
		defer delete(msg)
		send_line(conn, msg)
		delete(result.err.msg)
		values.free_var(result.err.value)
	case .Normal, .Break, .Continue:
		send_line(conn, "(no value)")
	}
}
