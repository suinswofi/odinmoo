package main

// Crash-hunting harness for the byte-oriented entry points that arbitrary, hostile input
// actually reaches: the color-markup translator every outbound line passes through, the word
// splitter every UNAUTHENTICATED line passes through, the MOO compiler (reachable by any
// programmer via `.program`/eval()/set_verb_code()), and the regex engine (match()'s pattern
// is player-supplied).
//
// Build it under AddressSanitizer -- that is the whole point, and it must NOT be run as an
// `odin test` case to get it:
//
//	odin build cmd/fuzz -sanitize:address -debug -extra-linker-flags:"-lcrypt" -out:bin/fuzz
//	./bin/fuzz 300000            # random inputs
//	./bin/fuzz -f some_file      # parse one file, for reducing a failure to a minimal case
//
// The test runner's allocator is a rollback stack that never returns memory to the OS, so
// ASan cannot see a use-after-free under `odin test` at all; a plain binary on the heap
// allocator can. That difference is not academic: the parse_program/lexer_destroy ordering bug
// this harness found is invisible to the unit tests and visible here in seconds.
//
// Inputs are drawn from alphabets weighted toward the metacharacters of each grammar rather
// than uniform bytes, which is what makes a few hundred thousand iterations enough to reach
// error-recovery paths instead of bouncing off the first character.

import "../../ansi"
import "../../compiler"
import "../../dbfile"
import "../../netio"
import "../../vm"
import "../../values"
import "../../objdb"
import "../../regex"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"

SEED :: 20260918
ITERS :: #config(FUZZ_DB_ITERS, 20000)
MOO_ITERS :: #config(FUZZ_MOO_ITERS, 30000)

@(private = "file")
random_bytes :: proc(max_len: int, alphabet: string) -> string {
	n := int(rand.uint32()) % max_len
	b := strings.builder_make()
	for _ in 0 ..< n {
		strings.write_byte(&b, alphabet[int(rand.uint32()) % len(alphabet)])
	}
	return strings.to_string(b)
}

@(private = "file")
parse_once :: proc(src: string) {
	res := compiler.parse_program(src, dbfile.Current_DB_Version)
	compiler.free_stmts(res.body)
	compiler.name_table_destroy(&res.names)
	for e in res.errors {
		delete(e)
	}
	delete(res.errors)
}

main :: proc() {
	if len(os.args) > 1 && os.args[1] == "-moo" {
		fuzz_moo(len(os.args) > 2 ? os.args[2] : "Minimal.db")
		return
	}
	if len(os.args) > 1 && os.args[1] == "-db" {
		fuzz_db_loader(len(os.args) > 2 ? os.args[2] : "Minimal.db")
		return
	}
	if len(os.args) > 2 && os.args[1] == "-f" {
		data, rerr := os.read_entire_file_from_path(os.args[2], context.allocator)
		if rerr != nil {
			fmt.eprintfln("cannot read %s: %v", os.args[2], rerr)
			os.exit(2)
		}
		defer delete(data)
		parse_once(string(data))
		return
	}

	iters := 200000
	if len(os.args) > 1 {
		n := 0
		for c in os.args[1] {
			n = n * 10 + int(c - '0')
		}
		if n > 0 {
			iters = n
		}
	}
	rand.reset(SEED)

	ansi_alpha := "%|0123456789abcdefghinrgwcyxzZ \t\\\x00\x1b<>[]"
	cmd_alpha := `abc "\ :.#$%|()[]{}<>,;'` + "\t\x00"
	moo_alpha := `abc123 +-*/%^=<>!&|()[]{}.,;:"'\$#@~` + "\n\t"
	re_alpha := `abc%()[]|*+?.^$-\0123`

	for i in 0 ..< iters {
		{ 	// ansi.translate runs on EVERY line sent to a client, in both modes
			s := random_bytes(120, ansi_alpha)
			defer delete(s)
			a := ansi.translate(s, true)
			delete(a)
			b := ansi.translate(s, false)
			delete(b)
			_ = ansi.visible_len(s)
		}
		{ 	// split_command_words: the first thing an unauthenticated line goes through
			s := random_bytes(120, cmd_alpha)
			defer delete(s)
			words := netio.split_command_words(s)
			for w in words {
				delete(w)
			}
			delete(words)
		}
		{ 	// the MOO compiler
			s := random_bytes(160, moo_alpha)
			defer delete(s)
			parse_once(s)
		}
		{ 	// the regex engine, forwards and backwards, case-folded and not
			pat := random_bytes(40, re_alpha)
			defer delete(pat)
			subj := random_bytes(60, re_alpha)
			defer delete(subj)
			if prog, ok := regex.compile(pat); ok {
				defer regex.program_destroy(&prog)
				_ = regex.match_pattern(&prog, subj, false, true)
				_ = regex.match_pattern(&prog, subj, true, false)
			}
		}
		if i > 0 && i % 50000 == 0 {
			fmt.printfln("  ... %d", i)
		}
	}
	fmt.printfln("fuzz: %d iterations from seed %d, no crash", iters, SEED)
}

// ---- .db loader ----
//
// Mutates a real core's bytes and feeds the result to load_database_bytes. A corrupt database
// is not a hypothetical: a checkpoint truncated by a crash or a bad disk is exactly what
// emergency mode exists to recover from, so "reports a Load_Error" and "takes the process
// down" are very different outcomes here.
@(private = "file")
fuzz_db_loader :: proc(base_path: string) {
	base, rerr := os.read_entire_file_from_path(base_path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("cannot read %s: %v -- run from the repo root", base_path, rerr)
		os.exit(2)
	}
	defer delete(base)
	rand.reset(SEED)
	digits := "0123456789-"
	for i in 0 ..< ITERS {
		buf := make([]byte, len(base))
		copy(buf, base)
		// Truncation, and a handful of byte edits biased toward digits so that counts and
		// lengths (the fields the reader trusts) actually change value rather than just
		// becoming unparseable.
		if len(buf) > 0 && rand.uint32() % 4 == 0 {
			buf = buf[:int(rand.uint32()) % len(buf)]
		}
		edits := 1 + int(rand.uint32()) % 8
        for _ in 0 ..< edits {
			if len(buf) == 0 {break}
			at := int(rand.uint32()) % len(buf)
			if rand.uint32() % 2 == 0 {
				buf[at] = digits[int(rand.uint32()) % len(digits)]
			} else {
				buf[at] = byte(rand.uint32())
			}
		}
		db, lerr := dbfile.load_database_bytes(buf)
		_ = lerr
		dbfile.database_destroy(&db)
		delete(buf)
		if i > 0 && i % 5000 == 0 {
			fmt.printfln("  ... db %d", i)
		}
	}
	fmt.printfln("db loader fuzz: %d mutations, no crash", ITERS)
}

// ---- MOO expression / builtin fuzzing (vm + objdb) ----
//
// Compiles and RUNS random MOO programs against a real loaded database, with wizard
// permissions, so the VM's evaluation paths and objdb's built-in implementations get hostile
// arguments: wrong types, wrong argument counts, out-of-range indices, invalid object
// numbers. Every builtin does its own argument checking by hand, which is exactly the kind of
// code where one missing check is a crash rather than an E_TYPE.
//
// Deliberately excluded from the generated grammar: `while`/`for` (this has no tick limit, so
// a generated infinite loop would hang the fuzzer rather than fail it) and `fork` (spawns
// threads). The scheduler is nil, which also makes suspend()/read() unavailable rather than
// blocking. Everything else -- including verb calls, property access, indexing, scatter
// assignment and try/except -- is in scope.
@(private = "file")
MOO_LITERALS := []string {
	"0", "1", "-1", "2147483647", "-2147483647 - 1", "1.5", "-0.0", "1.0e308",
	`""`, `"abc"`, `"%r|15"`, "{}", "{1}", "{1, \"a\", #0}", "{{1}, {}}",
	"#0", "#1", "#-1", "#99999", "E_NONE", "E_TYPE", "E_RANGE",
	"player", "this", "caller", "verb", "args",
}

@(private = "file")
BUILTIN_NAMES := []string {
	"abs", "acos", "asin", "atan", "ceil", "cos", "cosh", "exp", "floor", "log", "log10",
	"sin", "sinh", "sqrt", "tan", "tanh", "trunc", "min", "max", "random", "time", "ctime",
	"floatstr", "toint", "tonum", "tofloat", "tostr", "toliteral", "toobj", "typeof", "equal",
	"length", "listappend", "listdelete", "listinsert", "listset", "setadd", "setremove",
	"is_member", "index", "rindex", "strcmp", "strsub", "match", "rmatch", "substitute",
	"crypt", "string_hash", "binary_hash", "value_bytes", "value_hash", "encode_binary",
	"valid", "parent", "children", "create", "recycle", "chparent", "max_object", "players",
	"is_player", "move", "properties", "property_info", "add_property", "delete_property",
	"clear_property", "is_clear_property", "verbs", "verb_info", "verb_args", "verb_code",
	"add_verb", "delete_verb", "set_verb_info", "set_verb_args", "set_verb_code",
	"set_property_info", "object_bytes", "caller_perms", "set_task_perms", "callers",
	"task_id", "queued_tasks", "function_info", "server_version", "memory_usage",
	"notify", "connected_players", "connected_seconds", "idle_seconds", "connection_name",
	"boot_player", "output_delimiters", "listeners", "eval", "pass", "raise", "call_function",
	"ansi_strip", "ansi_len", "ansify",
}

@(private = "file")
random_moo_source :: proc() -> string {
	b := strings.builder_make()
	lit :: proc(b: ^strings.Builder) {
		strings.write_string(b, MOO_LITERALS[int(rand.uint32()) % len(MOO_LITERALS)])
	}
	nstmt := 1 + int(rand.uint32()) % 3
	for _ in 0 ..< nstmt {
		switch rand.uint32() % 6 {
		case 0, 1, 2:
			// builtin(arg, ...) -- the main event
			strings.write_string(&b, "r = ")
			strings.write_string(&b, BUILTIN_NAMES[int(rand.uint32()) % len(BUILTIN_NAMES)])
			strings.write_byte(&b, '(')
			nargs := int(rand.uint32()) % 5
			for i in 0 ..< nargs {
				if i > 0 {strings.write_string(&b, ", ")}
				lit(&b)
			}
			strings.write_string(&b, ");\n")
		case 3:
			// indexing / ranges / property / verb access
			strings.write_string(&b, "r = ")
			lit(&b)
			switch rand.uint32() % 4 {
			case 0:
				strings.write_byte(&b, '[')
				lit(&b)
				strings.write_byte(&b, ']')
			case 1:
				strings.write_byte(&b, '[')
				lit(&b)
				strings.write_string(&b, "..")
				lit(&b)
				strings.write_byte(&b, ']')
			case 2:
				strings.write_string(&b, ".name")
			case 3:
				strings.write_string(&b, ":foo()")
			}
			strings.write_string(&b, ";\n")
		case 4:
			// arithmetic / comparison
			ops := []string{"+", "-", "*", "/", "%", "^", "==", "!=", "<", "<=", ">", ">=", "&&", "||", "in"}
			strings.write_string(&b, "r = ")
			lit(&b)
			strings.write_byte(&b, ' ')
			strings.write_string(&b, ops[int(rand.uint32()) % len(ops)])
			strings.write_byte(&b, ' ')
			lit(&b)
			strings.write_string(&b, ";\n")
		case 5:
			// scatter assignment / try / conditional -- statement shapes, not just expressions
			switch rand.uint32() % 3 {
			case 0:
				strings.write_string(&b, "{a, b, ?c} = ")
				lit(&b)
				strings.write_string(&b, ";\n")
			case 1:
				strings.write_string(&b, "try r = ")
				lit(&b)
				strings.write_string(&b, "[1]; except e (ANY) r = e; endtry\n")
			case 2:
				strings.write_string(&b, "if (")
				lit(&b)
				strings.write_string(&b, ") r = ")
				lit(&b)
				strings.write_string(&b, "; endif\n")
			}
		}
	}
	strings.write_string(&b, "return r;\n")
	return strings.to_string(b)
}

@(private = "file")
fuzz_moo :: proc(core_path: string) {
	db, lerr := dbfile.load_database(core_path)
	if lerr.stage != "" {
		fmt.eprintfln("cannot load %s: %v -- run from the repo root", core_path, lerr)
		os.exit(2)
	}
	defer dbfile.database_destroy(&db)
	// scheduler = nil on purpose: it makes suspend()/read()/fork bookkeeping unavailable
	// rather than blocking this single-threaded harness forever.
	ow := objdb.object_world_init(&db, nil)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	wiz := values.Objid(3) // Minimal.db's wizard; any valid object works for permission checks
	rand.reset(SEED)
	cmd_line_alpha := `abc 123 the with at to from in on #$"\\:.*` + "\t"
	compiled, returned, raised: int
	errs: map[values.Error]int
	defer delete(errs)
	for i in 0 ..< MOO_ITERS {
		src := random_moo_source()
		defer delete(src)
		r := compiler.parse_program(src, db.version)
		if len(r.errors) == 0 {
			compiled += 1
			act := vm.activation_make(len(r.names.names), &r.names)
			act.this = wiz
			act.player = wiz
			act.programmer = wiz
			act.verb_loc = wiz
			act.verb_name = "fuzz"
			act.debug = true
			act.depth = 0
			// Bind the standard variables into their slots. Without this a third of the
			// generated programs died on E_VARNF before reaching the builtin they were meant
			// to exercise -- the fuzzer looked busy while testing almost nothing.
			bind :: proc(r: ^compiler.Parse_Result, act: ^vm.Activation, name: string, v: values.Var) {
				if slot := compiler.find(&r.names, name); slot >= 0 {
					values.free_var(act.locals[slot])
					act.locals[slot] = v
				} else {
					values.free_var(v)
				}
			}
			bind(&r, &act, "player", values.obj_val(wiz))
			bind(&r, &act, "this", values.obj_val(wiz))
			bind(&r, &act, "caller", values.obj_val(wiz))
			bind(&r, &act, "verb", values.str_val(strings.clone("fuzz")))
			bind(&r, &act, "args", values.empty_list())
			res := vm.run(r.body, &r.names, &world, &act)
			#partial switch res.signal {
			case .Return:
				returned += 1
				values.free_var(res.value)
			case .Raised:
				raised += 1
				errs[res.err.code] += 1
				delete(res.err.msg)
				values.free_var(res.err.value)
			}
			vm.activation_destroy(&act)
		}
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		for e in r.errors {delete(e)}
		delete(r.errors)
		{ 	// objdb's command parser and object matcher, on the same database. Unlike the
			// programs above these are reachable by a merely logged-in player, with no
			// programmer bit: every line typed at the prompt goes through parse_command, and
			// its dobj/iobj matching walks the player's and the room's contents chains.
			line := random_bytes(80, cmd_line_alpha)
			defer delete(line)
			pc := objdb.parse_command(&db, line, wiz)
			objdb.parsed_command_destroy(&pc)
			name := random_bytes(24, cmd_line_alpha)
			defer delete(name)
			_ = objdb.match_object(&db, wiz, name)
		}
		if i > 0 && i % 5000 == 0 {
			fmt.printfln("  ... moo %d", i)
		}
	}
	fmt.printfln("moo fuzz: %d programs, no crash", MOO_ITERS)
	fmt.printfln("  compiled=%d returned=%d raised=%d", compiled, returned, raised)
	for code, n in errs {
		fmt.printfln("    %v %d", code, n)
	}
}
