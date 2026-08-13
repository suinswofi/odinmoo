#+feature dynamic-literals
package netio

// Backs read()/force_input()/flush_input()/set_connection_option()/connection_option(s)()
// (objdb/connection_io.odin), ported in spirit (not line-for-line) from tasks.c's tqueue
// machinery (enqueue_input_task/dequeue_input_task/hold_input) and net_multi.c/server.c's
// CONNECTION_OPTION tables.
//
// Design: every connection has a small input queue (`pending_lines`) and an optional
// "reader" task id. A line arriving for a connection -- whether typed on the real socket
// (on_incoming_line) or injected via force_input() (on_forced_line) -- goes through one path
// (deliver): if a task is parked in read() on this connection, wake it directly with the line
// (no dispatch); else if "hold-input" is set, queue it; else dispatch it as an ordinary
// command/login line.
//
// NOTHING dispatches MOO code on a connection's recv thread -- every line, socket-typed or
// force_input()'d, either wakes a parked reader directly or goes through the queue and a
// drain worker thread (spawn_drain, mirroring tasks/fork.odin's do_fork), exactly like the
// original's "just enqueue it, the scheduler picks it up later" model. Two reasons, both
// load-bearing:
//
//  - on_forced_line runs on a MOO task's own thread, which already holds the scheduler's
//    (non-reentrant) big lock: dispatching synchronously would self-deadlock.
//  - on_incoming_line runs on the recv thread, and dispatching there means a command (or a
//    `;`-eval) that calls read()/suspend() parks the ONE thread that receives this
//    connection's input: read(player) from your own connection would deadlock until the
//    connection died. The original never had the problem because its network loop and task
//    execution were always decoupled; queue-plus-drain is that same decoupling here.
//
// The drain worker processes queued lines strictly in order, one at a time, and stands down
// while a reader is parked (the reader consumes the queue itself via try_dequeue) or while
// hold-input is set.

import "../tasks"
import "../values"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"

@(private = "file")
option_types := map[string]values.Var_Type {
	"binary"             = .Int,
	"hold-input"         = .Int,
	"disable-oob"        = .Int,
	"intrinsic-commands" = .List,
	"flush-command"      = .Str,
	"client-echo"        = .Int,
}

init_option_defaults :: proc() -> map[string]values.Var {
	m := make(map[string]values.Var)
	m["binary"] = values.int_val(0)
	m["hold-input"] = values.int_val(0)
	m["disable-oob"] = values.int_val(0)
	m["intrinsic-commands"] = values.empty_list()
	m["flush-command"] = values.str_val(strings.clone(""))
	m["client-echo"] = values.int_val(1)
	return m
}

connection_io_destroy :: proc(conn: ^Connection) {
	sync.mutex_lock(&conn.io_lock)
	tid := conn.reader_task_id
	conn.reader_task_id = 0
	for _, v in conn.options {
		values.free_var(v)
	}
	delete(conn.options)
	for line in conn.pending_lines {
		delete(line)
	}
	delete(conn.pending_lines)
	sync.mutex_unlock(&conn.io_lock)
	if tid != 0 {
		// The connection is gone while a task was parked in read() on it -- wake it with an
		// empty string rather than leaving it blocked forever. A real, if degraded, default:
		// the original doesn't have a clean answer for this case either (a reading_vm just
		// gets abandoned/freed on connection close).
		wake_reader(conn.server.scheduler, tid, strings.clone(""))
	}
}

// on_incoming_line handles a line read directly off conn's own socket -- see header for why
// it queues rather than dispatching on the recv thread.
on_incoming_line :: proc(conn: ^Connection, line: string) {
	deliver(conn, strings.clone(line), false, true)
}

// on_forced_line handles a force_input()'d line -- see header for why it must never
// synchronously dispatch.
on_forced_line :: proc(conn: ^Connection, line: string, at_front: bool) {
	deliver(conn, line, at_front, true)
}

@(private = "file")
deliver :: proc(conn: ^Connection, line: string, at_front: bool, from_other_thread: bool) {
	sync.mutex_lock(&conn.io_lock)
	for conn.reader_task_id != 0 {
		tid := conn.reader_task_id
		conn.reader_task_id = 0
		sync.mutex_unlock(&conn.io_lock)
		if wake_reader(conn.server.scheduler, tid, strings.clone(line)) {
			delete(line)
			return
		}
		// The parked read() was already gone -- timed out or kill_task()'d in the moment
		// between our claim above and the resume attempt (bf_suspend unregisters
		// atomically with committing to that outcome, so the resume cleanly failed
		// rather than writing into a task that would never look). We still hold the
		// line; re-take the lock and deliver it the ordinary way. The loop re-checks
		// reader_task_id because a NEW read() may legitimately have parked meanwhile.
		sync.mutex_lock(&conn.io_lock)
	}
	hold := values.is_true(conn.options["hold-input"])
	if hold || from_other_thread {
		if at_front {
			old := conn.pending_lines
			new_lines: [dynamic]string
			append(&new_lines, line)
			for l in old {
				append(&new_lines, l)
			}
			delete(old)
			conn.pending_lines = new_lines
		} else {
			append(&conn.pending_lines, line)
		}
		sync.mutex_unlock(&conn.io_lock)
		if from_other_thread && !hold {
			spawn_drain(conn)
		}
		return
	}
	sync.mutex_unlock(&conn.io_lock)
	dispatch_now(conn, line)
}

// Not file-private: server.odin's server_stop() calls this too -- see its own comment on why
// a parked reader can't be woken just by closing its connection's socket. Takes ownership
// of `line` either way (bf_resume consumes its args even on failure); returns whether the
// task actually received it, so deliver() can fall back with its own copy instead of
// letting the line vanish when the reader died racing the delivery.
wake_reader :: proc(s: ^tasks.Scheduler, task_id: int, line: string) -> (delivered: bool) {
	args := make([]values.Var, 2)
	args[0] = values.int_val(i32(task_id))
	args[1] = values.str_val(line)
	rr := tasks.bf_resume(s, values.list_val(args))
	if rr.raised {
		delete(rr.msg)
		values.free_var(rr.rvalue)
		return false
	}
	values.free_var(rr.value)
	return true
}

@(private = "file")
dispatch_now :: proc(conn: ^Connection, line: string) {
	defer delete(line)
	if conn.player < 0 {
		login_dispatch(conn, line)
	} else {
		handle_line(conn, line)
	}
}

// spawn_drain starts a thread to dispatch whatever is queued, if one isn't already working.
// Registering with conn.drains is what lets connection teardown wait for it rather than
// pulling `conn` out from under it (see connection_handler's defer); `drain_running` keeps a
// burst of force_input() calls from spawning a thread per line, since one drain loop already
// picks up everything queued.
@(private = "file")
spawn_drain :: proc(conn: ^Connection) {
	sync.mutex_lock(&conn.io_lock)
	already := conn.drain_running
	if !already {
		conn.drain_running = true
	}
	sync.mutex_unlock(&conn.io_lock)
	if already {
		return
	}
	sync.wait_group_add(&conn.drains, 1)
	thread.create_and_start_with_data(conn, drain_thread_proc, init_context = context, self_cleanup = true)
}

@(private = "file")
drain_thread_proc :: proc(data: rawptr) {
	conn := (^Connection)(data)
	defer sync.wait_group_done(&conn.drains)
	// Per-thread scratch arena, only ever reclaimed explicitly -- see the reset in
	// connection.odin's read loop for the full reasoning.
	defer free_all(context.temp_allocator)
	for {
		sync.mutex_lock(&conn.io_lock)
		if values.is_true(conn.options["hold-input"]) || len(conn.pending_lines) == 0 || conn.reader_task_id != 0 {
			conn.drain_running = false
			sync.mutex_unlock(&conn.io_lock)
			return
		}
		line := conn.pending_lines[0]
		copy(conn.pending_lines[:], conn.pending_lines[1:])
		resize(&conn.pending_lines, len(conn.pending_lines) - 1)
		sync.mutex_unlock(&conn.io_lock)
		dispatch_now(conn, line)
	}
}

@(private = "file")
try_dequeue :: proc(conn: ^Connection) -> (line: string, ok: bool) {
	sync.mutex_lock(&conn.io_lock)
	defer sync.mutex_unlock(&conn.io_lock)
	if len(conn.pending_lines) == 0 {
		return "", false
	}
	line = conn.pending_lines[0]
	copy(conn.pending_lines[:], conn.pending_lines[1:])
	resize(&conn.pending_lines, len(conn.pending_lines) - 1)
	return line, true
}

@(private = "file")
send_telnet_echo_negotiation :: proc(conn: ^Connection, echo_on: bool) {
	IAC :: 255
	WILL :: 251
	WONT :: 252
	ECHO :: 1
	cmd: [3]byte
	cmd[0] = IAC
	cmd[1] = WONT if echo_on else WILL
	cmd[2] = ECHO
	enqueue_output(conn, cmd[:])
}

// ---- Connection_Hooks implementations (wired in login.odin's wire_connection_hooks) ----

// Not file-private: login.odin's hook_output_delimiters uses this too.
find_conn :: proc(s: ^Server, player: values.Objid) -> (^Connection, bool) {
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	conn, ok := s.players[player]
	return conn, ok
}

hook_try_dequeue_input :: proc(user_data: rawptr, player: values.Objid) -> (line: string, ok: bool) {
	s := (^Server)(user_data)
	conn, found := find_conn(s, player)
	if !found {
		return "", false
	}
	return try_dequeue(conn)
}

hook_register_reader :: proc(user_data: rawptr, player: values.Objid, task_id: int) -> bool {
	s := (^Server)(user_data)
	conn, found := find_conn(s, player)
	if !found {
		return false
	}
	sync.mutex_lock(&conn.io_lock)
	conn.reader_task_id = task_id
	sync.mutex_unlock(&conn.io_lock)
	return true
}

hook_unregister_reader :: proc(user_data: rawptr, player: values.Objid, task_id: int) {
	s := (^Server)(user_data)
	conn, found := find_conn(s, player)
	if !found {
		return
	}
	sync.mutex_lock(&conn.io_lock)
	if conn.reader_task_id == task_id {
		conn.reader_task_id = 0
	}
	// The drain worker stands down while a reader is parked; if lines queued up in the
	// meantime (or the read consumed only some of them), restart it now that the reader is
	// gone, or they'd sit until the next line happened to arrive.
	kick := len(conn.pending_lines) > 0 && !values.is_true(conn.options["hold-input"])
	sync.mutex_unlock(&conn.io_lock)
	if kick {
		spawn_drain(conn)
	}
}

hook_force_input :: proc(user_data: rawptr, player: values.Objid, line: string, at_front: bool) -> bool {
	s := (^Server)(user_data)
	conn, found := find_conn(s, player)
	if !found {
		return false
	}
	on_forced_line(conn, strings.clone(line), at_front)
	return true
}

hook_flush_input :: proc(user_data: rawptr, player: values.Objid, show_messages: bool) -> bool {
	s := (^Server)(user_data)
	conn, found := find_conn(s, player)
	if !found {
		return false
	}
	sync.mutex_lock(&conn.io_lock)
	for l in conn.pending_lines {
		delete(l)
	}
	clear(&conn.pending_lines)
	sync.mutex_unlock(&conn.io_lock)
	if show_messages {
		send_line(conn, "*** Flushed ***")
	}
	return true
}

hook_set_connection_option :: proc(user_data: rawptr, player: values.Objid, option: string, value: values.Var) -> bool {
	s := (^Server)(user_data)
	conn, found := find_conn(s, player)
	if !found {
		return false
	}
	want_type, known := option_types[option]
	if !known || value.type != want_type {
		return false
	}
	sync.mutex_lock(&conn.io_lock)
	if old, ok := conn.options[option]; ok {
		values.free_var(old)
	}
	conn.options[option] = values.var_ref(value)
	hold_input_cleared := option == "hold-input" && !values.is_true(value)
	sync.mutex_unlock(&conn.io_lock)

	if option == "client-echo" {
		send_telnet_echo_negotiation(conn, values.is_true(value))
	}
	if hold_input_cleared {
		spawn_drain(conn)
	}
	return true
}

hook_connection_option :: proc(user_data: rawptr, player: values.Objid, option: string) -> (value: values.Var, found: bool) {
	s := (^Server)(user_data)
	conn, ok := find_conn(s, player)
	if !ok {
		return {}, false
	}
	sync.mutex_lock(&conn.io_lock)
	defer sync.mutex_unlock(&conn.io_lock)
	v, exists := conn.options[option]
	if !exists {
		return {}, false
	}
	return values.var_ref(v), true
}

hook_connection_options :: proc(user_data: rawptr, player: values.Objid) -> (list: values.Var, found: bool) {
	s := (^Server)(user_data)
	conn, ok := find_conn(s, player)
	if !ok {
		return {}, false
	}
	sync.mutex_lock(&conn.io_lock)
	defer sync.mutex_unlock(&conn.io_lock)
	pairs := make([]values.Var, len(conn.options))
	i := 0
	for name, v in conn.options {
		entry := make([]values.Var, 2)
		entry[0] = values.str_val(strings.clone(name))
		entry[1] = values.var_ref(v)
		pairs[i] = values.list_val(entry)
		i += 1
	}
	return values.list_val(pairs), true
}
