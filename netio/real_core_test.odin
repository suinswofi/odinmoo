package netio

// Diagnostic/regression coverage against the actual shipped LambdaCore.db (not a synthetic
// stand-in) -- exercises the real #0:do_login_command over a real socket, all the way through
// $login's own verb graph, which build_login_db() in netio_test.odin deliberately doesn't
// attempt to model. This is the same flow a telnet client drives; it's what caught the
// bf_index double-free (see builtins/list_str.odin) that a synthetic single-verb DB never
// would have exercised.

import "../dbfile"
import "../objdb"
import "../tasks"
import "../values"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"

@(private = "file")
LAMBDACORE_PATH :: "LambdaCore.db"

@(test)
test_real_lambdacore_login :: proc(t: ^testing.T) {
	db, lerr := dbfile.load_database(LAMBDACORE_PATH)
	if lerr.stage != "" {
		fmt.printfln("skipping test_real_lambdacore_login: could not load %s: stage=%s err=%v", LAMBDACORE_PATH, lerr.stage, lerr.err)
		return
	}
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
	testing.expect(t, strings.contains(banner, "Welcome"))

	log_in(t, &client)
}

// A command nothing matches must reach the DATABASE's huh handler ($root_class:huh ->
// $command_utils:do_huh, whose message is "I don't understand that."), not the server's own
// "I couldn't understand that." fallback -- tasks.c finds `huh` with db_find_callable_verb,
// arg specs ignored, and LambdaCore's huh is `this none this`.
@(test)
test_real_lambdacore_unknown_command_reaches_db_huh :: proc(t: ^testing.T) {
	db, lerr := dbfile.load_database(LAMBDACORE_PATH)
	if lerr.stage != "" {
		fmt.printfln("skipping: could not load %s: stage=%s err=%v", LAMBDACORE_PATH, lerr.stage, lerr.err)
		return
	}
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
	delete(banner)
	log_in(t, &client)

	// The post-login room description etc. precedes the reply; scan past it.
	send_cmd(&client, "xyzzyplugh")
	saw_db_huh, saw_fallback := false, false
	for i in 0 ..< 40 {
		line := recv_line(t, &client)
		defer delete(line)
		if strings.contains(line, "couldn't understand") {
			saw_fallback = true
			break
		}
		if strings.contains(line, "I don't understand that") {
			saw_db_huh = true
			break
		}
	}
	testing.expect(t, !saw_fallback, "server fallback fired instead of the database's huh verb")
	testing.expect(t, saw_db_huh, "never saw $command_utils:do_huh's \"I don't understand that.\"")
}
