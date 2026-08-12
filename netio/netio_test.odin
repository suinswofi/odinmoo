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
import "core:net"
import "core:strings"
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
	add_verb(&db, sysobj, "do_login_command", 0, int(1 << uint(objdb.Verb_Flag.Exec)), `
		if (callers())
			return E_PERM;
		endif
		if (length(args) == 0)
			notify(player, "%h%cWelcome to the Test MOO. Type 'connect wizard' to log in.%n");
			return 0;
		elseif (length(args) == 2 && args[1] == "connect" && args[2] == "wizard")
			return #1;
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
	send_cmd(c, "connect wizard")
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
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world)
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
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world)
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
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world)
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
		log_in(t, &clients[i])
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
	err := server_start(&s, 0, &sched, &world)
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
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world)
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
	db := build_login_db()
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: Server
	wire_connection_hooks(&ow, &s)
	err := server_start(&s, 0, &sched, &world)
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
