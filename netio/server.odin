package netio

// TCP networking, re-engineered rather than ported line-for-line from net_multi.c/server.c.
//
// The original multiplexes every connection's non-blocking socket through a single
// select()/poll() loop on one thread, specifically so one process can serve many
// connections without one blocking another. This port gets the same "one connection never
// blocks another" property a different way: each accepted connection gets its own OS
// thread with an ordinary blocking socket. That's a legitimate, simpler alternative given
// Phase 6 already established genuine multi-threaded concurrency (the scheduler's "big
// lock" model) -- there's no single-threaded event loop left to protect here. Command
// *execution* still serializes correctly through the same big lock every task already goes
// through, so this doesn't weaken the concurrency guarantee the original relied on, just
// relocates where the concurrency lives (OS thread scheduling instead of one thread's
// select() multiplexing).
//
// The connection lifecycle implements the real protocol (see login.odin): on connect, an
// empty-string "command" is dispatched to #0:do_login_command() exactly as the original's
// server_new_connection()/do_login_task() do, which is what makes $login:welcome's
// notify()-based banner appear without netio hardcoding any welcome text of its own. Each
// subsequent line is word-split and re-dispatched the same way until a valid player object
// comes back, at which point the connection is registered (see `players` below) and ordinary
// command lines are evaluated as MOO expressions -- a REPL, not the original's full
// preposition/verb-matching command parser (parse_command() in parse_cmd.c), which is a
// materially larger, separate piece of work.
//
// server_stop() *does* wait for every connection thread to actually exit (see its own
// comment) -- unlike the original, which lets already-open connections linger past shutdown.
// That matters here specifically because Odin callers (tests, and main.odin's own shutdown
// path before writing the final checkpoint) routinely free the World/Database right after
// server_stop() returns; a connection thread still touching either at that point would be a
// real use-after-free, not just an academic concern.

import "../tasks"
import "../values"
import "../vm"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"

Server :: struct {
	listener:      net.TCP_Socket,
	scheduler:     ^tasks.Scheduler,
	world:         ^vm.World,
	running:       bool,
	accept_done:   sync.Wait_Group, // lets server_stop know the accept loop has actually exited
	conns_done:    sync.Wait_Group, // lets server_stop know every connection thread has actually exited
	players_lock:  sync.Mutex, // guards `players` and `next_unconnected`, independent of the
	// scheduler's big_lock since registration/lookup needs to work regardless of which
	// thread happens to be executing MOO code (notify() can be called from any task) or
	// accepting/closing a connection (which isn't task execution at all).
	players:       map[values.Objid]^Connection, // player-or-placeholder -> its connection
	next_unconnected: values.Objid, // ports server.c's next_unconnected_player counter (starts
	// at NOTHING-1, decrements): every fresh connection gets one of these negative IDs
	// before login so notify()/do_login_command have someone to address, exactly like the
	// original's shandle->player assignment in server_new_connection().
}

// server_start binds and listens (port 0 picks an ephemeral port -- useful for tests) on
// the given, already-allocated Server (caller owns its lifetime, same pattern as
// tasks.scheduler_init/objdb.object_world_init), then spawns the accept loop on its own
// thread. Returns immediately; the caller can read back the actual bound port via
// net.bound_endpoint(s.listener).
server_start :: proc(s: ^Server, port: int, scheduler: ^tasks.Scheduler, world: ^vm.World) -> net.Network_Error {
	endpoint := net.Endpoint{address = net.IP4_Loopback, port = port}
	listener := net.listen_tcp(endpoint) or_return
	s.listener = listener
	s.scheduler = scheduler
	s.world = world
	s.running = true
	s.players = make(map[values.Objid]^Connection)
	s.next_unconnected = values.NOTHING - 1
	sync.wait_group_add(&s.accept_done, 1)
	thread.create_and_start_with_data(s, accept_loop, init_context = context, self_cleanup = true)
	return nil
}

// server_stop signals the accept loop to end, forcibly disconnects every currently-open
// connection, and waits for all of it (accept loop + every connection thread) to actually
// exit before returning -- so the caller can safely free the World/Database right after this
// returns (see the package header comment).
//
// Closing the listening socket alone is NOT enough here: a thread already blocked inside
// accept() on that socket is not guaranteed to wake up just because another thread closed
// it (a real POSIX quirk, not a hypothetical one -- this hung in testing before the dummy-
// connect below was added). So: flip `running` to false, then make a throwaway local
// connection to the listener to force the pending accept() to actually return; accept_loop
// notices `running` is false, discards that dummy connection, and exits.
//
// Every live connection -- logged in or still mid-login -- is registered in `players` (see
// login.odin's allocate_connection_id/finish_login), so closing every socket found there is
// enough to unblock every connection thread's recv_tcp; each then notices the error, runs its
// own defers (including unregistering itself), and exits.
server_stop :: proc(s: ^Server) {
	s.running = false
	if endpoint, err := net.bound_endpoint(s.listener); err == nil {
		if dummy, derr := net.dial_tcp_from_endpoint(endpoint); derr == nil {
			net.close(dummy)
		}
	}
	net.close(s.listener)
	sync.wait_group_wait(&s.accept_done)

	sync.mutex_lock(&s.players_lock)
	for _, conn in s.players {
		// A task parked in read() (objdb/connection_io.odin's bf_read) is blocked on a
		// condition variable inside the scheduler, not inside a socket call at all -- closing
		// or even shutdown()ing its connection's socket does NOT wake it (unlike a thread
		// blocked in recv_tcp, which shutdown() below does reliably unblock). Left alone, that
		// thread would never return from connection_handler, conns_done would never complete,
		// and server_stop would hang forever. So: wake any pending reader explicitly first,
		// exactly like input_queue.odin's connection_io_destroy does for the "client
		// disconnected on its own" case -- this is the same fix for the "we're the ones
		// closing it" case, which that per-connection defer can't reach because the blocked
		// thread never gets to its own defers until read() itself returns.
		sync.mutex_lock(&conn.io_lock)
		tid := conn.reader_task_id
		conn.reader_task_id = 0
		sync.mutex_unlock(&conn.io_lock)
		if tid != 0 {
			wake_reader(s.scheduler, tid, strings.clone(""))
		}
		// shutdown() before close(): a thread blocked in recv_tcp() on this socket is not
		// reliably woken by another thread merely close()ing the fd on Linux (the same class
		// of accept()-vs-close() quirk noted above, for recv() instead) -- shutdown(Both) is
		// the documented, reliable way to force a concurrent blocking read to return
		// immediately (as a 0-byte EOF), which is what actually unblocks connection_handler's
		// loop below instead of leaving it (and thus server_stop) hung until the remote end
		// closes its side on its own.
		net.shutdown(conn.socket, .Both)
		net.close(conn.socket)
	}
	sync.mutex_unlock(&s.players_lock)
	sync.wait_group_wait(&s.conns_done)

	delete(s.players)
}

@(private = "file")
accept_loop :: proc(data: rawptr) {
	s := (^Server)(data)
	defer sync.wait_group_done(&s.accept_done)
	for s.running {
		client, _, err := net.accept_tcp(s.listener)
		if err != nil {
			break // listener closed (server_stop) or a real accept error -- stop either way
		}
		if !s.running {
			net.close(client) // this was server_stop's own wake-up connection
			break
		}
		conn := new(Connection)
		conn.socket = client
		conn.server = s
		sync.wait_group_add(&s.conns_done, 1)
		thread.create_and_start_with_data(conn, connection_handler, init_context = context, self_cleanup = true)
	}
}
