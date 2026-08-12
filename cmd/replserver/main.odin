package main

// Manual smoke-test tool for Phase 7: loads a real .db file and serves the netio REPL over
// real TCP, so it can be exercised with an actual telnet/nc client.

import "../../dbfile"
import "../../netio"
import "../../objdb"
import "../../tasks"
import "core:fmt"
import "core:net"
import "core:os"

main :: proc() {
	path := len(os.args) > 1 ? os.args[1] : "/home/consty/LambdaMOO/LambdaCore.db"
	port := 7777

	fmt.printfln("Loading %s ...", path)
	db, lerr := dbfile.load_database(path)
	if lerr.stage != "" {
		fmt.eprintfln("load failed at %s: %v", lerr.stage, lerr.err)
		os.exit(1)
	}
	defer dbfile.database_destroy(&db)
	fmt.printfln("Loaded: %d objects", len(db.objects))

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	s: netio.Server
	err := netio.server_start(&s, port, &sched, &world)
	if err != nil {
		fmt.eprintfln("server_start failed: %v", err)
		os.exit(1)
	}
	endpoint, _ := net.bound_endpoint(s.listener)
	fmt.printfln("Listening on %v -- connect with: telnet localhost %d", endpoint, port)
	fmt.println("Press Enter to stop the server.")

	buf: [1]byte
	os.read(os.stdin, buf[:])
	netio.server_stop(&s)
	fmt.println("Stopped.")
}
