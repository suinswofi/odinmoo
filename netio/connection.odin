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
import "../objdb"
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

	// closing is set once, by connection_teardown, in the same players_lock hold that removes
	// this connection from Server.players; it is read under that same lock. It exists because
	// removal alone is not enough to make a connection unreachable: a drain worker that is
	// still finishing a login will REGISTER it again (finish_login's s.players[player] = conn)
	// moments later, putting a connection that is already tearing down -- and about to be
	// freed -- back into the map for every hook and for server_stop to find. That leaves a
	// dangling entry behind, and the connections still genuinely live are the ones that then
	// never get shut down, so server_stop waits on conns_done forever.
	//
	// Guarded by Server.players_lock, NOT io_lock: the invariant it protects is about the
	// registry, and it has to be tested and acted on inside the same hold that touches it.
	closing: bool,

	// Input-queue state backing read()/force_input()/flush_input()/set_connection_option()
	// (see input_queue.odin's header for the full design). Protected by io_lock throughout.
	io_lock:        sync.Mutex,
	reader_task_id: int, // 0 = no task currently parked in read() on this connection
	pending_lines:  [dynamic]string, // queued while "hold-input" is set, or awaiting a non-blocking read()
	pending_bytes:  int, // total length of pending_lines, kept incrementally so the MAX_QUEUED_INPUT check stays O(1)
	options:        map[string]values.Var, // connection-option store, see input_queue.odin's option_defaults
	drains:         sync.Wait_Group, // outstanding drain threads (input_queue.odin's spawn_drain)
	drain_running:  bool, // guards against spawning a second drain thread while one is working

	// `.program` intrinsic editor state (see program_editor.odin). Only ever touched while
	// dispatching this connection's lines -- which happens on at most one drain worker at a
	// time (input_queue.odin's drain_running), never concurrently -- so unlike the fields
	// above it needs no lock; the drain_running handoff through io_lock orders successive
	// workers' accesses.
	programming:        bool,
	program_obj:        values.Objid, // the verb's DEFINER (h.definer from find_defined_verb), not necessarily the object named in ".program obj:verb"
	program_verb_name:  string, // owned; the verb name as typed, re-resolved against program_obj when programming ends
	program_lines:      [dynamic]string, // owned strings; raw body lines accumulated so far

	// PREFIX/OUTPUTPREFIX and SUFFIX/OUTPUTSUFFIX intrinsic commands (see command.odin's
	// handle_intrinsic_command): text sent immediately before/after every ordinary command's
	// output. Empty string ("") means unset, matching the original's NULL-slot convention.
	output_prefix: string, // owned
	output_suffix: string, // owned

	// Outbound buffering. Almost every send happens from a MOO task's thread WHILE HOLDING
	// the scheduler's big_lock (notify() and friends), so a direct blocking send_tcp there
	// would let one stalled client -- full TCP window, peer stopped reading -- freeze every
	// task in the server at its next notify() to that connection. The original never has
	// this problem because its select() loop only writes to ready sockets, buffering the
	// rest (network.c's enqueue_output with MAX_QUEUED_OUTPUT). Reproduced here as: sends
	// append to out_buf (bounded the same way) and a dedicated per-connection writer thread
	// drains it to the socket, blocking only itself.
	out_lock:    sync.Mutex,
	out_cond:    sync.Cond, // signaled on new output and on out_closing
	out_buf:     [dynamic]byte,
	out_closing: bool, // writer flushes what it has and exits; enqueues become no-ops
	out_done:    sync.Wait_Group, // signaled when the writer thread has exited
}

// MAX_QUEUED_OUTPUT matches options.h's default (65536): the most outbound bytes a
// connection may have buffered before the oldest are discarded (with a notice, like the
// original's "lines of output flushed" message -- byte-counted here rather than line-
// counted, since the buffer is a flat byte stream).
@(private = "file")
MAX_QUEUED_OUTPUT :: 65536

// MAX_QUEUED_INPUT is MAX_QUEUED_OUTPUT's inbound twin, and matches the same options.h
// default (65536). It bounds two things that were previously unbounded, both of them
// reachable BEFORE a client has authenticated -- i.e. by anyone who can open a TCP
// connection, with no database object and no password:
//
//  - the partial line being accumulated in connection_read_loop: bytes with no '\n' in
//    them are just appended, so a client that never sends a newline could grow one
//    connection's buffer until the process ran out of memory.
//  - a connection's pending_lines queue (input_queue.odin): lines arrive on the recv
//    thread and are dispatched by a drain worker, so a client sending faster than its
//    commands execute -- or one that simply sets "hold-input" and then types -- grows the
//    queue without limit.
//
// The original bounds both with this same constant in one place, because its input is one
// flat per-connection buffer that pull_input() splits lazily; here the two halves are
// separate, so each is checked against it. Over-limit policy matches the original's
// (net_multi.c's "input flushed" handling) and this file's own output side: drop what is
// queued, tell the client, keep the connection alive.
MAX_QUEUED_INPUT :: 65536

// enqueue_output appends msg to conn's outbound buffer and wakes the writer thread. Never
// blocks on the network, so it's safe to call while holding big_lock (which is exactly what
// notify() does). Silently drops output once the connection is shutting down. Not
// file-private: input_queue.odin's telnet ECHO negotiation routes through it too, so those
// bytes stay ordered with ordinary output.
enqueue_output :: proc(conn: ^Connection, msg: []byte) {
	sync.mutex_lock(&conn.out_lock)
	defer sync.mutex_unlock(&conn.out_lock)
	if conn.out_closing {
		return
	}
	if len(conn.out_buf) + len(msg) > MAX_QUEUED_OUTPUT {
		// Same policy as the original's flush_pushed_output: discard the backlog the slow
		// client never read, tell them, keep the newest output flowing.
		clear(&conn.out_buf)
		notice := ">> Network buffer overflow: previous output to you has been lost <<\r\n"
		append(&conn.out_buf, ..transmute([]byte)notice)
	}
	append(&conn.out_buf, ..msg)
	sync.cond_signal(&conn.out_cond)
}

// output_writer_proc is the per-connection writer thread: waits for buffered output, swaps
// the buffer out under the lock, sends without holding any lock, repeats until out_closing
// and the buffer is drained (or the socket dies).
@(private = "file")
output_writer_proc :: proc(data: rawptr) {
	conn := (^Connection)(data)
	defer sync.wait_group_done(&conn.out_done)
	local: [dynamic]byte
	defer delete(local)

	for {
		sync.mutex_lock(&conn.out_lock)
		for len(conn.out_buf) == 0 && !conn.out_closing {
			sync.cond_wait(&conn.out_cond, &conn.out_lock)
		}
		conn.out_buf, local = local, conn.out_buf
		closing := conn.out_closing
		sync.mutex_unlock(&conn.out_lock)

		if len(local) > 0 {
			_, serr := net.send_tcp(conn.socket, local[:])
			clear(&local)
			if serr != nil {
				// Socket dead (or shutdown() from teardown unblocked us). Stop accepting
				// output and exit; the recv loop notices the death independently.
				sync.mutex_lock(&conn.out_lock)
				conn.out_closing = true
				sync.mutex_unlock(&conn.out_lock)
				return
			}
		}
		if closing {
			return
		}
	}
}

// send_line translates conn's %-code/pipe-code markup per its current ansi_enabled setting,
// then writes text + "\r\n" to the socket. Not file-private: login.odin's connection hooks
// and finish_login() also write directly to a connection's socket.
send_line :: proc(conn: ^Connection, text: string) {
	colored := ansi.translate(text, conn.ansi_enabled)
	defer delete(colored)
	msg := strings.concatenate({colored, "\r\n"})
	defer delete(msg)
	enqueue_output(conn, transmute([]byte)msg)
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
	enqueue_output(conn, transmute([]byte)msg)
}

// connection_handler owns one connection for its whole life: it runs the recv loop and then
// performs teardown, in a deliberate order spelled out inline below.
//
// The socket, ansi_enabled, options and the pre-login placeholder player id are all set up
// by accept_loop before this thread starts (see server.odin for why registration has to
// happen there), so this begins with the connection already live and reachable.
connection_handler :: proc(data: rawptr) {
	conn := (^Connection)(data)

	// Spawn the outbound writer (see enqueue_output/output_writer_proc above).
	sync.wait_group_add(&conn.out_done, 1)
	if !tasks.spawn_worker(conn, output_writer_proc) {
		// Without a writer nothing can be sent, so the connection is useless -- but it must
		// still tear down cleanly rather than block teardown on a wait group no thread will
		// ever complete. Mark the output side closed (enqueue_output then drops everything)
		// and release the count here.
		sync.mutex_lock(&conn.out_lock)
		conn.out_closing = true
		sync.mutex_unlock(&conn.out_lock)
		sync.wait_group_done(&conn.out_done)
	}

	connection_read_loop(conn)
	connection_teardown(conn)
}

// connection_teardown runs once the recv loop has ended, and the ORDER of these steps is the
// whole point -- each one is what makes the next one safe:
//
//  1. unregister_conn: after this, no other thread can obtain this ^Connection (every route
//     goes through Server.players under players_lock -- see login.odin's lifetime note), and
//     no new drain worker can be spawned, since every spawn_drain caller is map-gated too.
//     It has to come FIRST: it used to run near the end, which left a window where notify(),
//     force_input() or set_connection_option() could still find the connection in the map
//     while its option map and input queue had already been freed.
//  2. Wait for in-flight drain workers, which hold this same `conn` and are dispatching
//     queued input on it. Step 1 guarantees this set can no longer grow, so the wait
//     terminates. (Waiting on a wait group that a concurrent spawn could still add to is
//     itself a race, which the old order had.)
//  3. Free the per-connection state nothing can reach any more.
//  4. Drain and stop the writer thread, THEN close the socket. Draining after step 2 rather
//     than before it is what lets a last line produced by a drain worker actually reach the
//     client.
//  5. Signal conns_done, and only then free the Connection. conns_done is what server_stop
//     waits on before deleting the players map and letting its caller free the World, so
//     nothing may touch conn.server after it is signalled.
@(private = "file")
connection_teardown :: proc(conn: ^Connection) {
	s := conn.server

	unregister_conn(s, conn)
	sync.wait_group_wait(&conn.drains)
	connection_io_destroy(conn)
	program_state_destroy(conn)

	// Give the writer a bounded chance to flush whatever is still buffered (a "*** Booted
	// ***", a last :tell from a disconnect verb) before the socket goes away. The timeout is
	// the bound: the writer sends with a blocking socket, and a client that has stopped
	// reading but not closed can otherwise stall that send indefinitely -- which would hang
	// this thread, and with it server_stop's conns_done wait, i.e. shutdown itself.
	net.set_option(conn.socket, .Send_Timeout, 2 * time.Second)
	sync.mutex_lock(&conn.out_lock)
	conn.out_closing = true
	sync.cond_signal(&conn.out_cond)
	sync.mutex_unlock(&conn.out_lock)
	sync.wait_group_wait(&conn.out_done)
	delete(conn.out_buf)

	net.shutdown(conn.socket, .Both)
	net.close(conn.socket) // the one and only close of this descriptor -- see server_stop

	// free first, THEN announce. conns_done is what server_stop waits on before letting its
	// caller tear down the World -- and, under the test runner, the allocator this thread has
	// been using. Nothing this thread allocated may still be outstanding once it is signalled.
	free(conn)
	sync.wait_group_done(&s.conns_done)
}

@(private = "file")
connection_read_loop :: proc(conn: ^Connection) {
	// Mirrors server_new_connection() dispatching an empty command through do_login_task():
	// this is what makes $login:welcome's notify()-based banner appear, rather than netio
	// hardcoding any welcome text of its own.
	login_dispatch(conn, "")

	buf: [4096]byte
	pending := strings.builder_make()
	defer strings.builder_destroy(&pending)
	// Set once the current line has outgrown MAX_QUEUED_INPUT: the rest of it is consumed
	// and discarded (rather than buffered) until its terminating newline arrives, so the
	// connection resynchronizes on the next line instead of being dropped mid-stream.
	overlong := false

	for {
		n, err := net.recv_tcp(conn.socket, buf[:])
		if err != nil || n == 0 {
			return
		}
		for i in 0 ..< n {
			c := buf[i]
			if c == '\n' {
				if overlong {
					send_line(conn, ">> Line too long: input discarded <<")
					overlong = false
					strings.builder_reset(&pending)
					free_all(context.temp_allocator)
					continue
				}
				line := strings.trim_right(strings.to_string(pending), "\r")
				on_incoming_line(conn, line)
				strings.builder_reset(&pending)
				// One completed line of input = one finished task, which is the natural point
				// to reclaim scratch memory. context.temp_allocator is a GROWING arena that is
				// never reclaimed on its own, and it's per-thread, so a connection thread that
				// never resets it would grow for as long as the connection lives -- months, for
				// a MOO. Nothing temp-allocated outlives a single dispatched line (verb code
				// works in owned Vars, and the compiler clones every string it keeps), so this
				// is safe here and belongs at exactly this boundary.
				free_all(context.temp_allocator)
			} else if !overlong {
				strings.write_byte(&pending, c)
				if strings.builder_len(pending) > MAX_QUEUED_INPUT {
					overlong = true
					strings.builder_reset(&pending)
				}
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

	// is_player_object reads db.objects (validity + the User flag) -- that's a DB access
	// like any other, and a forked task from another connection's login can be mutating the
	// object map concurrently, so it needs the lock exactly as the verb call above did.
	sync.mutex_lock(&s.scheduler.big_lock)
	is_player := result.value.type == .Obj && is_player_object(s.world, result.value.data.obj)
	sync.mutex_unlock(&s.scheduler.big_lock)
	if is_player {
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
//
// It is gated on the programmer bit, and that gate is not decorative. Being able to run an
// arbitrary MOO expression is precisely what the programmer bit grants: the in-database `;`
// command checks it ($prog:eval, and the eval() built-in checks it again in bf_eval), so an
// ungated `.eval` handed every connected player -- including one the database has
// deliberately not trusted with code -- a way around a decision the database had already
// made. Wizards pass by virtue of the usual wizard-implies-programmer rule.
@(private = "file")
eval_expr :: proc(conn: ^Connection, trimmed: string) {
	s := conn.server
	ow := (^objdb.Object_World)(s.world.user_data)
	// Reading an object's flags is a database read like any other, so it takes big_lock --
	// another task may be setting that very bit (see CLAUDE.md's locking rule).
	sync.mutex_lock(&s.scheduler.big_lock)
	allowed := objdb.is_programmer(ow.db, conn.player) || objdb.is_wizard(ow.db, conn.player)
	sync.mutex_unlock(&s.scheduler.big_lock)
	if !allowed {
		send_line(conn, "%r** Permission denied **%n")
		return
	}

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
