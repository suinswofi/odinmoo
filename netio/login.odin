package netio

// The real login protocol, ported from tasks.c's do_login_task() and parse_cmd.c's
// parse_into_words(), plus the Connection_Hooks (objdb/world.odin) that let
// notify()/connection_name()/boot_player() reach an actual socket.

import "../objdb"
import "../tasks"
import "../values"
import "../vm"
import "core:fmt"
import "core:net"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

// SYSTEM_OBJECT is #0, matching structures.h's SYSTEM_OBJECT -- do_login_command lives there.
SYSTEM_OBJECT :: values.Objid(0)

// split_command_words ports parse_into_words() exactly: leading/trailing spaces trimmed,
// words split on unquoted spaces, `"` toggles a quoted region (consumed, not included in
// the output), `\` escapes the next character literally (including a space or quote).
split_command_words :: proc(s: string) -> []string {
	words: [dynamic]string
	i := 0
	n := len(s)
	for i < n && s[i] == ' ' {
		i += 1
	}
	for i < n {
		b := strings.builder_make()
		in_quotes := false
		for i < n && (in_quotes || s[i] != ' ') {
			c := s[i]
			switch c {
			case '"':
				in_quotes = !in_quotes
				i += 1
			case '\\':
				i += 1
				if i < n {
					strings.write_byte(&b, s[i])
					i += 1
				}
			case:
				strings.write_byte(&b, c)
				i += 1
			}
		}
		append(&words, strings.to_string(b))
		for i < n && s[i] == ' ' {
			i += 1
		}
	}
	// Exact-length allocation: the receiver frees this with delete(). See vm/eval_expr.odin.
	shrink(&words)
	return words[:]
}

// words_to_list builds the MOO list of strings do_login_command()/eval_and_dispatch expect
// as `args`, consuming `words` (each element's ownership transfers into the list).
words_to_list :: proc(words: []string) -> values.Var {
	items := make([]values.Var, len(words))
	for w, i in words {
		items[i] = values.str_val(w)
	}
	delete(words) // the []string backing array, not the strings themselves (now owned by items)
	return values.list_val(items)
}

// world_of returns the Object_World behind this server's World.
world_of :: proc(s: ^Server) -> ^objdb.Object_World {
	return (^objdb.Object_World)(s.world.user_data)
}

// server_message ports server.c's send_message(): the listener's (here always #0's)
// $server_options.<name> -- a string, or a list whose string elements are each a line --
// replacing the default lines; an option that exists but is neither means "say nothing".
// The caller holds big_lock (this reads the DB). Returned lines are owned.
server_message :: proc(s: ^Server, name: string, defaults: ..string) -> [dynamic]string {
	out: [dynamic]string
	v, found := objdb.get_server_option(world_of(s), SYSTEM_OBJECT, name)
	if !found {
		for d in defaults {
			append(&out, strings.clone(d))
		}
		return out
	}
	defer values.free_var(v)
	#partial switch v.type {
	case .Str:
		append(&out, strings.clone(v.data.str.s))
	case .List:
		for i in 1 ..= values.list_len(v) {
			if item := values.list_get(v, i); item.type == .Str {
				append(&out, strings.clone(item.data.str.s))
			}
		}
	}
	return out
}

// send_lines sends each line raw (the original's network_send_line -- these are server
// messages, not MOO output) and frees them.
send_lines :: proc(conn: ^Connection, lines: [dynamic]string) {
	for l in lines {
		send_line_raw(conn, l)
		delete(l)
	}
	delete(lines)
}

// run_notifier ports server.c's call_notifier(): #0:<verb>(player) as a server task, with
// player bound to `player`. Takes big_lock itself.
run_notifier :: proc(s: ^Server, verb: string, player: values.Objid) {
	args := make([]values.Var, 1)
	args[0] = values.obj_val(player)
	sync.mutex_lock(&s.scheduler.big_lock)
	v, _ := objdb.run_root_verb(world_of(s), s.world, objdb.Root_Call{
		player = player, this = SYSTEM_OBJECT, verb = verb, args = values.list_val(args),
	})
	sync.mutex_unlock(&s.scheduler.big_lock)
	values.free_var(v)
}

// notify_disconnect tells the database a connection is gone, per its close reason (see
// Connection.close_reason).
notify_disconnect :: proc(s: ^Server, reason: Close_Reason, player: values.Objid) {
	switch reason {
	case .Client:
		run_notifier(s, "user_client_disconnected", player) // server_close()
	case .Booted, .Timeout:
		run_notifier(s, "user_disconnected", player) // main_loop's disconnect_me / timeout sweep
	case .Redirected, .Recycled, .Shutdown:
	}
}

// ---- Connection_Hooks implementations, wired into an objdb.Object_World by
// wire_connection_hooks() below. ----

@(private = "file")
hook_notify :: proc(user_data: rawptr, player: values.Objid, text: string) -> bool {
	s := (^Server)(user_data)
	// players_lock is held ACROSS the send, not just across the map lookup. See the
	// "Connection lifetime" note at the bottom of this file: the lock is the only thing
	// keeping `conn` from being freed underneath us, so a pattern of "look it up, unlock,
	// then use it" is a use-after-free waiting for a player to disconnect at the wrong
	// moment. Safe to hold because send_line only ever appends to a buffer -- it never
	// touches the network (see enqueue_output).
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	conn, ok := s.players[player]
	if !ok {
		return false
	}
	send_line(conn, text)
	return true
}

// hook_notify_raw backs notify_raw() -- see objdb/connection_io.odin's header for why this
// exists alongside notify().
@(private = "file")
hook_notify_raw :: proc(user_data: rawptr, player: values.Objid, text: string) -> bool {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock) // held across the send -- see hook_notify
	defer sync.mutex_unlock(&s.players_lock)
	conn, ok := s.players[player]
	if !ok {
		return false
	}
	send_line_raw(conn, text)
	return true
}

@(private = "file")
hook_connection_name :: proc(user_data: rawptr, player: values.Objid) -> (name: string, found: bool) {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock) // held across the read -- see hook_notify
	defer sync.mutex_unlock(&s.players_lock)
	conn, ok := s.players[player]
	if !ok {
		return "", false
	}
	return strings.clone(conn.name), true
}

// hook_idle_seconds backs idle_seconds(): time since the connection's last line of input.
@(private = "file")
hook_idle_seconds :: proc(user_data: rawptr, player: values.Objid) -> (secs: i64, found: bool) {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	conn, ok := s.players[player]
	if !ok {
		return 0, false
	}
	sync.mutex_lock(&conn.io_lock)
	defer sync.mutex_unlock(&conn.io_lock)
	return i64(time.duration_seconds(time.since(conn.last_activity))), true
}

@(private = "file")
hook_boot_player :: proc(user_data: rawptr, player: values.Objid) {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock) // held throughout -- see hook_notify
	conn, ok := s.players[player]
	if !ok {
		return
	}
	// boot_player only marks the connection in the original (disconnect_me); the main loop
	// then runs #0:user_disconnected and sends boot_msg. Here the hook runs inside the MOO task
	// that called boot_player(), which holds big_lock, so the message is read now and the
	// notifier runs from the connection's own teardown.
	delete_key(&s.players, player)
	conn.close_reason = .Booted
	disconnect_conn(s, conn, server_message(s, "boot_msg", "*** Disconnected ***"))
}

// disconnect_conn forcibly ends a connection that has ALREADY been removed from `players`
// (caller's job, under players_lock, which the caller must still hold): send a final line,
// wake anything parked on it, and shut the socket down so the connection's own thread
// notices and tears itself down. Shared by boot_player() and by finish_login()'s
// displaced-reconnect path.
//
// Deliberately no net.close() here -- only net.shutdown(). The descriptor belongs to the
// connection's own thread, which closes it exactly once during teardown; closing it from
// here as well is a double close, and the number can be handed straight back out by accept()
// in between (see server_stop's comment for the full reasoning).
//
// Shutting down only the RECEIVE half leaves the write half open, so the final line above
// actually reaches the client: the writer thread drains what is buffered and the connection
// thread's own teardown does the final shutdown(Both) once that drain is done. Shutting both
// halves here (which is what this used to do) discarded the buffered boot message almost
// every time -- the message was enqueued a few microseconds earlier and the writer thread had
// not been scheduled yet. Receive alone is still enough to unblock the connection thread's
// recv_tcp, which is what makes it tear down at all.
@(private = "file")
disconnect_conn :: proc(s: ^Server, conn: ^Connection, final_lines: [dynamic]string) {
	send_lines(conn, final_lines)
	// A task parked in read() on this connection can't be woken by closing its socket
	// (it's blocked on a condition variable, not a socket call) -- same issue and same
	// fix as server.odin's server_stop; without this, boot_player()ing a player mid-read()
	// would leave that thread parked forever.
	sync.mutex_lock(&conn.io_lock)
	tid := conn.reader_task_id
	conn.reader_task_id = 0
	sync.mutex_unlock(&conn.io_lock)
	if tid != 0 {
		wake_reader_closed(s.scheduler, tid)
	}
	net.shutdown(conn.socket, .Receive)
}

// sweep_connections ports the end of server.c's main loop: an un-logged-in connection idle for
// longer than connect_timeout (default 300 seconds; $server_options.connect_timeout, where a
// non-positive or non-integer value disables it) is closed with timeout_msg and
// #0:user_disconnected, and a logged-in connection whose player object no longer exists is
// closed with recycle_msg. Called periodically by the server's main loop.
sweep_connections :: proc(s: ^Server) {
	ow := world_of(s)
	sync.mutex_lock(&s.scheduler.big_lock)
	defer sync.mutex_unlock(&s.scheduler.big_lock)
	timeout := f64(DEFAULT_CONNECT_TIMEOUT)
	if v, found := objdb.get_server_option(ow, SYSTEM_OBJECT, "connect_timeout"); found {
		timeout = v.type == .Int && v.data.num > 0 ? f64(v.data.num) : -1
		values.free_var(v)
	}
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	doomed: [dynamic]^Connection
	defer delete(doomed)
	for player, conn in s.players {
		if player < 0 {
			sync.mutex_lock(&conn.io_lock)
			idle := time.duration_seconds(time.since(conn.last_activity))
			sync.mutex_unlock(&conn.io_lock)
			if timeout > 0 && idle > timeout {
				conn.close_reason = .Timeout
				append(&doomed, conn)
			}
		} else if !objdb.valid(ow.db, player) {
			conn.close_reason = .Recycled
			append(&doomed, conn)
		}
	}
	for conn in doomed {
		delete_key(&s.players, conn.player)
		if conn.close_reason == .Timeout {
			fmt.printfln("TIMEOUT: #%d on %s", conn.player, conn.name)
			disconnect_conn(s, conn, server_message(s, "timeout_msg", "*** Timed-out waiting for login. ***"))
		} else {
			fmt.printfln("RECYCLED: #%d on %s", conn.player, conn.name)
			disconnect_conn(s, conn, server_message(s, "recycle_msg", "*** Recycled ***"))
		}
	}
}

// DEFAULT_CONNECT_TIMEOUT is options.h's.
DEFAULT_CONNECT_TIMEOUT :: 300

// hook_connected_players ports the shandle-list scan behind connected_players(): every
// registered connection whose player ID is >= 0 is past login (negative IDs are the
// pre-login placeholders allocate_connection_id hands out -- see that proc's comment), so
// the default (include_all=false) filters to those; include_all returns every registered ID
// as-is.
@(private = "file")
hook_connected_players :: proc(user_data: rawptr, include_all: bool) -> []values.Objid {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	conns := make([dynamic]^Connection, 0, len(s.players))
	defer delete(conns)
	for player, conn in s.players {
		if include_all || player >= 0 {
			append(&conns, conn)
		}
	}
	// The original walks all_shandles, which new connections are pushed onto the front of:
	// newest connection first. (The map's own order is arbitrary, and differs run to run.)
	slice.sort_by(conns[:], proc(a, b: ^Connection) -> bool {return a.seq > b.seq})
	ids := make([]values.Objid, len(conns))
	for c, i in conns {
		ids[i] = c.player
	}
	return ids
}

// hook_connected_seconds ports the shandle.connection_time check behind connected_seconds():
// found=false for any id not currently registered as a past-login connection (negative
// placeholder IDs and unknown players alike), matching the original's E_INVARG-on-not-found.
@(private = "file")
hook_connected_seconds :: proc(user_data: rawptr, player: values.Objid) -> (secs: i64, found: bool) {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock) // held across the read of conn -- see hook_notify
	defer sync.mutex_unlock(&s.players_lock)
	conn, ok := s.players[player]
	if !ok || player < 0 {
		return 0, false
	}
	return i64(time.duration_seconds(time.since(conn.connect_time))), true
}

// hook_output_delimiters backs output_delimiters() -- see command.odin's
// handle_intrinsic_command (PREFIX/SUFFIX) for where conn.output_prefix/output_suffix are
// actually set. Returned strings are cloned copies (owned per Connection_Hooks' contract),
// not the connection's own live storage, since that could change concurrently.
@(private = "file")
hook_output_delimiters :: proc(user_data: rawptr, player: values.Objid) -> (prefix: string, suffix: string, found: bool) {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock) // held across the read -- see hook_notify
	defer sync.mutex_unlock(&s.players_lock)
	conn, ok := find_conn_locked(s, player)
	if !ok {
		return "", "", false
	}
	// io_lock, not just players_lock: these two strings are REPLACED (old one freed, new one
	// cloned) by a PREFIX/SUFFIX command running on the connection's drain worker, which is a
	// different thread from this one and holds no players_lock. Reading them unsynchronised
	// races that swap, and cloning from a pointer the swap just freed is a use-after-free.
	sync.mutex_lock(&conn.io_lock)
	defer sync.mutex_unlock(&conn.io_lock)
	return strings.clone(conn.output_prefix), strings.clone(conn.output_suffix), true
}

// hook_listening_points reports this server's single listening point, backing listeners().
// The original's initial listener is new_slistener(SYSTEM_OBJECT, <port>, 1, 0)
// (server.c:1250), so the object is #0 and print_messages is on; listen()/unlisten() would
// add and remove further points, and aren't implemented here (see objdb's bf_listeners).
@(private = "file")
hook_listening_points :: proc(user_data: rawptr) -> []objdb.Listening_Point {
	s := (^Server)(user_data)
	endpoint, err := net.bound_endpoint(s.listener)
	if err != nil {
		return {}
	}
	points := make([]objdb.Listening_Point, 1)
	points[0] = objdb.Listening_Point{
		object         = values.SYSTEM_OBJECT,
		port           = int(endpoint.port),
		print_messages = true,
	}
	return points
}

// hook_buffered_output_length reports how many bytes are queued for a connection but not yet
// written to its socket -- the outbound buffer enqueue_output appends to and the writer
// thread drains (connection.odin). Both locks are needed and in this order: players_lock to
// hold the ^Connection still (see the "Connection lifetime" note below), out_lock because the
// writer thread swaps that buffer out from under readers.
@(private = "file")
hook_buffered_output_length :: proc(user_data: rawptr, player: values.Objid) -> (n: int, found: bool) {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	conn, ok := s.players[player]
	if !ok {
		return 0, false
	}
	sync.mutex_lock(&conn.out_lock)
	defer sync.mutex_unlock(&conn.out_lock)
	// out_in_flight covers the window where the writer has swapped the buffer out and is
	// blocked in send_tcp -- without it this reports 0 for a stalled client, which is the one
	// case the built-in is for. See Connection.out_in_flight.
	return len(conn.out_buf) + conn.out_in_flight, true
}

// hook_max_queued_output answers buffered_output_length()'s no-argument form: the ceiling any
// one connection's buffer is allowed to reach before the backlog is discarded.
@(private = "file")
hook_max_queued_output :: proc(user_data: rawptr) -> int {
	return MAX_QUEUED_OUTPUT
}

// wire_connection_hooks points an Object_World's notify/connection_name/boot_player/
// connected_players/connected_seconds at this server's connection registry. Call once, after
// object_world_init() and before server_start() -- server/main.odin does this at startup.
wire_connection_hooks :: proc(ow: ^objdb.Object_World, s: ^Server) {
	ow.conn = objdb.Connection_Hooks{
		user_data          = s,
		notify             = hook_notify,
		notify_raw         = hook_notify_raw,
		connection_name    = hook_connection_name,
		boot_player        = hook_boot_player,
		connected_players  = hook_connected_players,
		connected_seconds  = hook_connected_seconds,
		try_dequeue_input  = hook_try_dequeue_input,
		register_reader    = hook_register_reader,
		unregister_reader  = hook_unregister_reader,
		force_input        = hook_force_input,
		flush_input        = hook_flush_input,
		set_connection_option = hook_set_connection_option,
		connection_option  = hook_connection_option,
		connection_options = hook_connection_options,
		output_delimiters  = hook_output_delimiters,
		idle_seconds       = hook_idle_seconds,
		listening_points   = hook_listening_points,
		buffered_output_length = hook_buffered_output_length,
		max_queued_output  = hook_max_queued_output,
	}
}

// login_dispatch ports do_login_task(): #0:do_login_command(@words) runs as a server task with
// argstr = the line; if it returns a player object (is_user) and this connection is still open,
// the connection becomes that player's (player_connected, below). Anything else -- an error, an
// int, an invalid object -- means "still logging in"; do_login_command does its own talking.
//
// Not file-private: input_queue.odin's dispatch_now() calls this for queued lines too.
login_dispatch :: proc(conn: ^Connection, line: string) {
	s := conn.server
	ow := world_of(s)
	args := words_to_list(split_command_words(line))

	sync.mutex_lock(&s.scheduler.big_lock)
	old_max := ow.db.max_oid
	value, outcome := objdb.run_root_verb(ow, s.world, objdb.Root_Call{
		player = conn.player, this = SYSTEM_OBJECT, verb = "do_login_command", args = args, argstr = line,
	})
	new_player := values.NOTHING
	if outcome == .Done && value.type == .Obj && objdb.valid(ow.db, value.data.obj) && objdb.object_has_flag(ow.db, value.data.obj, .User) {
		new_player = value.data.obj
	}
	values.free_var(value)
	if new_player == values.NOTHING {
		sync.mutex_unlock(&s.scheduler.big_lock)
		return
	}
	// player_connected decides created-vs-connected by `new_player > old_max_object`.
	player_connected(s, conn, new_player, new_player > old_max)
	sync.mutex_unlock(&s.scheduler.big_lock)
}

// player_connected ports server.c's player_connected(). Called with big_lock held.
//
// If the player is already connected elsewhere, that older connection is told
// redirect_from_msg and closed (no disconnect notification for it), this one is told
// redirect_to_msg, and #0:user_reconnected runs. Otherwise this connection is told create_msg
// or connect_msg and #0:user_created or #0:user_connected runs.
@(private = "file")
player_connected :: proc(s: ^Server, conn: ^Connection, player: values.Objid, created: bool) {
	from_lines := server_message(s, "redirect_from_msg", "*** Redirecting connection to new port ***")
	to_lines := server_message(s, "redirect_to_msg", "*** Redirecting old connection to this port ***")
	new_lines := created \
		? server_message(s, "create_msg", "*** Created ***") \
		: server_message(s, "connect_msg", "*** Connected ***")

	sync.mutex_lock(&s.players_lock)
	if conn.closing {
		// The client hung up while its login line was being processed: nobody is there to
		// log in, and registering a connection that is already tearing down would leave a
		// dangling entry (see Connection.closing).
		sync.mutex_unlock(&s.players_lock)
		delete_lines(from_lines)
		delete_lines(to_lines)
		delete_lines(new_lines)
		return
	}
	old_id := conn.player
	delete_key(&s.players, old_id) // drop the pre-login placeholder
	redirected := false
	if old_conn, ok := s.players[player]; ok && old_conn != conn {
		delete_key(&s.players, player)
		old_conn.close_reason = .Redirected
		fmt.printfln("REDIRECTED: #%d, was %s, now %s", player, old_conn.name, conn.name)
		disconnect_conn(s, old_conn, from_lines)
		redirected = true
	} else {
		delete_lines(from_lines)
		fmt.printfln("%s: #%d on %s", created ? "CREATED" : "CONNECTED", player, conn.name)
	}
	conn.player = player
	conn.connect_time = time.now()
	s.players[player] = conn
	sync.mutex_unlock(&s.players_lock)

	if redirected {
		delete_lines(new_lines)
		send_lines(conn, to_lines)
	} else {
		delete_lines(to_lines)
		send_lines(conn, new_lines)
	}

	verb := redirected ? "user_reconnected" : (created ? "user_created" : "user_connected")
	args := make([]values.Var, 1)
	args[0] = values.obj_val(player)
	v, _ := objdb.run_root_verb(world_of(s), s.world, objdb.Root_Call{
		player = player, this = SYSTEM_OBJECT, verb = verb, args = values.list_val(args),
	})
	values.free_var(v)
}

@(private = "file")
delete_lines :: proc(lines: [dynamic]string) {
	for l in lines {
		delete(l)
	}
	delete(lines)
}

// unregister_conn removes a connection from the registry the hooks above read, called from
// connection.odin as the FIRST step of connection teardown.
//
// Identity-checked: it deletes the key only if the key still maps to THIS connection. A
// plain delete_key(player) is wrong because the key is a player id, not a connection id,
// and two connections can briefly share one -- a player reconnecting while their previous
// session is still shutting down. Whichever connection died second would then evict the
// live one, leaving a connected player that notify() can no longer reach at all.
//
// This is also the point after which no other thread can obtain this Connection (every
// route to one goes through `players` under this lock), which is what makes the rest of
// teardown -- freeing the connection's queues, options and buffers, and finally the
// Connection itself -- safe to do at all. See the "Connection lifetime" note below.
unregister_conn :: proc(s: ^Server, conn: ^Connection) -> (reason: Close_Reason, player: values.Objid) {
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	reason, player = conn.close_reason, conn.player
	// Set in the same hold as the removal, and this is the half that makes removal stick: a
	// drain worker part-way through finish_login is about to re-register this connection under
	// its new player id, and the only way to stop it is a mark it checks under this same lock.
	// See Connection.closing and finish_login.
	conn.closing = true
	if current, ok := s.players[conn.player]; ok && current == conn {
		delete_key(&s.players, conn.player)
	}
	return
}

// allocate_connection_id hands out the next negative placeholder ID (server.c's
// next_unconnected_player-- in server_new_connection()) and registers `conn` under it, so
// notify() can reach this connection immediately -- even before login, while $login:welcome
// is running. connection.odin calls this once, right after accept.
allocate_connection_id :: proc(s: ^Server, conn: ^Connection) -> values.Objid {
	sync.mutex_lock(&s.players_lock)
	id := s.next_unconnected
	s.next_unconnected -= 1
	s.players[id] = conn
	sync.mutex_unlock(&s.players_lock)
	return id
}

// ---- Connection lifetime ----
//
// A ^Connection is owned by its own thread (connection.odin's connection_handler), which
// allocates it (via accept_loop) and frees it. Every OTHER thread that touches one -- every
// hook in this file, every hook in input_queue.odin, server_stop's shutdown sweep -- reaches
// it through Server.players, and the rule that makes that safe is:
//
//	A Connection may be dereferenced by a thread other than its own ONLY while that
//	thread holds players_lock, and never after it releases it.
//
// The other half of the contract lives in connection_handler's teardown: unregister_conn()
// runs first, under players_lock, and only then is any of the connection's state (its input
// queue, its option map, its output buffer, the Connection itself) torn down. So a hook
// either gets the lock first and finds a fully live connection, or gets it after teardown
// and finds nothing in the map.
//
// This is why the hooks above hold players_lock across their whole body instead of just the
// map lookup, and it is also why nothing here calls net.close() on a connection's socket:
// closing is teardown, and teardown belongs to the owning thread.
