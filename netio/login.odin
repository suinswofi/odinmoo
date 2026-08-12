package netio

// The real login protocol, ported from tasks.c's do_login_task() and parse_cmd.c's
// parse_into_words(), plus the Connection_Hooks (objdb/world.odin) that let
// notify()/connection_name()/boot_player() reach an actual socket.

import "../objdb"
import "../tasks"
import "../values"
import "../vm"
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
	sync.mutex_lock(&s.players_lock)
	conn, ok := s.players[player]
	sync.mutex_unlock(&s.players_lock)
	if !ok {
		return false
	}
	send_line(conn, text)
	return true
}

@(private = "file")
hook_connection_name :: proc(user_data: rawptr, player: values.Objid) -> (name: string, found: bool) {
	s := (^Server)(user_data)
	sync.mutex_lock(&s.players_lock)
	conn, ok := s.players[player]
	sync.mutex_unlock(&s.players_lock)
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
	conn, ok := s.players[player]
	if ok {
		delete_key(&s.players, player)
	}
	sync.mutex_unlock(&s.players_lock)
	if ok {
		send_line(conn, "%r*** Booted ***%n")
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
		// shutdown() before close(): see server.odin's server_stop for why close() alone
		// isn't reliable at waking a concurrent blocked recv_tcp() on Linux.
		net.shutdown(conn.socket, .Both)
		net.close(conn.socket)
	}
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
	sync.mutex_lock(&s.players_lock)
	conn, ok := s.players[player]
	sync.mutex_unlock(&s.players_lock)
	if !ok || player < 0 {
		return 0, false
	}
	return i64(time.duration_seconds(time.since(conn.connect_time))), true
}

// wire_connection_hooks points an Object_World's notify/connection_name/boot_player/
// connected_players/connected_seconds at this server's connection registry. Call once, after
// object_world_init() and before server_start() -- server/main.odin does this at startup.
wire_connection_hooks :: proc(ow: ^objdb.Object_World, s: ^Server) {
	ow.conn = objdb.Connection_Hooks{
		user_data          = s,
		notify             = hook_notify,
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
	unregister_player(s, conn.player) // drop the pre-login negative placeholder ID
	conn.player = player
	conn.connect_time = time.now()
	register_player(s, player, conn)

	send_line(conn, "*** Connected ***")

	args_items := make([]values.Var, 1)
	args_items[0] = values.obj_val(player)
	args := values.list_val(args_items)
	task_id := tasks.new_task_id(s.scheduler)
	result := call_root_verb(s.world, SYSTEM_OBJECT, "user_connected", args, player, task_id)
	if result.raised {
		delete(result.msg)
		values.free_var(result.rvalue)
	} else {
		values.free_var(result.value)
	}
}

// register_player and unregister_player maintain the registry that the hooks above read.
// Called from connection.odin on successful login / connection teardown.
register_player :: proc(s: ^Server, player: values.Objid, conn: ^Connection) {
	sync.mutex_lock(&s.players_lock)
	s.players[player] = conn
	sync.mutex_unlock(&s.players_lock)
}

unregister_player :: proc(s: ^Server, player: values.Objid) {
	sync.mutex_lock(&s.players_lock)
	delete_key(&s.players, player)
	sync.mutex_unlock(&s.players_lock)
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
