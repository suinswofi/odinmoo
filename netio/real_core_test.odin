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
LAMBDACORE_PATH :: "/home/consty/LambdaMOO/LambdaCore.db"

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
	testing.expect(t, strings.contains(banner, "Welcome"))

	log_in(t, &client)
}
