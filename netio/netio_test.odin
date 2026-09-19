package netio

// End-to-end tests: a real TCP client (core:net, exactly what a telnet client would use)
// talking to a real running Server, over the real loopback network stack -- not mocked.
//
// Since the real login protocol landed, every session starts unauthenticated: a fresh
// connection only gets $login:welcome's notify() text (no netio-hardcoded banner), and the
// MOO-expression REPL (handle_line in connection.odin) isn't reachable until a
// `do_login_command` call returns a valid player object. build_login_db() below stands in
// for LambdaCore's #0:do_login_command/#1 "wizard" player, just enough of both to drive that
// flow from a real socket.

import "../dbfile"
import "../objdb"
import "../values"
import "../tasks"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(private = "file")
mkobj :: proc(db: ^dbfile.Database, id, parent, owner: values.Objid, name: string) -> ^dbfile.Object {
	o := new(dbfile.Object)
	o.id = id
	o.parent = parent
	o.owner = owner
	o.name = dbfile.intern_name(&db.name_intern, name)
	o.location = values.NOTHING
	o.contents = values.NOTHING
	o.next = values.NOTHING
	o.child = values.NOTHING
	o.sibling = values.NOTHING
	db.objects[id] = o
	return o
}

@(private = "file")
add_verb :: proc(db: ^dbfile.Database, o: ^dbfile.Object, name: string, owner: values.Objid, perms: int, src: string) {
	append(&o.verbdefs, dbfile.Verbdef{
		name           = dbfile.intern_name(&db.name_intern, name),
		owner          = owner,
		perms          = perms,
		prep           = objdb.PREP_NONE, // "no preposition" -- 0 (the zero value) is a real prep_table index, not none
		program_source = strings.clone(src),
		has_program    = true,
	})
}

// build_login_db builds a two-object DB standing in for LambdaCore's login path: #0's
// do_login_command mirrors $login:do_login_command closely enough for these tests --
// welcome text on no args, `connect wizard` returns the #1 player, anything else fails --
// and #1 is a User-flagged player object, the only thing is_player_object() checks for.
@(private = "file")
build_login_db :: proc() -> dbfile.Database {
	db: dbfile.Database
	db.objects = make(map[values.Objid]^dbfile.Object)
	db.version = dbfile.Current_DB_Version

	sysobj := mkobj(&db, 0, values.NOTHING, 0, "System Object")
	// Owned by #1 (the wizard below), like the real core's wizard-owned $login verbs: the
	// verb's owner is the `programmer` its notify() calls run as, and notify() correctly
	// requires wizard-or-self -- a #0-owned (non-wizard) login verb couldn't greet an
	// unauthenticated (negative-id) connection at all.
	// `connect wizard` is the usual path; `connect extraN` logs in as one of the extra
	// player objects below, so a test that wants several connections at once can give each
	// one its OWN player. Connecting twice as the SAME player is not a way to get two
	// connections -- the server redirects, disconnecting the earlier one, exactly as
	// server.c's player_connected() does.
	add_verb(&db, sysobj, "do_login_command", 1, int(1 << uint(objdb.Verb_Flag.Exec)), `
		if (callers())
			return E_PERM;
		endif
		if (length(args) == 0)
			notify(player, "%h%cWelcome to the Test MOO. Type 'connect wizard' to log in.%n");
			return 0;
		elseif (length(args) == 2 && args[1] == "connect" && args[2] == "wizard")
			return #1;
		elseif (length(args) == 2 && args[1] == "connect" && index(args[2], "extra") == 1)
			n = toint(args[2][6..$]);
			if (n >= 1 && n <= 8)
				return toobj(9 + n);
			endif
			notify(player, "Either that player does not exist, or has a different password.");
			return 0;
		else
			notify(player, "Either that player does not exist, or has a different password.");
			return 0;
		endif
	`)

	wizard := mkobj(&db, 1, values.NOTHING, 1, "Wizard")
	wizard.flags = 1 << uint(objdb.Object_Flag.User) | 1 << uint(objdb.Object_Flag.Wizard) | 1 << uint(objdb.Object_Flag.Programmer)
	// A directly-typeable command (dobj/prep/iobj all "none") on the wizard itself, reachable
	// via ordinary command dispatch -- used to exercise PREFIX/SUFFIX, which only wrap real
	// dispatch_command()-routed commands, not the `.eval` debug hatch.
	add_verb(&db, wizard, "greet", 1, int(1<<uint(objdb.Verb_Flag.Read)) | int(1<<uint(objdb.Verb_Flag.Write)) | int(1<<uint(objdb.Verb_Flag.Exec)), `notify(player, "hello there");`)

	// A small programmable object for `.program` tests: a "widget" with one pre-existing verb
	// ("look"), owned by the wizard, that .program's own permission check (VF_WRITE) accepts.
	widget := mkobj(&db, 2, values.NOTHING, 1, "widget")
	add_verb(&db, widget, "look", 1, int(1<<uint(objdb.Verb_Flag.Read)) | int(1<<uint(objdb.Verb_Flag.Write)) | int(1<<uint(objdb.Verb_Flag.Exec)), `return "before";`)

	// #10..#17: spare players for `connect extra1`..`connect extra8`, so tests that want
	// several simultaneous connections can hold one per player rather than stacking them all
	// onto the wizard (which the server would treat as reconnects and redirect).
	for i in 1 ..= 8 {
		extra := mkobj(&db, values.Objid(9 + i), values.NOTHING, 1, "Extra")
		extra.flags = 1 << uint(objdb.Object_Flag.User) | 1 << uint(objdb.Object_Flag.Wizard) | 1 << uint(objdb.Object_Flag.Programmer)
	}

	return db
}

// Test_Client wraps a raw socket with a small line-buffer -- a single net.recv_tcp() call
// can return anything from a partial line to several lines at once (the server makes
// separate send_line() calls per notify(), and TCP is free to coalesce or split them however
// it likes), so tests need real line-buffering, not "trust one recv() = one line". Shared
// with real_core_test.odin -- not file-private.
Test_Client :: struct {
	sock:    net.TCP_Socket,
	pending: strings.Builder,
}

client_init :: proc(sock: net.TCP_Socket) -> Test_Client {
	return Test_Client{sock = sock, pending = strings.builder_make()}
}

client_destroy :: proc(c: ^Test_Client) {
	strings.builder_destroy(&c.pending)
}

recv_line :: proc(t: ^testing.T, c: ^Test_Client) -> string {
	for {
		buffered := strings.to_string(c.pending)
		if nl := strings.index_byte(buffered, '\n'); nl >= 0 {
			line := strings.trim_right(buffered[:nl], "\r")
			result := strings.clone(line)
			rest := strings.clone(buffered[nl + 1:])
			strings.builder_reset(&c.pending)
			strings.write_string(&c.pending, rest)
			delete(rest)
			return result
		}
		buf: [4096]byte
		n, err := net.recv_tcp(c.sock, buf[:])
		testing.expectf(t, err == nil, "recv error: %v", err)
		if n == 0 {
			result := strings.clone(strings.to_string(c.pending))
			strings.builder_reset(&c.pending)
			return result
		}
		strings.write_bytes(&c.pending, buf[:n])
	}
}

send_cmd :: proc(c: ^Test_Client, text: string) {
	msg := strings.concatenate({text, "\r\n"})
	defer delete(msg)
	net.send_tcp(c.sock, transmute([]byte)msg)
}

// log_in sends "connect wizard" and reads lines until "*** Connected ***" turns up, leaving
// the connection ready for real command dispatch (or `.eval`). Scans forward rather than
// assuming it's the very next line: the welcome banner itself is multiple lines (blank lines
// included) and may not have been fully drained yet by whatever read the banner before
// calling this, and #0:user_connected can itself notify() extra lines before or after the
// literal "*** Connected ***" text. Shared with real_core_test.odin -- not file-private.
log_in :: proc(t: ^testing.T, c: ^Test_Client) {
	log_in_as(t, c, "wizard")
}

// log_in_as is log_in for a named player other than the wizard -- see build_login_db's
// `connect extraN` accounts. Shared with real_core_test.odin -- not file-private.
log_in_as :: proc(t: ^testing.T, c: ^Test_Client, who: string) {
	cmd := strings.concatenate({"connect ", who})
	send_cmd(c, cmd)
	delete(cmd) // not deferred: fail_now below diverges, so a defer here never runs
	for i in 0 ..< 20 {
		line := recv_line(t, c)
		defer delete(line)
		if line == "*** Connected ***" {
			return
		}
	}
	testing.fail_now(t, "never saw \"*** Connected ***\" after connect wizard")
}

@(test)
test_telnet_style_session_evaluates_moo_expressions :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world, net.IP4_Loopback)
	testing.expectf(t, err == nil, "server_start: %v", err)
	defer server_stop(&s)

	endpoint, eerr := net.bound_endpoint(s.listener)
	testing.expectf(t, eerr == nil, "bound_endpoint: %v", eerr)

	sock, derr := net.dial_tcp_from_endpoint(endpoint)
	testing.expectf(t, derr == nil, "dial: %v", derr)
	defer net.close(sock)
	client := client_init(sock)
	defer client_destroy(&client)

	banner := recv_line(t, &client)
	defer delete(banner)
	testing.expect(t, strings.contains(banner, "Welcome"))

	log_in(t, &client)

	send_cmd(&client, ".eval 1 + 2 * 3")
	r1 := recv_line(t, &client)
	defer delete(r1)
	testing.expect(t, r1 == "7")

	send_cmd(&client, `.eval "hello" + " " + "world"`)
	r2 := recv_line(t, &client)
	defer delete(r2)
	testing.expect(t, r2 == `"hello world"`)

	send_cmd(&client, ".eval 1 / 0")
	r3 := recv_line(t, &client)
	defer delete(r3)
	testing.expect(t, strings.contains(r3, "E_DIV"))
}

@(test)
test_ansi_color_default_on_and_toggle :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world, net.IP4_Loopback)
	testing.expectf(t, err == nil, "server_start: %v", err)
	defer server_stop(&s)

	endpoint, _ := net.bound_endpoint(s.listener)
	sock, derr := net.dial_tcp_from_endpoint(endpoint)
	testing.expectf(t, derr == nil, "dial: %v", derr)
	defer net.close(sock)
	client := client_init(sock)
	defer client_destroy(&client)

	// Color is on by default -- the welcome text (which uses %h%c...%n markup) should
	// contain real ANSI escapes, not the literal %-codes.
	banner := recv_line(t, &client)
	defer delete(banner)
	testing.expect(t, strings.contains(banner, "\x1b["))
	testing.expect(t, !strings.contains(banner, "%h"))
	testing.expect(t, !strings.contains(banner, "%c"))

	log_in(t, &client)

	// Toggle off: subsequent output should be plain text, no escapes at all.
	send_cmd(&client, ".ansi off")
	ack := recv_line(t, &client)
	defer delete(ack)
	testing.expect(t, ack == "ANSI color disabled.")

	send_cmd(&client, ".eval 1 / 0")
	plain_err := recv_line(t, &client)
	defer delete(plain_err)
	testing.expect(t, !strings.contains(plain_err, "\x1b["))
	testing.expect(t, strings.contains(plain_err, "E_DIV"))

	// Toggle back on: markup becomes real escapes again.
	send_cmd(&client, ".ansi on")
	ack2 := recv_line(t, &client)
	defer delete(ack2)
	testing.expect(t, strings.contains(ack2, "\x1b["))
}

@(test)
test_multiple_concurrent_connections :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world, net.IP4_Loopback)
	testing.expectf(t, err == nil, "server_start: %v", err)
	defer server_stop(&s)

	endpoint, _ := net.bound_endpoint(s.listener)

	N :: 5
	clients: [N]Test_Client
	for i in 0 ..< N {
		c, derr := net.dial_tcp_from_endpoint(endpoint)
		testing.expectf(t, derr == nil, "dial %d: %v", i, derr)
		clients[i] = client_init(c)
		banner := recv_line(t, &clients[i])
		delete(banner)
		// One player per connection: connecting twice as the same player is a reconnect,
		// which redirects (and disconnects) the earlier connection rather than giving you
		// two live ones. This test is about per-connection independence, not about that.
		who := fmt.tprintf("extra%d", i + 1)
		log_in_as(t, &clients[i], who)
	}
	defer for &c in clients {
		net.close(c.sock)
		client_destroy(&c)
	}

	// Every connection has its own thread -- these all execute independently. Verify each
	// gets the right answer for a distinct computation, not cross-talk between connections.
	for i in 0 ..< N {
		send_cmd(&clients[i], ".eval 2 ^ 10")
		r := recv_line(t, &clients[i])
		defer delete(r)
		testing.expectf(t, r == "1024", "connection %d: expected 1024, got %s", i, r)
	}
}

@(test)
test_server_stop_closes_listener :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	db: dbfile.Database
	db.objects = make(map[values.Objid]^dbfile.Object)
	db.version = dbfile.Current_DB_Version
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	err := server_start(&s, 0, &sched, &world, net.IP4_Loopback)
	testing.expectf(t, err == nil, "server_start: %v", err)

	endpoint, _ := net.bound_endpoint(s.listener)
	server_stop(&s)

	// A dial after stop should fail (nothing listening anymore) -- give the OS a moment to
	// actually tear the socket down.
	time.sleep(10 * time.Millisecond)
	_, derr := net.dial_tcp_from_endpoint(endpoint)
	testing.expect(t, derr != nil)
}

@(test)
test_program_intrinsic_command_edits_a_real_verb :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world, net.IP4_Loopback)
	testing.expectf(t, err == nil, "server_start: %v", err)
	defer server_stop(&s)

	endpoint, _ := net.bound_endpoint(s.listener)
	sock, derr := net.dial_tcp_from_endpoint(endpoint)
	testing.expectf(t, derr == nil, "dial: %v", derr)
	defer net.close(sock)
	client := client_init(sock)
	defer client_destroy(&client)

	banner := recv_line(t, &client)
	defer delete(banner)
	log_in(t, &client)

	// By object number: `widget` isn't placed anywhere in the player's environment (no
	// location/inventory in this minimal fixture), so name-matching wouldn't find it --
	// exactly why `.program` (like most MOO object-spec syntax) also accepts `#N` directly.
	send_cmd(&client, ".program #2:look")
	confirm := recv_line(t, &client)
	defer delete(confirm)
	testing.expect(t, confirm == `Now programming widget (#2):look.  Use "." to end.`)

	// The verb's EXISTING source is echoed back next (raw, uncolored) before capture starts.
	existing := recv_line(t, &client)
	defer delete(existing)
	testing.expect(t, strings.contains(existing, "before"))

	send_cmd(&client, `return "|15after|07";`)
	send_cmd(&client, ".")
	errcount := recv_line(t, &client)
	defer delete(errcount)
	testing.expect(t, errcount == "0 error(s).")
	installed := recv_line(t, &client)
	defer delete(installed)
	testing.expect(t, installed == "Verb programmed.")

	// Confirm the NEW body actually took effect, and that the pipe codes inside the string
	// literal survived being typed through the raw-capture editor unmangled -- checked via
	// length(), not the string's displayed form, since .eval's OWN result display legitimately
	// goes through the normal translated send_line path (it's showing a live expression
	// result, not stored source) and would otherwise turn |15/|07 into real color escapes
	// here too, same as any other command output -- correct for .eval, and exactly why this
	// checks the underlying stored value instead. A mangled storage round-trip (the pipe
	// codes silently eaten, as they would be had capture gone through send_line/
	// ansi.translate instead of send_line_raw) would show up as the wrong length: `|15after|07`
	// is 11 characters; losing either pipe code would leave 8.
	send_cmd(&client, ".eval length(#2:look())")
	length_result := recv_line(t, &client)
	defer delete(length_result)
	testing.expect(t, length_result == "11")
}

@(test)
test_prefix_suffix_wrap_command_output :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world, net.IP4_Loopback)
	testing.expectf(t, err == nil, "server_start: %v", err)
	defer server_stop(&s)

	endpoint, _ := net.bound_endpoint(s.listener)
	sock, derr := net.dial_tcp_from_endpoint(endpoint)
	testing.expectf(t, derr == nil, "dial: %v", derr)
	defer net.close(sock)
	client := client_init(sock)
	defer client_destroy(&client)

	banner := recv_line(t, &client)
	defer delete(banner)
	log_in(t, &client)

	send_cmd(&client, "PREFIX >>>")
	send_cmd(&client, "SUFFIX <<<")
	send_cmd(&client, "greet")
	before := recv_line(t, &client)
	defer delete(before)
	testing.expect(t, before == ">>>")
	middle := recv_line(t, &client)
	defer delete(middle)
	testing.expect(t, middle == "hello there")
	after := recv_line(t, &client)
	defer delete(after)
	testing.expect(t, after == "<<<")

	// output_delimiters() reports back what was set.
	send_cmd(&client, ".eval output_delimiters(player)")
	delims := recv_line(t, &client)
	defer delete(delims)
	testing.expect(t, delims == `{">>>", "<<<"}`)

	// Clearing with an empty argument turns delimiters back off.
	send_cmd(&client, "PREFIX")
	send_cmd(&client, "SUFFIX")
	send_cmd(&client, "greet")
	only := recv_line(t, &client)
	defer delete(only)
	testing.expect(t, only == "hello there")
}

// test_force_input_drains_after_hold_cleared exercises the queued-input path end to end, which
// the objdb-side tests can't: they stand in a fake for Connection_Hooks, so they never touch the
// real queue, the drain thread, or the interaction between them. Sequence: hold input, inject two
// lines with force_input(), then clear the hold -- which has to hand both queued lines to ordinary
// command dispatch, in order, on a thread that isn't the one holding the interpreter lock.
@(test)
test_force_input_drains_after_hold_cleared :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world, net.IP4_Loopback)
	testing.expectf(t, err == nil, "server_start: %v", err)
	defer server_stop(&s)

	endpoint, _ := net.bound_endpoint(s.listener)
	sock, derr := net.dial_tcp_from_endpoint(endpoint)
	testing.expectf(t, derr == nil, "dial: %v", derr)
	defer net.close(sock)
	client := client_init(sock)
	defer client_destroy(&client)

	banner := recv_line(t, &client)
	defer delete(banner)
	log_in(t, &client)

	// All in one expression on purpose: while "hold-input" is set, the connection queues
	// EVERYTHING it reads -- including whatever the test types next -- so this can't be split
	// across several lines. Sets the hold, queues two lines behind it, then clears the hold,
	// which is what has to kick off the drain.
	send_cmd(&client, `.eval {set_connection_option(player, "hold-input", 1), force_input(player, "greet"), force_input(player, "greet"), set_connection_option(player, "hold-input", 0)}`)

	// Both queued "greet" commands now run, each notify()ing once. Scanning rather than
	// expecting an exact next line: the .eval result and the drained output are produced by two
	// different threads, so their order isn't guaranteed.
	greeted := 0
	for _ in 0 ..< 6 {
		line := recv_line(t, &client)
		defer delete(line)
		if line == "hello there" {
			greeted += 1
			if greeted == 2 {
				break
			}
		}
	}
	testing.expectf(t, greeted == 2, "expected both queued lines to dispatch, saw %d", greeted)
}

// test_connection_churn_under_concurrent_hooks hammers the connection LIFECYCLE rather than
// any one feature: clients connect, log in and drop abruptly in a loop, while the test thread
// concurrently drives every Connection_Hooks entry point -- notify, connection_name,
// connected_seconds, force_input, set/connection_option, output_delimiters and boot_player --
// at those same connections, plus reconnects that displace a still-open session.
//
// Every one of those hooks reaches a ^Connection through Server.players, and a connection
// being torn down on its own thread is exactly what they race. This is the test for the
// lifetime contract documented in login.odin: unregister-then-free on the owning side,
// look-up-and-use-entirely-under-players_lock on every other side. Run it under
// `-sanitize:thread` or `-sanitize:address` for it to say much beyond "didn't hang or crash":
// plain, it still catches a double close (the booted connection's descriptor being handed to
// a new connection and torn down under it) as cross-talk or a lost session.
@(private = "file")
Churn_Args :: struct {
	t:        ^testing.T,
	endpoint: net.Endpoint,
	player:   int, // which `connect extraN` account this worker owns
	rounds:   int,
	done:     ^sync.Wait_Group,
}

@(private = "file")
churn_worker :: proc(data: rawptr) {
	a := (^Churn_Args)(data)
	done := a.done
	who := fmt.aprintf("extra%d", a.player)
	cmd := strings.concatenate({"connect ", who})
	for round in 0 ..< a.rounds {
		sock, derr := net.dial_tcp_from_endpoint(a.endpoint)
		if derr != nil {
			continue // the server is stopping, or the OS is out of ephemeral ports
		}
		net.send_tcp(sock, transmute([]byte)cmd)
		net.send_tcp(sock, transmute([]byte)string("\r\n"))
		// Read a little (or nothing at all, on alternate rounds) and then drop mid-stream,
		// leaving buffered output undelivered -- the disconnect shape that actually races
		// teardown, as opposed to a polite drain-then-close.
		if round % 2 == 0 {
			buf: [256]byte
			net.recv_tcp(sock, buf[:])
		}
		net.send_tcp(sock, transmute([]byte)string(".eval 1 + 1\r\n"))
		net.close(sock)
	}
	delete(cmd)
	delete(who)
	free(a)
	sync.wait_group_done(done) // after the last free -- see spawn_worker's comment
}

@(test)
test_connection_churn_under_concurrent_hooks :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world, net.IP4_Loopback)
	testing.expectf(t, err == nil, "server_start: %v", err)
	defer server_stop(&s)

	endpoint, _ := net.bound_endpoint(s.listener)

	WORKERS :: 6
	ROUNDS :: 12
	churn_done: sync.Wait_Group
	sync.wait_group_add(&churn_done, WORKERS)
	for i in 1 ..= WORKERS {
		a := new(Churn_Args)
		a.t = t
		a.endpoint = endpoint
		a.player = i
		a.rounds = ROUNDS
		a.done = &churn_done
		tasks.spawn_worker(a, churn_worker)
	}

	// Meanwhile, drive the hooks at those same players from this thread. Return values are
	// deliberately unasserted: whether a given player is connected at a given instant is a
	// race by construction, and that IS the point -- what is being checked is that every
	// outcome is a clean found/not-found rather than a read of freed memory.
	for _ in 0 ..< 400 {
		for i in 1 ..= WORKERS {
			player := values.Objid(9 + i)
			ow.conn.notify(ow.conn.user_data, player, "%h%gping%n")
			ow.conn.notify_raw(ow.conn.user_data, player, "raw ping")
			if name, ok := ow.conn.connection_name(ow.conn.user_data, player); ok {
				delete(name)
			}
			ow.conn.connected_seconds(ow.conn.user_data, player)
			ow.conn.force_input(ow.conn.user_data, player, "look", false)
			ow.conn.flush_input(ow.conn.user_data, player, false)
			if v, ok := ow.conn.connection_option(ow.conn.user_data, player, "hold-input"); ok {
				values.free_var(v)
			}
			hold := values.int_val(1)
			ow.conn.set_connection_option(ow.conn.user_data, player, "hold-input", hold)
			values.free_var(hold)
			if opts, ok := ow.conn.connection_options(ow.conn.user_data, player); ok {
				values.free_var(opts)
			}
			if p, sfx, ok := ow.conn.output_delimiters(ow.conn.user_data, player); ok {
				delete(p)
				delete(sfx)
			}
			// Boot a fraction of them: this is the path that used to close a descriptor the
			// connection's own thread would then close a second time.
			if i % 3 == 0 {
			ow.conn.boot_player(ow.conn.user_data, player)
			}
		}
		ids := ow.conn.connected_players(ow.conn.user_data, true)
		delete(ids)
	}

	sync.wait_group_wait(&churn_done)

	// The server survived all of that: a fresh session still logs in and dispatches. (Had a
	// double close handed a live descriptor to someone else, this is where it shows up.)
	sock, derr := net.dial_tcp_from_endpoint(endpoint)
	testing.expectf(t, derr == nil, "dial after churn: %v", derr)
	defer net.close(sock)
	client := client_init(sock)
	defer client_destroy(&client)
	banner := recv_line(t, &client)
	delete(banner)
	log_in(t, &client)
	send_cmd(&client, ".eval 2 + 2")
	r := recv_line(t, &client)
	defer delete(r)
	testing.expectf(t, r == "4", "server unusable after churn: got %q", r)
}

// ---- thread-safe test allocator ----
//
// Every test in this package starts real server threads (accept loop, one per connection,
// output writers, input drains, forked MOO tasks) and each of those inherits the calling
// test's `context`, allocator included. Under `odin test` that allocator is a per-test
// Tracking_Allocator over a Rollback_Stack -- neither of which is thread-safe -- so those
// threads and the test body allocate from one non-thread-safe allocator at once. That is not
// a theoretical hazard: it hands the same block out twice, and it showed up as a
// ThreadSanitizer report inside rollback_stack_allocator and as roughly one-in-five spurious
// netio failures.
//
// The threads cannot simply be given a different allocator: they and the test body share
// ownership of the same values (a connection thread allocates a Var that database_destroy
// later frees on the test thread), so they must all use ONE allocator -- it just has to be a
// thread-safe one. In production it already is (the plain heap allocator); this makes it so
// under the test runner too, while keeping the tracking allocator's leak reporting intact.
//
// Usage, as the first two lines of a test:
//
//	mu: mem.Mutex_Allocator
//	context.allocator = thread_safe_allocator(&mu)
//
// `mu` lives on the test's stack, so every spawned thread must be joined before the test
// returns -- which they all are (server_stop waits for connection threads,
// scheduler_destroy for forks).
// Package-private, not file-private: real_core_test.odin's tests need it too.
@(private)
thread_safe_allocator :: proc(mu: ^mem.Mutex_Allocator) -> mem.Allocator {
	mem.mutex_allocator_init(mu, context.allocator)
	return mem.mutex_allocator(mu)
}

// MAX_QUEUED_INPUT and the `overlong` state machine in connection_read_loop had no test at all,
// and they are the one piece of new state an UNAUTHENTICATED peer can drive: a client that
// never sends a newline used to grow a connection's buffer until the process ran out of memory.
// This drives it over the socket, the way a real client would.
@(test)
test_overlong_input_line_is_discarded_and_connection_survives :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world, net.IP4_Loopback)
	testing.expectf(t, err == nil, "server_start: %v", err)
	defer server_stop(&s)

	endpoint, eerr := net.bound_endpoint(s.listener)
	testing.expectf(t, eerr == nil, "bound_endpoint: %v", eerr)
	sock, derr := net.dial_tcp_from_endpoint(endpoint)
	testing.expectf(t, derr == nil, "dial: %v", derr)
	defer net.close(sock)
	client := client_init(sock)
	defer client_destroy(&client)

	banner := recv_line(t, &client)
	defer delete(banner)
	log_in(t, &client)

	// Well past the cap, with no newline anywhere in it -- the shape that was unbounded.
	blob := strings.repeat("A", MAX_QUEUED_INPUT + 4096)
	defer delete(blob)
	net.send_tcp(client.sock, transmute([]byte)blob)
	send_cmd(&client, "") // the newline that terminates the over-long line

	notice := recv_line(t, &client)
	defer delete(notice)
	// Specifically the READ-LOOP notice. The queue-side cap in input_queue.odin has its own,
	// deliberately different, wording -- asserting on a substring common to both would let this
	// test pass with the read-loop limit removed entirely, which is exactly what it did before
	// the two were given distinct text.
	testing.expectf(t, strings.contains(notice, "Line too long"), "expected the read-loop over-long notice, got %q", notice)

	// The connection must resynchronize on the next line rather than being poisoned or dropped.
	send_cmd(&client, ".eval 6 * 7")
	after := recv_line(t, &client)
	defer delete(after)
	testing.expectf(t, after == "42", "connection unusable after an over-long line: got %q", after)
}

// A line at exactly the cap is accepted -- the limit must not be off by one in the strict
// direction, or a legitimate long command would be refused.
@(test)
test_input_line_at_the_limit_is_accepted :: proc(t: ^testing.T) {
	mu: mem.Mutex_Allocator
	context.allocator = thread_safe_allocator(&mu)
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world, net.IP4_Loopback)
	testing.expectf(t, err == nil, "server_start: %v", err)
	defer server_stop(&s)

	endpoint, _ := net.bound_endpoint(s.listener)
	sock, derr := net.dial_tcp_from_endpoint(endpoint)
	testing.expectf(t, derr == nil, "dial: %v", derr)
	defer net.close(sock)
	client := client_init(sock)
	defer client_destroy(&client)
	banner := recv_line(t, &client)
	defer delete(banner)
	log_in(t, &client)

	// `.eval "AAA..."` padded so the whole line is exactly MAX_QUEUED_INPUT bytes, LF-terminated.
	prefix :: `.eval "`
	pad := strings.repeat("A", MAX_QUEUED_INPUT - len(prefix) - 1)
	defer delete(pad)
	line := strings.concatenate({prefix, pad, `"`})
	defer delete(line)
	testing.expect(t, len(line) == MAX_QUEUED_INPUT)
	net.send_tcp(client.sock, transmute([]byte)line)
	net.send_tcp(client.sock, transmute([]byte)string("\n"))

	echoed := recv_line(t, &client)
	defer delete(echoed)
	testing.expectf(t, !strings.contains(echoed, "too long"), "a line at exactly the cap was rejected: %q", echoed)
	testing.expectf(t, len(echoed) >= MAX_QUEUED_INPUT - len(prefix) - 1, "unexpected reply of length %d: %q", len(echoed), echoed)
}
