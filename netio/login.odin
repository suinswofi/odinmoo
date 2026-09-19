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

// call_root_verb invokes obj:name(args) as a fresh, server-initiated task rather than a
// nested verb call -- the same thing run_server_task_setting_id() does in tasks.c. depth=-1
// on the synthetic root activation means the callee's own activation ends up at depth=0 (see
// world_call_verb's `act.depth = ctx.activation.depth + 1`), so callers() inside it correctly
// reports "not called from another verb" -- what #0:do_login_command's `if (callers()) return
// E_PERM;` guard checks for.
call_root_verb :: proc(world: ^vm.World, obj: values.Objid, name: string, args: values.Var, player: values.Objid, task_id: int) -> vm.Call_Result {
	root_act := vm.Activation {
		this       = values.NOTHING,
		player     = player,
		caller     = values.NOTHING,
		programmer = values.NOTHING,
		verb_loc   = values.NOTHING,
		task_id    = task_id,
		depth      = -1,
	}
	ctx := vm.Eval_Context{activation = &root_act, world = world}
	return world.call_verb(world, obj, name, args, &ctx)
}

// is_player_object ports the is_user() check do_login_task uses on the value
// #0:do_login_command returns, to decide whether login succeeded.
is_player_object :: proc(world: ^vm.World, obj: values.Objid) -> bool {
	ow := (^objdb.Object_World)(world.user_data)
	return objdb.valid(ow.db, obj) && objdb.object_has_flag(ow.db, obj, .User)
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
	sync.mutex_lock(&s.players_lock) // held across the peer lookup -- see hook_notify
	defer sync.mutex_unlock(&s.players_lock)
	conn, ok := s.players[player]
	if !ok {
		return "", false
	}
	ep, err := net.peer_endpoint(conn.socket)
	if err != nil {
		return "", false
	}
	// Explicit allocator: endpoint_to_string's default is context.temp_allocator, but
	// Connection_Hooks.connection_name's contract (see world.odin) is "owned if found" --
	// the caller eventually runs this through values.str_val() -> values.free_var(), which
	// frees via context.allocator. A temp-arena string freed through the heap allocator is
	// exactly the kind of allocator mismatch that corrupts the heap instead of erroring
	// cleanly -- this is what a real telnet session against LambdaCore.db actually hit.
	return net.endpoint_to_string(ep, context.allocator), true
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
	delete_key(&s.players, player)
	disconnect_conn(s, conn, "%r*** Booted ***%n")
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
// halves here (which is what this used to do) discarded the buffered "*** Booted ***" almost
// every time -- the message was enqueued a few microseconds earlier and the writer thread had
// not been scheduled yet. Receive alone is still enough to unblock the connection thread's
// recv_tcp, which is what makes it tear down at all.
@(private = "file")
disconnect_conn :: proc(s: ^Server, conn: ^Connection, final_line: string) {
	send_line(conn, final_line)
	// A task parked in read() on this connection can't be woken by closing its socket
	// (it's blocked on a condition variable, not a socket call) -- same issue and same
	// fix as server.odin's server_stop; without this, boot_player()ing a player mid-read()
	// would leave that thread parked forever.
	sync.mutex_lock(&conn.io_lock)
	tid := conn.reader_task_id
	conn.reader_task_id = 0
	sync.mutex_unlock(&conn.io_lock)
	if tid != 0 {
		wake_reader(s.scheduler, tid, strings.clone(""))
	}
	net.shutdown(conn.socket, .Receive)
}

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
	ids := make([dynamic]values.Objid, 0, len(s.players))
	for player in s.players {
		if include_all || player >= 0 {
			append(&ids, player)
		}
	}
	return ids[:]
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
		listening_points   = hook_listening_points,
		buffered_output_length = hook_buffered_output_length,
		max_queued_output  = hook_max_queued_output,
	}
}

// finish_login ports player_connected()'s non-redirect branch (server.c:1080-1097): register
// the connection, send the literal "*** Connected ***" banner, then call #0:user_connected as
// a fresh server task (call_notifier()). Reconnection redirects (an already-connected player
// logging in again on a second connection, server.c:1049-1079) and "*** Created ***"/
// user_created (which needs create()-based player creation to ever trigger, not implemented
// yet -- see object_builtins.odin's header note on scope) are both out of scope for the same
// reason: this port's do_login_command support only covers the `connect` path against
// existing players.
finish_login :: proc(s: ^Server, conn: ^Connection, player: values.Objid) {
	sync.mutex_lock(&s.players_lock)
	if conn.closing {
		// This connection's own thread has already started tearing it down -- the client hung
		// up while its `connect ...` line was still being processed on a drain worker, which is
		// routine. Registering it now would put a Connection that is about to be freed back
		// into the map for every hook and for server_stop to find; worse, the teardown that
		// is already under way will not remove it again, so the entry outlives the memory. The
		// observable symptom was a shutdown that never completed. Abandon the login instead:
		// there is nobody on the other end of it any more.
		sync.mutex_unlock(&s.players_lock)
		return
	}
	delete_key(&s.players, conn.player) // drop the pre-login negative placeholder ID
	// An already-connected player logging in again on a second connection: the registry is
	// keyed by player id, so the two connections would otherwise share one key -- only the
	// newer reachable by notify(), and the older one's eventual teardown deleting the key
	// out from under the live connection, silently cutting the player off from all output
	// while they were still typing. Full reconnect redirection (server.c:1049-1079's
	// "*** Redirected ***" handover, complete with $login:redirected_task) is out of scope
	// here, but a stale connection MUST not be left sharing the key: disconnect it.
	if old_conn, ok := s.players[player]; ok && old_conn != conn {
		delete_key(&s.players, player)
		disconnect_conn(s, old_conn, "*** Redirected ***")
	}
	conn.player = player
	conn.connect_time = time.now()
	s.players[player] = conn
	sync.mutex_unlock(&s.players_lock)

	send_line(conn, "*** Connected ***")

	args_items := make([]values.Var, 1)
	args_items[0] = values.obj_val(player)
	args := values.list_val(args_items)
	task_id := tasks.new_task_id(s.scheduler)
	// big_lock is NOT optional here, even though this call site "owns" the connection: MOO
	// execution anywhere means holding it. #0:user_connected's own fork(0) bodies start
	// immediately on their own threads and take the lock -- run this call without it and
	// the connect chain races its own forks over shared refcounted values, which surfaces
	// as one-in-N random E_VERBNF/E_TYPE/E_RANGE around login and anything typed just
	// after it. (Found exactly that way.)
	sync.mutex_lock(&s.scheduler.big_lock)
	result := call_root_verb(s.world, SYSTEM_OBJECT, "user_connected", args, player, task_id)
	sync.mutex_unlock(&s.scheduler.big_lock)
	if result.raised {
		// An uncaught error here is not cosmetic: #0:user_connected is what moves a
		// connecting player into the world, so a raise leaves them wherever the DB left
		// them with no working commands. The original logs a full traceback for a failed
		// server task; log at least the error rather than swallowing it silently.
		fmt.printfln("ERROR: #0:user_connected raised %v: %s", result.code, result.msg)
		delete(result.msg)
		values.free_var(result.rvalue)
	} else {
		values.free_var(result.value)
	}
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
unregister_conn :: proc(s: ^Server, conn: ^Connection) {
	sync.mutex_lock(&s.players_lock)
	defer sync.mutex_unlock(&s.players_lock)
	// Set in the same hold as the removal, and this is the half that makes removal stick: a
	// drain worker part-way through finish_login is about to re-register this connection under
	// its new player id, and the only way to stop it is a mark it checks under this same lock.
	// See Connection.closing and finish_login.
	conn.closing = true
	if current, ok := s.players[conn.player]; ok && current == conn {
		delete_key(&s.players, conn.player)
	}
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
