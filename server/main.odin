package server

// Top-level entry point: CLI parsing, startup, signal handling, shutdown, and (`-e`)
// emergency wizard mode -- ported from server.c's main()/main_loop(), re-engineered where
// the original's single-process design doesn't apply (see netio/server.odin and
// checkpoint.odin's headers for the specifics).
//
// CLI stays compatible with the original: `moo [-e] <initial-db> <checkpoint-db> [port]`.

import "../ansi"
import "../builtins"
import "../compiler"
import "../dbfile"
import "../netio"
import "../objdb"
import "../tasks"
import "../values"
import "../vm"
import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:sys/posix"
import "core:time"

DEFAULT_PORT :: 7777

// Signal handlers must do the absolute minimum (POSIX signal-safety rules: no allocation,
// no locking) -- exactly like the original's checkpoint_signal()/shutdown handlers, which
// just set a flag for the main loop to notice. These globals are the Odin equivalent.
@(private = "file")
g_checkpoint_requested: bool
@(private = "file")
g_shutdown_requested: bool

@(private = "file")
on_sigusr2 :: proc "c" (sig: posix.Signal) {
	g_checkpoint_requested = true
}

@(private = "file")
on_shutdown_signal :: proc "c" (sig: posix.Signal) {
	g_shutdown_requested = true
}

// hook_request_shutdown/hook_request_checkpoint back objdb.Server_Hooks (see its header
// comment) with the same flags the signal handlers above set -- so shutdown()/dump_database()
// called from MOO code and SIGINT/SIGUSR2 from the shell both funnel into the one main loop
// below.
@(private = "file")
hook_request_shutdown :: proc(user_data: rawptr, message: string) {
	if len(message) > 0 {
		fmt.printfln("SHUTDOWN: requested from within the database: %s", message)
	}
	g_shutdown_requested = true
}

@(private = "file")
hook_request_checkpoint :: proc(user_data: rawptr) {
	g_checkpoint_requested = true
}

main :: proc() {
	args := os.args[1:]
	emergency := false
	if len(args) > 0 && args[0] == "-e" {
		emergency = true
		args = args[1:]
	}
	if len(args) < 2 {
		fmt.eprintln("usage: moo [-e] <initial-db-file> <checkpoint-db-file> [port]")
		os.exit(1)
	}
	initial_db_path := args[0]
	checkpoint_db_path := args[1]
	port := DEFAULT_PORT
	if len(args) >= 3 {
		if p, ok := strconv.parse_int(args[2], 10); ok {
			port = p
		}
	}

	fmt.printfln("STARTING: LambdaMOO (Odin port), loading %s", initial_db_path)
	db, lerr := dbfile.load_database(initial_db_path)
	if lerr.stage != "" {
		fmt.eprintfln("LOADING: failed at stage %q: %v", lerr.stage, lerr.err)
		os.exit(1)
	}
	defer dbfile.database_destroy(&db)
	fmt.printfln("LOADING: done -- %d objects, %d users", len(db.objects), len(db.users))

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	if emergency {
		run_emergency_mode(&db, &world)
		return
	}

	posix.signal(.SIGINT, on_shutdown_signal)
	posix.signal(.SIGTERM, on_shutdown_signal)
	posix.signal(.SIGUSR2, on_sigusr2)

	s: netio.Server
	// Points notify()/connection_name()/boot_player() (called from anywhere in the running
	// object DB) back at this server's live connection registry -- see netio/login.odin's
	// wire_connection_hooks header comment. Must happen before server_start() so the very
	// first connection's $login:welcome notify() call has somewhere to go.
	netio.wire_connection_hooks(&ow, &s)
	ow.server_ctl = objdb.Server_Hooks{
		request_shutdown   = hook_request_shutdown,
		request_checkpoint = hook_request_checkpoint,
	}
	if err := netio.server_start(&s, port, &sched, &world); err != nil {
		fmt.eprintfln("LISTENING: failed to start on port %d: %v", port, err)
		os.exit(1)
	}
	fmt.printfln("LISTENING on port %d (SIGINT/SIGTERM to shut down cleanly, SIGUSR2 to checkpoint now)", port)

	for !g_shutdown_requested {
		if g_checkpoint_requested {
			g_checkpoint_requested = false
			checkpoint(&db, &sched, checkpoint_db_path)
		}
		time.sleep(200 * time.Millisecond)
	}

	fmt.println("SHUTTING DOWN: signal received")
	netio.server_stop(&s)
	fmt.println("DUMPING: final checkpoint before exit")
	sync.mutex_lock(&sched.big_lock)
	ok := dbfile.save_database(&db, checkpoint_db_path)
	sync.mutex_unlock(&sched.big_lock)
	fmt.printfln("DUMPING: %s", ok ? "done" : "FAILED")
	fmt.println("DONE")
}

// run_emergency_mode ports the `-e` emergency wizard mode: a stdin/stdout REPL for
// recovering a database broken by bad verb code, bypassing the network layer entirely.
// Scope note: the original's emergency mode also supports listing/resetting individual verb
// programs (`list`, `program`, etc.) -- that needs Phase 5 builtins (verb_code/
// set_verb_code) this port doesn't have yet. What's here covers the other half: directly
// evaluating MOO expressions/statements against the loaded DB, which is the actual recovery
// tool (e.g. `#0.some_prop = fixed_value;`) most emergencies need.
@(private = "file")
run_emergency_mode :: proc(db: ^dbfile.Database, world: ^vm.World) {
	print_colored("\n%h%rLambdaMOO Emergency Wizard Mode%n %h%w(Odin port)%n\n")
	print_colored("%rType a MOO expression or statement, or `.quit` to exit and save nothing.%n\n\n")

	reader: bufio.Reader
	buf: [4096]byte
	bufio.reader_init_with_buf(&reader, os.to_reader(os.stdin), buf[:])
	defer bufio.reader_destroy(&reader)

	task_id := 0
	for {
		print_colored("%h%cMOO>%n ")
		line, err := bufio.reader_read_string(&reader, '\n')
		if err != nil {
			break
		}
		defer delete(line)
		trimmed := trim_line(line)
		if trimmed == ".quit" {
			break
		}
		if len(trimmed) == 0 {
			continue
		}
		task_id += 1
		eval_and_print(db, world, trimmed, task_id)
	}
	fmt.println("EMERGENCY_MODE: leaving.")
}

@(private = "file")
trim_line :: proc(s: string) -> string {
	i := len(s)
	for i > 0 && (s[i - 1] == '\n' || s[i - 1] == '\r' || s[i - 1] == ' ' || s[i - 1] == '\t') {
		i -= 1
	}
	return s[:i]
}

@(private = "file")
eval_and_print :: proc(db: ^dbfile.Database, world: ^vm.World, line: string, task_id: int) {
	src := fmt.tprintf("return (%s);", line)
	r := compiler.parse_program(src, db.version)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		for e in r.errors {
			delete(e)
		}
		delete(r.errors)
	}
	if len(r.errors) > 0 {
		print_colored("%rParse error:%n ")
		fmt.println(r.errors[0])
		return
	}

	act := vm.activation_make(len(r.names.names), &r.names)
	defer vm.activation_destroy(&act)
	act.task_id = task_id
	act.debug = true

	result := vm.run(r.body, &r.names, world, &act)
	switch result.signal {
	case .Return:
		defer values.free_var(result.value)
		lit_args := make([]values.Var, 1)
		lit_args[0] = values.var_ref(result.value)
		lit_result, _ := builtins.call("toliteral", values.list_val(lit_args))
		defer values.free_var(lit_result.value)
		print_colored("%h%g=>%n ")
		fmt.println(lit_result.value.data.str.s)
	case .Raised:
		print_colored("%r**%n ")
		fmt.printfln("%s (%s)", compiler.error_name(result.err.code), result.err.msg)
		delete(result.err.msg)
		values.free_var(result.err.value)
	case .Normal, .Break, .Continue:
		print_colored("%h%g=>%n (no value)\n")
	}
}

// print_colored translates %-code markup and writes it directly to stdout -- the emergency
// console is a local terminal, assumed to support ANSI (unlike a network client, which
// might not, hence netio's per-connection toggle instead of an unconditional assumption
// there).
@(private = "file")
print_colored :: proc(s: string) {
	colored := ansi.translate(s, true)
	defer delete(colored)
	fmt.print(colored)
}
