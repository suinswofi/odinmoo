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
import "core:container/queue"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

// Intrinsic commands, in ICMD_FOR_EACH's order (which is the order the "intrinsic-commands"
// option lists them in).
Icmd :: enum {
	Program,
	Prefix,
	Suffix,
	Outputprefix,
	Outputsuffix,
}

ALL_ICMDS :: bit_set[Icmd]{.Program, .Prefix, .Suffix, .Outputprefix, .Outputsuffix}

@(private = "file")
icmd_names := [Icmd]string {
	.Program      = ".program",
	.Prefix       = "PREFIX",
	.Suffix       = "SUFFIX",
	.Outputprefix = "OUTPUTPREFIX",
	.Outputsuffix = "OUTPUTSUFFIX",
}

// icmd_index ports tasks.c's icmd_index(): `.program` matches as the verb pattern ".pr*ogram"
// does (any case, abbreviable to ".pr"); the four delimiter commands match exactly, case
// included.
icmd_index :: proc(verb: string) -> (Icmd, bool) {
	switch verb {
	case "PREFIX":
		return .Prefix, true
	case "SUFFIX":
		return .Suffix, true
	case "OUTPUTPREFIX":
		return .Outputprefix, true
	case "OUTPUTSUFFIX":
		return .Outputsuffix, true
	}
	full := ".program"
	if len(verb) >= 3 && len(verb) <= len(full) && values.strings_equal_fold(verb, full[:len(verb)]) {
		return .Program, true
	}
	return .Program, false
}

// Conn_Options is a connection's option set -- the union of the original's SERVER_CO_TABLE
// (binary), TASK_CO_TABLE (flush-command, hold-input, disable-oob, intrinsic-commands) and
// NETWORK_CO_TABLE (client-echo). Guarded by Connection.io_lock.
Conn_Options :: struct {
	binary:      bool, // stored, inert -- see CLAUDE.md
	flush_cmd:   string, // owned; "" = no flush command
	hold_input:  bool,
	disable_oob: bool,
	icmds:       bit_set[Icmd],
	client_echo: bool,
}

@(private = "file")
option_names := [?]string{"binary", "flush-command", "hold-input", "disable-oob", "intrinsic-commands", "client-echo"}

// init_option_defaults is find_tqueue()'s and new_nhandle()'s initial state. flush_cmd is
// default_flush_command(): $server_options.default_flush_command, or ".flush" -- worked out
// by the caller, which holds big_lock.
init_option_defaults :: proc(flush_cmd: string) -> Conn_Options {
	return Conn_Options{flush_cmd = strings.clone(flush_cmd), icmds = ALL_ICMDS, client_echo = true}
}

// option_value is an option's current value as a MOO value (CONNECTION_OPTION_GET). Caller
// holds io_lock.
@(private = "file")
option_value :: proc(o: ^Conn_Options, name: string) -> (values.Var, bool) {
	switch {
	case values.strings_equal_fold(name, "binary"):
		return values.int_val(o.binary ? 1 : 0), true
	case values.strings_equal_fold(name, "flush-command"):
		return values.str_val(strings.clone(o.flush_cmd)), true
	case values.strings_equal_fold(name, "hold-input"):
		return values.int_val(o.hold_input ? 1 : 0), true
	case values.strings_equal_fold(name, "disable-oob"):
		return values.int_val(o.disable_oob ? 1 : 0), true
	case values.strings_equal_fold(name, "intrinsic-commands"):
		items: [dynamic]values.Var
		for c in Icmd {
			if c in o.icmds {
				append(&items, values.str_val(strings.clone(icmd_names[c])))
			}
		}
		shrink(&items)
		return values.list_val(items[:]), true
	case values.strings_equal_fold(name, "client-echo"):
		return values.int_val(o.client_echo ? 1 : 0), true
	}
	return {}, false
}

connection_io_destroy :: proc(conn: ^Connection) {
	sync.mutex_lock(&conn.io_lock)
	tid := conn.reader_task_id
	conn.reader_task_id = 0
	delete(conn.options.flush_cmd)
	conn.options.flush_cmd = ""
	clear_pending_locked(conn)
	for queue.len(conn.oob_lines) > 0 {
		delete(queue.pop_front(&conn.oob_lines))
	}
	queue.destroy(&conn.oob_lines)
	queue.destroy(&conn.pending_lines)
	sync.mutex_unlock(&conn.io_lock)
	if tid != 0 {
		// The connection is gone while a task was parked in read() on it: it is resumed with
		// E_INVARG, as run_ready_tasks does for a reading task that is out of input.
		// the original doesn't have a clean answer for this case either (a reading_vm just
		// gets abandoned/freed on connection close).
		wake_reader_closed(conn.server.scheduler, tid)
	}
}

// on_incoming_line handles a line read directly off conn's own socket -- see header for why
// it queues rather than dispatching on the recv thread.
on_incoming_line :: proc(conn: ^Connection, line: string) {
	sync.mutex_lock(&conn.io_lock)
	conn.last_activity = time.now() // server_receive_line: what idle_seconds() and connect_timeout measure
	flush := conn.options.flush_cmd != "" && values.strings_equal_fold(line, conn.options.flush_cmd)
	oob := !conn.options.disable_oob && strings.has_prefix(line, OUT_OF_BAND_PREFIX)
	quoted := !conn.options.disable_oob && strings.has_prefix(line, OUT_OF_BAND_QUOTE_PREFIX)
	sync.mutex_unlock(&conn.io_lock)
	switch {
	case flush:
		// new_input_task: the flush command is never queued, it empties the queue.
		flush_pending(conn, true)
	case oob:
		// Out-of-band lines skip the in-band queue entirely: they go to
		// #0:do_out_of_band_command even while hold-input is set or a read() is waiting, and
		// read() never sees them (dequeue_input_task's DQ_OOB/DQ_INBAND split).
		//
		// Bounded exactly like the in-band queue (MAX_QUEUED_INPUT, in bytes and in lines): this
		// is reachable before login, and a client sending these faster than
		// do_out_of_band_command runs would otherwise grow it without limit.
		sync.mutex_lock(&conn.io_lock)
		overflow := conn.oob_bytes + len(line) > MAX_QUEUED_INPUT || queue.len(conn.oob_lines) >= MAX_QUEUED_INPUT
		if overflow {
			for queue.len(conn.oob_lines) > 0 {
				delete(queue.pop_front(&conn.oob_lines))
			}
			conn.oob_bytes = 0
		}
		queue.push_back(&conn.oob_lines, strings.clone(line))
		conn.oob_bytes += len(line)
		sync.mutex_unlock(&conn.io_lock)
		if overflow {
			send_line(conn, ">> Input buffer overflow: previous input from you has been lost <<")
		}
		spawn_drain(conn)
	case quoted:
		// OUT_OF_BAND_QUOTE_PREFIX: an in-band line that would otherwise look out-of-band.
		deliver(conn, strings.clone(line[len(OUT_OF_BAND_QUOTE_PREFIX):]), false, true)
	case:
		deliver(conn, strings.clone(line), false, true)
	}
}

// OUT_OF_BAND_PREFIX/OUT_OF_BAND_QUOTE_PREFIX are options.h's (LambdaMOO's MCP convention).
OUT_OF_BAND_PREFIX :: "#$#"
OUT_OF_BAND_QUOTE_PREFIX :: "#$\""

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
	hold := conn.options.hold_input
	if hold || from_other_thread {
		if len(line) > MAX_QUEUED_INPUT {
			// One line bigger than the whole queue's budget. The socket path cannot produce this
			// -- connection_read_loop caps a line as it is read, and says so with a distinct
			// notice -- so force_input() is the only way here; it clones an
			// arbitrary MOO string, and queueing it would leave pending_bytes permanently over
			// the cap -- every subsequent line the player typed would then flush the queue and
			// blame them for it. Drop it instead, so pending_bytes <= MAX_QUEUED_INPUT always.
			delete(line)
			sync.mutex_unlock(&conn.io_lock)
			send_line(conn, ">> Forced input line too long: discarded <<")
			return
		}
		if conn.pending_bytes + len(line) > MAX_QUEUED_INPUT || queue.len(conn.pending_lines) >= MAX_QUEUED_INPUT {
			// The queue has outrun whatever is meant to be draining it: a client typing
			// faster than its commands run, one that set "hold-input" and then kept typing,
			// or a verb in a force_input() loop. Same policy as the outbound side's
			// overflow (connection.odin's enqueue_output) and as the original's input
			// flush: drop the backlog, say so, keep the newest line. Dropping the OLDEST
			// is what makes this recoverable -- the connection stays usable and the command
			// the player just typed is the one that survives.
			clear_pending_locked(conn)
			// Safe to notify without dropping io_lock: send_line only ever reaches
			// out_lock (connection.odin's enqueue_output), and nothing anywhere takes
			// io_lock while holding out_lock, so there is no inversion to create. Keeping
			// the hold also keeps this atomic with the append below, so a line arriving
			// concurrently can't slip in between the flush and the refill.
			send_line(conn, ">> Input buffer overflow: previous input from you has been lost <<")
		}
		conn.pending_bytes += len(line)
		if at_front {
			queue.push_front(&conn.pending_lines, line)
		} else {
			queue.push_back(&conn.pending_lines, line)
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
// wake_reader_closed ends a read() whose connection has gone away: run_ready_tasks resumes a
// reading task that is out of input with E_INVARG, which read() then RAISES (an error resume
// value is raised, not returned -- see tasks.resumed_result).
wake_reader_closed :: proc(s: ^tasks.Scheduler, task_id: int) {
	args := make([]values.Var, 2)
	args[0] = values.int_val(i32(task_id))
	args[1] = values.err_val(.E_INVARG)
	rr := tasks.bf_resume(s, values.list_val(args))
	if rr.raised {
		delete(rr.msg)
		values.free_var(rr.rvalue)
	} else {
		values.free_var(rr.value)
	}
}

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
	if !tasks.spawn_worker(conn, drain_thread_proc) {
		// No drain worker means the queued lines just sit there until the next line arrives
		// and tries again -- degraded, but survivable. Leaving the counter raised is not:
		// connection teardown waits on conn.drains before it frees anything.
		sync.mutex_lock(&conn.io_lock)
		conn.drain_running = false
		sync.mutex_unlock(&conn.io_lock)
		sync.wait_group_done(&conn.drains)
	}
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
		if queue.len(conn.oob_lines) > 0 {
			oob := queue.pop_front(&conn.oob_lines)
			conn.oob_bytes -= len(oob)
			sync.mutex_unlock(&conn.io_lock)
			dispatch_oob(conn, oob)
			continue
		}
		if conn.options.hold_input || queue.len(conn.pending_lines) == 0 || conn.reader_task_id != 0 {
			conn.drain_running = false
			sync.mutex_unlock(&conn.io_lock)
			return
		}
		// A ring buffer's pop, not `copy(q[:], q[1:])` -- shifting the whole queue down per
		// line made draining N queued lines O(N^2): 400k bare newlines took 11 seconds.
		line := queue.pop_front(&conn.pending_lines)
		conn.pending_bytes -= len(line)
		sync.mutex_unlock(&conn.io_lock)
		dispatch_now(conn, line)
	}
}

@(private = "file")
try_dequeue :: proc(conn: ^Connection) -> (line: string, ok: bool) {
	sync.mutex_lock(&conn.io_lock)
	defer sync.mutex_unlock(&conn.io_lock)
	if queue.len(conn.pending_lines) == 0 {
		return "", false
	}
	line = queue.pop_front(&conn.pending_lines)
	conn.pending_bytes -= len(line)
	return line, true
}

// clear_pending_locked frees every queued line. Caller holds conn.io_lock.
@(private = "file")
clear_pending_locked :: proc(conn: ^Connection) {
	for queue.len(conn.pending_lines) > 0 {
		delete(queue.pop_front(&conn.pending_lines))
	}
	conn.pending_bytes = 0
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

// find_conn_locked looks a connection up in the registry. The caller MUST already hold
// s.players_lock, and must keep holding it for as long as it uses the returned pointer --
// that lock is the only thing standing between this pointer and the connection's own thread
// freeing it (see login.odin's "Connection lifetime" note). Every hook below is written that
// way: lock, look up, do the whole job, unlock.
//
// Not file-private: login.odin's hook_output_delimiters uses this too.
find_conn_locked :: proc(s: ^Server, player: values.Objid) -> (^Connection, bool) {
	conn, ok := s.players[player]
	return conn, ok
}

hook_try_dequeue_input :: proc(user_data: rawptr, player: values.Objid) -> (line: string, ok: bool) {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	conn, found := find_conn_locked(s, player)
	if !found {
		return "", false
	}
	return try_dequeue(conn)
}

hook_register_reader :: proc(user_data: rawptr, player: values.Objid, task_id: int) -> bool {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	conn, found := find_conn_locked(s, player)
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
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	conn, found := find_conn_locked(s, player)
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
	kick := queue.len(conn.pending_lines) > 0 && !conn.options.hold_input
	sync.mutex_unlock(&conn.io_lock)
	if kick {
		spawn_drain(conn)
	}
}

hook_force_input :: proc(user_data: rawptr, player: values.Objid, line: string, at_front: bool) -> bool {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	conn, found := find_conn_locked(s, player)
	if !found {
		return false
	}
	on_forced_line(conn, strings.clone(line), at_front)
	return true
}

hook_flush_input :: proc(user_data: rawptr, player: values.Objid, show_messages: bool) -> bool {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	conn, found := find_conn_locked(s, player)
	if !found {
		return false
	}
	flush_pending(conn, show_messages)
	return true
}

// flush_pending ports tasks.c's flush_input(): discard the queued in-band input, listing it if
// asked to.
flush_pending :: proc(conn: ^Connection, show_messages: bool) {
	sync.mutex_lock(&conn.io_lock)
	lines: [dynamic]string
	for queue.len(conn.pending_lines) > 0 {
		append(&lines, queue.pop_front(&conn.pending_lines))
	}
	conn.pending_bytes = 0
	sync.mutex_unlock(&conn.io_lock)
	defer {
		for l in lines {
			delete(l)
		}
		delete(lines)
	}
	if !show_messages {
		return
	}
	if len(lines) == 0 {
		send_line_raw(conn, ">> No pending input to flush...")
		return
	}
	send_line_raw(conn, ">> Flushing the following pending input:")
	for l in lines {
		msg := strings.concatenate({">>     ", l})
		send_line_raw(conn, msg)
		delete(msg)
	}
	send_line_raw(conn, ">> (Done flushing)")
}

// hook_set_connection_option ports the CONNECTION_OPTION_SET tables: names match in any case,
// and values are coerced the way the original coerces them -- a flag option takes the truth of
// any value, flush-command takes a non-empty string (anything else removes it), and
// intrinsic-commands takes a truth value (all or none) or a list of command names.
hook_set_connection_option :: proc(user_data: rawptr, player: values.Objid, option: string, value: values.Var) -> bool {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	conn, found := find_conn_locked(s, player)
	if !found {
		return false
	}
	sync.mutex_lock(&conn.io_lock)
	o := &conn.options
	hold_input_cleared, echo_changed := false, false
	switch {
	case values.strings_equal_fold(option, "binary"):
		o.binary = values.is_true(value)
	case values.strings_equal_fold(option, "flush-command"):
		delete(o.flush_cmd)
		o.flush_cmd = value.type == .Str ? strings.clone(value.data.str.s) : ""
	case values.strings_equal_fold(option, "hold-input"):
		o.hold_input = values.is_true(value)
		hold_input_cleared = !o.hold_input
	case values.strings_equal_fold(option, "disable-oob"):
		o.disable_oob = values.is_true(value)
	case values.strings_equal_fold(option, "intrinsic-commands"):
		flags: bit_set[Icmd]
		#partial switch value.type {
		case .Int:
			flags = values.is_true(value) ? ALL_ICMDS : {}
		case .List:
			for i in 1 ..= values.list_len(value) {
				item := values.list_get(value, i)
				if item.type != .Str {
					sync.mutex_unlock(&conn.io_lock)
					return false
				}
				c, ok := icmd_index(item.data.str.s)
				if !ok {
					sync.mutex_unlock(&conn.io_lock)
					return false
				}
				flags += {c}
			}
		case:
			sync.mutex_unlock(&conn.io_lock)
			return false
		}
		o.icmds = flags
	case values.strings_equal_fold(option, "client-echo"):
		o.client_echo = values.is_true(value)
		echo_changed = true
	case:
		sync.mutex_unlock(&conn.io_lock)
		return false
	}
	echo := o.client_echo
	sync.mutex_unlock(&conn.io_lock)

	if echo_changed {
		send_telnet_echo_negotiation(conn, echo)
	}
	if hold_input_cleared {
		spawn_drain(conn)
	}
	return true
}

hook_connection_option :: proc(user_data: rawptr, player: values.Objid, option: string) -> (value: values.Var, found: bool) {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	conn, ok := find_conn_locked(s, player)
	if !ok {
		return {}, false
	}
	sync.mutex_lock(&conn.io_lock)
	defer sync.mutex_unlock(&conn.io_lock)
	return option_value(&conn.options, option)
}

hook_connection_options :: proc(user_data: rawptr, player: values.Objid) -> (list: values.Var, found: bool) {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	conn, ok := find_conn_locked(s, player)
	if !ok {
		return {}, false
	}
	sync.mutex_lock(&conn.io_lock)
	defer sync.mutex_unlock(&conn.io_lock)
	pairs := make([]values.Var, len(option_names))
	for name, i in option_names {
		entry := make([]values.Var, 2)
		entry[0] = values.str_val(strings.clone(name))
		entry[1], _ = option_value(&conn.options, name)
		pairs[i] = values.list_val(entry)
	}
	return values.list_val(pairs), true
}
