package server

// Top-level entry point: CLI parsing, startup, signal handling, shutdown, and (`-e`)
// emergency wizard mode -- ported from server.c's main()/main_loop(), re-engineered where
// the original's single-process design doesn't apply (see netio/server.odin and
// checkpoint.odin's headers for the specifics).
//
// CLI stays compatible with the original: `moo [-e] <initial-db> <checkpoint-db> [port]`.

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
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

DEFAULT_PORT :: 7777

// Signal handlers must do the absolute minimum (POSIX signal-safety rules: no allocation,
// no locking) -- exactly like the original's checkpoint_signal()/shutdown handlers, which
// just set a flag for the main loop to notice. These globals are the Odin equivalent.
//
// Accessed with sync.atomic_* rather than as plain bools. Two different kinds of writer reach
// them: a signal handler, which can interrupt the main loop between any two instructions, and
// -- via the Server_Hooks below -- MOO code calling shutdown()/dump_database() on some task's
// own thread. Plain loads and stores across threads are a data race, and a compiler is within
// its rights to hoist the `for !g_shutdown_requested` test out of the loop entirely, in which
// case the server simply never notices the request.
@(private = "file")
g_checkpoint_requested: bool
@(private = "file")
g_shutdown_requested: bool

// g_shutdown_message is the text broadcast as "*** Shutting down: <it> ***" (the original's
// shutdown_message): "shutdown signal received" for a signal, shutdown()'s own text otherwise.
// Written by the shutdown() hook (under big_lock) before the flag is raised; read by the main
// loop after it sees the flag.
@(private = "file")
g_shutdown_message: string

// The size db_disk_size() reports: the byte count of the database's most recent full on-disk
// representation. This ports db_file.c's db_disk_size(), which stats input_db_name while
// dump_generation is 0 and dump_db_name once it isn't -- before any checkpoint, the most recent
// full representation IS the file we loaded.
//
// Kept as a cached COUNT rather than a path to stat on demand, for two reasons. db_disk_size()
// is dispatched from a MOO task, which holds big_lock: a filesystem syscall there stalls every
// other task in the server, on a slow or networked filesystem indefinitely. And the obvious
// implementation (os.stat into context.temp_allocator) leaked, because the threads that run MOO
// tasks -- forked tasks and connection drain workers -- only reclaim that arena when the thread
// EXITS, and a forked housekeeping daemon never exits. The server already knows every number it
// needs: the initial file is stat'd once at startup before any thread exists, and a checkpoint's
// size is just the length of the buffer it wrote.
//
// Updated only after a write SUCCEEDS, which differs slightly from the original's
// dump_generation (bumped when the dump starts). The original can name a file its forked child
// has not finished writing, and stat() then reports a partial size or fails; waiting for success
// means this always reports a file that is really there, and reports the loaded database in the
// meantime rather than an error. Read and written atomically -- the writer is a background
// thread, the reader is any MOO task's thread.
@(private = "file")
g_db_disk_size: i64

@(private = "file")
on_sigusr2 :: proc "c" (sig: posix.Signal) {
	sync.atomic_store(&g_checkpoint_requested, true)
}

@(private = "file")
on_shutdown_signal :: proc "c" (sig: posix.Signal) {
	sync.atomic_store(&g_shutdown_requested, true)
}

// hook_request_shutdown/hook_request_checkpoint back objdb.Server_Hooks (see its header
// comment) with the same flags the signal handlers above set -- so shutdown()/dump_database()
// called from MOO code and SIGINT/SIGUSR2 from the shell both funnel into the one main loop
// below.
@(private = "file")
hook_request_shutdown :: proc(user_data: rawptr, message: string) {
	if g_shutdown_message == "" {
		g_shutdown_message = strings.clone(message)
	}
	sync.atomic_store(&g_shutdown_requested, true)
}

@(private = "file")
hook_request_checkpoint :: proc(user_data: rawptr) {
	sync.atomic_store(&g_checkpoint_requested, true)
}

// note_db_written records the size of a database representation that has just landed on disk.
// Called by checkpoint.odin's writer thread on success, and by main() for the file it loaded.
note_db_written :: proc(size: i64) {
	sync.atomic_store(&g_db_disk_size, size)
}

// hook_db_disk_size backs objdb.Server_Hooks.db_disk_size -- see g_db_disk_size above for what
// it measures and why it is a cached count. Zero means nothing has successfully landed on disk
// (the initial stat failed), which the built-in turns into E_QUOTA exactly as the original does.
@(private = "file")
hook_db_disk_size :: proc(user_data: rawptr) -> (size: i64, ok: bool) {
	n := sync.atomic_load(&g_db_disk_size)
	if n <= 0 {
		return 0, false
	}
	return n, true
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

	// The database's on-disk representation is the file we just loaded, until a checkpoint
	// replaces it. Stat'd once, here, before any other thread exists -- see g_db_disk_size.
	if fi, serr := os.stat(initial_db_path, context.temp_allocator); serr == nil {
		note_db_written(fi.size)
	}

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	if emergency {
		// server.c's main(): `if (!emergency || emergency_mode())` start the server; either
		// way db_shutdown() then writes the database out.
		sync.mutex_lock(&sched.big_lock)
		objdb.load_server_options(&ow)
		start := run_emergency_mode(&db, &ow, &world)
		sync.mutex_unlock(&sched.big_lock)
		if !start {
			tasks.scheduler_shutdown(&sched)
			sync.mutex_lock(&sched.big_lock)
			data := dbfile.save_database_bytes(&db)
			sync.mutex_unlock(&sched.big_lock)
			ok := write_db_file(checkpoint_db_path, data) == nil
			delete(data)
			fmt.printfln("DUMPING: %s", ok ? "done" : "FAILED")
			return
		}
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
		db_disk_size       = hook_db_disk_size,
	}

	// server.c's main(): load_server_options() before anything runs.
	sync.mutex_lock(&sched.big_lock)
	objdb.load_server_options(&ow)
	sync.mutex_unlock(&sched.big_lock)

	if err := netio.server_start(&s, port, &sched, &world); err != nil {
		fmt.eprintfln("LISTENING: failed to start on port %d: %v", port, err)
		os.exit(1)
	}
	fmt.printfln("LISTENING on port %d (SIGINT/SIGTERM to shut down cleanly, SIGUSR2 to checkpoint now)", port)

	// main_loop()'s preamble: the connections the database recorded as open when it was last
	// dumped are gone now, so #0:user_disconnected hears about each of them; then
	// #0:server_started runs.
	sync.mutex_lock(&sched.big_lock)
	for c in db.connections {
		args := make([]values.Var, 1)
		args[0] = values.obj_val(c.who)
		v, _ := objdb.run_root_verb(&ow, &world, objdb.Root_Call{
			player = c.who, this = c.listener, verb = "user_disconnected", args = values.list_val(args),
		})
		values.free_var(v)
	}
	clear(&db.connections)
	{
		v, _ := objdb.run_root_verb(&ow, &world, objdb.Root_Call{
			player = values.NOTHING, this = values.SYSTEM_OBJECT, verb = "server_started", args = values.empty_list(),
		})
		values.free_var(v)
	}
	sync.mutex_unlock(&sched.big_lock)

	next_checkpoint := time.time_add(time.now(), dump_interval(&ow, &sched))
	last_sweep := time.now()
	for !sync.atomic_load(&g_shutdown_requested) {
		if time.diff(next_checkpoint, time.now()) >= 0 {
			fmt.println("CHECKPOINTING on schedule ($dump_interval)")
			sync.atomic_store(&g_checkpoint_requested, true)
		}
		if sync.atomic_exchange(&g_checkpoint_requested, false) {
			run_checkpoint(&db, &ow, &world, &sched, &s, checkpoint_db_path)
			next_checkpoint = time.time_add(time.now(), dump_interval(&ow, &sched))
			// Scratch memory used while writing a checkpoint isn't needed afterwards, and
			// context.temp_allocator is a growing arena that's only ever reclaimed explicitly
			// (see netio/connection.odin's per-line reset for the same reasoning).
			free_all(context.temp_allocator)
		}
		if result, finished := checkpoint_take_result(); finished {
			// call_checkpoint_notifier: #0:checkpoint_finished(success) once the write is done.
			args := make([]values.Var, 1)
			args[0] = values.int_val(result ? 1 : 0)
			sync.mutex_lock(&sched.big_lock)
			v, _ := objdb.run_root_verb(&ow, &world, objdb.Root_Call{
				player = values.NOTHING, this = values.SYSTEM_OBJECT, verb = "checkpoint_finished", args = values.list_val(args),
			})
			sync.mutex_unlock(&sched.big_lock)
			values.free_var(v)
		}
		if time.diff(last_sweep, time.now()) >= time.Second {
			netio.sweep_connections(&s)
			last_sweep = time.now()
		}
		time.sleep(200 * time.Millisecond)
	}

	message := g_shutdown_message != "" ? g_shutdown_message : "shutdown signal received"
	fmt.printfln("SHUTDOWN: %s", message)
	// send_shutdown_message, to every connection, before they're closed.
	broadcast := fmt.tprintf("*** Shutting down: %s ***", message)
	netio.broadcast_raw(&s, broadcast)
	// The final dump records the connections that are open right now, as the original's does,
	// so that the next startup can tell the database they were dropped.
	final_connections := netio.live_connections(&s)
	defer delete(final_connections)
	// Before server_stop: a disconnect notifier parked in suspend() would otherwise hold up its
	// connection's teardown, which server_stop waits for. See scheduler_begin_shutdown.
	tasks.scheduler_begin_shutdown(&sched)
	netio.server_stop(&s)
	// Stop the network first (no new commands), THEN quiesce the tasks already running, and
	// only then dump. Forked tasks are ordinary threads executing verb code against the
	// object DB; letting them run on while main() dumps and then frees the database is a
	// use-after-free, and dumping mid-mutation would record a half-applied change.
	fmt.println("SHUTTING DOWN: waiting for running tasks")
	tasks.scheduler_shutdown(&sched)
	fmt.println("DUMPING: final checkpoint before exit")
	checkpoint_wait() // let any in-flight background checkpoint write finish first
	sync.mutex_lock(&sched.big_lock)
	clear(&db.connections)
	append(&db.connections, ..final_connections)
	final_data := dbfile.save_database_bytes(&db)
	sync.mutex_unlock(&sched.big_lock)
	ok := write_db_file(checkpoint_db_path, final_data) == nil
	delete(final_data)
	fmt.printfln("DUMPING: %s", ok ? "done" : "FAILED")
	fmt.println("DONE")
}

// dump_interval ports set_checkpoint_timer(): #0.dump_interval seconds between checkpoints if
// it is an integer of at least 60, otherwise an hour.
@(private = "file")
dump_interval :: proc(ow: ^objdb.Object_World, sched: ^tasks.Scheduler) -> time.Duration {
	sync.mutex_lock(&sched.big_lock)
	defer sync.mutex_unlock(&sched.big_lock)
	interval := 3600
	if h := objdb.find_property(ow.db, values.SYSTEM_OBJECT, "dump_interval"); objdb.valid(ow.db, values.SYSTEM_OBJECT) && h.found {
		v := objdb.property_value(ow.db, values.SYSTEM_OBJECT, h)
		if v.type == .Int && v.data.num >= 60 {
			interval = int(v.data.num)
		}
		values.free_var(v)
	}
	return time.Duration(interval) * time.Second
}

// run_checkpoint is main_loop's checkpoint step: #0:checkpoint_started, then the dump (the
// live connections recorded in it), whose completion is reported to #0:checkpoint_finished by
// the main loop once the background write is done.
@(private = "file")
run_checkpoint :: proc(db: ^dbfile.Database, ow: ^objdb.Object_World, world: ^vm.World, sched: ^tasks.Scheduler, s: ^netio.Server, path: string) {
	sync.mutex_lock(&sched.big_lock)
	v, _ := objdb.run_root_verb(ow, world, objdb.Root_Call{
		player = values.NOTHING, this = values.SYSTEM_OBJECT, verb = "checkpoint_started", args = values.empty_list(),
	})
	values.free_var(v)
	sync.mutex_unlock(&sched.big_lock)

	conns := netio.live_connections(s)
	defer delete(conns)
	checkpoint(db, sched, path, conns)
}

// run_emergency_mode ports server.c's emergency_mode(): a stdin/stdout console, before the
// network starts, for repairing a database that verb code has broken. Commands:
//
//	;EXPR              evaluate a MOO expression and print the result
//	;;CODE             run MOO statements and print the result
//	                   (with nothing after the `;`/`;;`, read lines up to a lone `.`)
//	program OBJ:VERB   replace a verb's code with the following lines, up to a lone `.`
//	list OBJ:VERB      print a verb's code
//	debug              toggle evaluating with the `d` flag
//	wizard #N          run future commands as wizard #N
//	continue           leave emergency mode and start the server
//	quit               leave and exit, saving the database
//	abort              exit WITHOUT saving
//	help, ?            this list
//
// Everything runs as a wizard (the first one in the database, unless `wizard` picks another);
// notify() output is printed as `#N <- text`. End of input counts as `quit`. The return value
// says whether to continue starting the server.
@(private = "file")
run_emergency_mode :: proc(db: ^dbfile.Database, ow: ^objdb.Object_World, world: ^vm.World) -> (start_server: bool) {
	fmt.println("\nLambdaMOO Emergency Holographic Wizard Mode")
	fmt.println("-------------------------------------------")
	fmt.println("\"Please state the nature of the wizardly emergency...\"")
	fmt.println("(Type `help' for assistance.)\n")

	// notify() has nowhere to go but this console.
	ow.conn = objdb.Connection_Hooks{
		notify = proc(user_data: rawptr, player: values.Objid, text: string) -> bool {
			fmt.printfln("#%d <- %s", player, text)
			return true
		},
	}
	defer ow.conn = {}

	reader: bufio.Reader
	buf: [4096]byte
	bufio.reader_init_with_buf(&reader, os.to_reader(os.stdin), buf[:])
	defer bufio.reader_destroy(&reader)

	read_line :: proc(r: ^bufio.Reader) -> (line: string, ok: bool) {
		l, err := bufio.reader_read_string(r, '\n', context.temp_allocator)
		if err != nil && len(l) == 0 {
			return "", false
		}
		return strings.trim_left(strings.trim_right(l, "\r\n"), " "), true
	}

	wizard := values.NOTHING
	debug := true
	for {
		if !objdb.is_wizard(db, wizard) {
			if wizard >= 0 {
				fmt.printfln("** Object #%d is not a wizard...", wizard)
			}
			wizard = find_any_wizard(db)
			if !objdb.is_wizard(db, wizard) {
				first_valid := values.NOTHING
				for oid := values.Objid(0); oid <= db.max_oid; oid += 1 {
					if objdb.valid(db, oid) {
						first_valid = oid
						break
					}
				}
				if first_valid == values.NOTHING {
					fmt.println("** No objects in database; nothing to run commands as.")
					return false
				}
				wizard = first_valid
				db.objects[wizard].flags |= 1 << uint(objdb.Object_Flag.Wizard)
				fmt.printfln("** No wizards in database; wizzed #%d.", wizard)
			}
			fmt.printfln("** Now running emergency commands as #%d ...", wizard)
		}
		fmt.printf("\nMOO (#%d)%s: ", wizard, debug ? "" : "[!d]")
		line, ok := read_line(&reader)
		if !ok {
			fmt.println("Bye.  (saving database)\n")
			return false // EOF is `quit`
		}
		if strings.has_prefix(line, ";") {
			rest := line[1:]
			lines: [dynamic]string
			defer delete(lines)
			if strings.has_prefix(rest, ";") {
				rest = rest[1:]
			} else {
				append(&lines, "return")
			}
			rest = strings.trim_left(rest, " ")
			if rest == "" {
				fmt.println("Type one or more lines of code, ending with `.' alone on a line.")
				for {
					l, lok := read_line(&reader)
					if !lok || l == "." {
						break
					}
					append(&lines, l)
				}
			} else {
				append(&lines, rest)
			}
			append(&lines, ";")
			emergency_eval(ow, world, strings.join(lines[:], "\n", context.temp_allocator), wizard, debug)
			free_all(context.temp_allocator)
			continue
		}
		words := strings.fields(line, context.temp_allocator)
		if len(words) == 0 {
			continue
		}
		command := words[0]
		nargs := len(words) - 1
		switch {
		case (values.strings_equal_fold(command, "program") || values.strings_equal_fold(command, ".program")) && nargs == 1:
			definer, index, ok := emergency_find_verb(ow, wizard, words[1])
			if !ok {
				continue
			}
			code: [dynamic]string
			defer delete(code)
			for {
				l, lok := read_line(&reader)
				if !lok || l == "." {
					break
				}
				append(&code, l)
			}
			emergency_program(ow, world, wizard, definer, index, code[:])
		case values.strings_equal_fold(command, "list") && nargs == 1:
			definer, index, ok := emergency_find_verb(ow, wizard, words[1], quiet = true)
			if ok {
				emergency_list(ow, world, wizard, definer, index)
			}
		case values.strings_equal_fold(command, "disassemble") && nargs == 1:
			fmt.println("** This server has no bytecode to disassemble (see `list').")
		case values.strings_equal_fold(command, "abort") && nargs == 0:
			fmt.println("Bye.  (NOT saving database)\n")
			os.exit(1)
		case values.strings_equal_fold(command, "quit") && nargs == 0:
			fmt.println("Bye.  (saving database)\n")
			return false
		case values.strings_equal_fold(command, "continue") && nargs == 0:
			fmt.println("Bye.  (continuing)\n")
			return true
		case values.strings_equal_fold(command, "debug") && nargs == 0:
			debug = !debug
		case values.strings_equal_fold(command, "wizard") && nargs == 1 && strings.has_prefix(words[1], "#"):
			n, nok := strconv.parse_int(words[1][1:], 10)
			if nok {
				wizard = values.Objid(n)
				fmt.printfln("** Switching to wizard #%d...", wizard)
			}
		case:
			if !values.strings_equal_fold(command, "help") && command != "?" {
				fmt.println("** Unknown or malformed command.")
			}
			fmt.println(";EXPR                 Evaluate MOO expression, print result.")
			fmt.println(";;CODE                Execute whole MOO verb, print result.")
			fmt.println("    (For above, omitting EXPR or CODE lets you enter several lines")
			fmt.println("     of input at once; type a period alone on a line to finish.)")
			fmt.println("program OBJ:VERB      Set the MOO code of an existing verb.")
			fmt.println("list OBJ:VERB         List the MOO code of an existing verb.")
			fmt.println("debug                 Toggle evaluation with(out) `d' bit.")
			fmt.println("wizard #XX            Execute future commands as wizard #XX.")
			fmt.println("continue              End emergency mode, continue start-up.")
			fmt.println("quit                  Exit server normally, saving database.")
			fmt.println("abort                 Exit server *without* saving database.")
			fmt.println("help, ?               Print this text.\n")
			fmt.println("NOTE: *NO* forked or suspended tasks will run until you exit this mode.\n")
			fmt.println("\"Please remember to turn me off when you go...\"")
		}
		free_all(context.temp_allocator)
	}
}

// emergency_eval compiles and runs `src` as the emergency wizard (run_server_program_task with
// tracebacks), printing "=> value" -- or the compiler's errors.
@(private = "file")
emergency_eval :: proc(ow: ^objdb.Object_World, world: ^vm.World, src: string, wizard: values.Objid, debug: bool) {
	r := compiler.parse_program(src, ow.db.version)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		for e in r.errors {
			delete(e)
		}
		delete(r.errors)
	}
	if len(r.errors) > 0 {
		fmt.printfln("** %d errors during parsing:", len(r.errors))
		for e in r.errors {
			fmt.printfln("  %s", e)
		}
		return
	}

	act := vm.activation_make(len(r.names.names), &r.names)
	defer vm.activation_destroy(&act)
	act.this = values.NOTHING
	act.player = wizard
	act.caller = values.NOTHING
	act.programmer = wizard
	act.verb_loc = values.NOTHING
	act.verb_name = "emergency_mode"
	act.debug = debug
	if slot := compiler.find(&r.names, "player"); slot >= 0 {
		act.locals[slot] = values.obj_val(wizard)
	}
	if slot := compiler.find(&r.names, "this"); slot >= 0 {
		act.locals[slot] = values.obj_val(values.NOTHING)
	}
	if slot := compiler.find(&r.names, "caller"); slot >= 0 {
		act.locals[slot] = values.obj_val(values.NOTHING)
	}
	budget: vm.Task_Budget
	vm.budget_open(&budget, world, false)
	defer vm.budget_close(&budget)
	act.budget = &budget

	result := vm.run(r.body, &r.names, world, &act)
	switch result.signal {
	case .Return:
		defer values.free_var(result.value)
		lit_args := make([]values.Var, 1)
		lit_args[0] = values.var_ref(result.value)
		lit_result, _ := builtins.call("toliteral", values.list_val(lit_args))
		// toliteral() can raise (values.MAX_STR_LEN), and a raised Call_Result's `value` is
		// the zero Var, whose data.str is nil -- emergency mode is the LAST place that should
		// die on a value it was asked to inspect.
		if lit_result.raised {
			fmt.printfln("=> (cannot print value: %s)", lit_result.msg)
			delete(lit_result.msg)
			values.free_var(lit_result.rvalue)
			return
		}
		defer values.free_var(lit_result.value)
		fmt.printfln("=> %s", lit_result.value.data.str.s)
	case .Raised:
		objdb.task_aborted(ow, world, &result.err, &act) // its traceback, via notify above
		fmt.println("=> *Aborted*")
		delete(result.err.msg)
		values.free_var(result.err.value)
	case .Normal, .Break, .Continue:
		fmt.println("=> 0")
	}
}

// emergency_find_verb ports find_verb_for_programming() for the console: OBJ is `$name` or
// anything match_object understands for the wizard. Prints the original's messages.
@(private = "file")
emergency_find_verb :: proc(ow: ^objdb.Object_World, wizard: values.Objid, verbref: string, quiet := false) -> (definer: values.Objid, index: int, ok: bool) {
	colon := strings.index_byte(verbref, ':')
	if colon < 0 || colon == len(verbref) - 1 {
		fmt.println("You must specify a verb; use the format object:verb.")
		return
	}
	obj, vname := verbref[:colon], verbref[colon + 1:]
	oid := values.NOTHING
	if strings.has_prefix(obj, "$") {
		if h := objdb.find_property(ow.db, values.SYSTEM_OBJECT, obj[1:]); h.found {
			v := objdb.property_value(ow.db, values.SYSTEM_OBJECT, h)
			if v.type == .Obj {
				oid = v.data.obj
			}
			values.free_var(v)
		}
	} else {
		oid = objdb.match_object(ow.db, wizard, obj)
	}
	if !objdb.valid(ow.db, oid) {
		switch oid {
		case objdb.FAILED_MATCH:
			fmt.printfln("I don't see \"%s\" here.", obj)
		case objdb.AMBIGUOUS:
			fmt.printfln("I don't know which \"%s\" you mean.", obj)
		case:
			fmt.printfln("\"%s\" is not a valid object.", obj)
		}
		return
	}
	h := objdb.find_defined_verb(ow.db, oid, vname, objdb.server_flag_option(ow, "support_numeric_verbname_strings", false))
	if !h.found {
		fmt.println("That object does not have that verb definition.")
		return
	}
	if !quiet {
		fmt.printfln("Now programming %s:%s.  Use \".\" to end.", ow.db.objects[oid].name, ow.db.objects[oid].verbdefs[h.index].name)
	}
	return h.definer, h.index, true
}

@(private = "file")
emergency_program :: proc(ow: ^objdb.Object_World, world: ^vm.World, wizard: values.Objid, definer: values.Objid, index: int, code: []string) {
	items := make([]values.Var, len(code))
	for l, i in code {
		items[i] = values.str_val(strings.clone(l))
	}
	args := make([]values.Var, 3)
	args[0] = values.obj_val(definer)
	args[1] = values.int_val(i32(index + 1))
	args[2] = values.list_val(items)
	act := vm.Activation{this = values.NOTHING, player = wizard, programmer = wizard, depth = -1}
	ctx := vm.Eval_Context{activation = &act, world = world}
	r := objdb.bf_set_verb_code(ow, values.list_val(args), &ctx)
	if r.raised {
		fmt.printfln("** %s", r.msg)
		delete(r.msg)
		values.free_var(r.rvalue)
		return
	}
	defer values.free_var(r.value)
	if n := values.list_len(r.value); n > 0 {
		fmt.printfln("** %d errors during parsing:", n)
		for i in 1 ..= n {
			fmt.printfln("  %s", values.list_get(r.value, i).data.str.s)
		}
		fmt.println("Verb not programmed.")
		return
	}
	fmt.println("Verb programmed.")
}

@(private = "file")
emergency_list :: proc(ow: ^objdb.Object_World, world: ^vm.World, wizard: values.Objid, definer: values.Objid, index: int) {
	args := make([]values.Var, 2)
	args[0] = values.obj_val(definer)
	args[1] = values.int_val(i32(index + 1))
	act := vm.Activation{this = values.NOTHING, player = wizard, programmer = wizard, depth = -1}
	ctx := vm.Eval_Context{activation = &act, world = world}
	r := objdb.bf_verb_code(ow, values.list_val(args), &ctx)
	if r.raised {
		fmt.printfln("** %s", r.msg)
		delete(r.msg)
		values.free_var(r.rvalue)
		return
	}
	defer values.free_var(r.value)
	for i in 1 ..= values.list_len(r.value) {
		fmt.println(values.list_get(r.value, i).data.str.s)
	}
}

// find_any_wizard returns the lowest-numbered object with the wizard bit set (in stock
// LambdaCore, #2), or SYSTEM_OBJECT if the database somehow has none.
@(private = "file")
find_any_wizard :: proc(db: ^dbfile.Database) -> values.Objid {
	for oid := values.Objid(0); oid <= db.max_oid; oid += 1 {
		if objdb.valid(db, oid) && objdb.is_wizard(db, oid) {
			return oid
		}
	}
	return values.SYSTEM_OBJECT
}

