#+feature dynamic-literals
package main

// Scratch verification tool: audits a real .db (default jhcore.db) for compatibility with
// this port -- structural integrity of the object graph, the property-inheritance invariant
// the DB format depends on, the set of MOO value types actually present, whether every verb
// program compiles, and whether every built-in function those programs call is implemented
// anywhere in this server. Prints a report; exits non-zero if anything is unsupported.
//
// Usage: odin run cmd/jhverify -extra-linker-flags:"-lcrypt" -- [db-path]   (from repo root)

import "../../builtins"
import "../../compiler"
import "../../dbfile"
import "../../values"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// Built-ins implemented outside builtins.table: objdb's object-aware set
// (objdb/object_builtins.odin) and the scheduler's (tasks/suspend.odin). Transcribed from
// those files' `case "name":` dispatch switches -- objdb's live behind a package-private
// proc, so there's no exported table to consult at runtime.
db_and_task_builtins := map[string]bool {
	"valid" = true, "parent" = true, "children" = true, "is_player" = true,
	"server_version" = true, "callers" = true, "caller_perms" = true, "notify" = true,
	"notify_raw" = true, "connection_name" = true, "boot_player" = true,
	"idle_seconds" = true, "verbs" = true, "verb_args" = true, "verb_info" = true,
	"is_clear_property" = true, "pass" = true, "set_task_perms" = true, "move" = true,
	"connected_players" = true, "connected_seconds" = true, "ticks_left" = true,
	"seconds_left" = true, "create" = true, "recycle" = true, "chparent" = true,
	"renumber" = true, "reset_max_object" = true, "max_object" = true,
	"properties" = true, "property_info" = true, "set_property_info" = true,
	"add_property" = true, "delete_property" = true, "clear_property" = true,
	"add_verb" = true, "delete_verb" = true, "set_verb_info" = true,
	"set_verb_args" = true, "verb_code" = true, "set_verb_code" = true, "crypt" = true,
	"players" = true, "set_player_flag" = true, "queued_tasks" = true,
	"task_stack" = true, "floatstr" = true, "value_bytes" = true, "object_bytes" = true,
	"memory_usage" = true, "function_info" = true, "call_function" = true,
	"server_log" = true, "shutdown" = true, "dump_database" = true,
	"load_server_options" = true, "read" = true, "force_input" = true,
	"flush_input" = true, "set_connection_option" = true, "connection_option" = true,
	"connection_options" = true, "output_delimiters" = true,
	"open_network_connection" = true, "eval" = true, "listeners" = true,
	"suspend" = true, "resume" = true, "kill_task" = true, "task_id" = true,
}

is_implemented :: proc(name: string) -> bool {
	if name in builtins.table {
		return true
	}
	return name in db_and_task_builtins
}

Census :: struct {
	calls:       map[string]int, // builtin name -> number of call sites
	sites:       map[string][dynamic]string, // unimplemented name -> "#obj:verb" sites
	site:        string, // the verb currently being walked
	verbs_total: int,
	verbs_prog:  int,
	parse_fail:  int,
}

main :: proc() {
	path := "jhcore.db"
	if len(os.args) > 1 {
		path = os.args[1]
	}

	db, lerr := dbfile.load_database(path)
	defer dbfile.database_destroy(&db)
	if lerr.stage != "" {
		fmt.eprintfln("LOAD FAILED at stage %q: %v", lerr.stage, lerr.err)
		os.exit(1)
	}

	// Find mode: `... <db> find <substring>` lists every verb whose name contains the
	// substring, with its owning object -- for locating a command verb by name.
	if len(os.args) > 3 && os.args[2] == "find" {
		for oid, obj in db.objects {
			for v in obj.verbdefs {
				if strings.contains(v.name, os.args[3]) {
					fmt.printfln("#%d (%s): %q  perms=%d prep=%d", oid, obj.name, v.name, v.perms, v.prep)
				}
			}
		}
		return
	}

	// Object mode: `... <db> obj <oid>` prints the object's structural links and its
	// ancestor chain -- what command dispatch actually walks.
	if len(os.args) > 3 && os.args[2] == "obj" {
		oid64, _ := strconv.parse_int(os.args[3], 10)
		oid := values.Objid(oid64)
		obj, ok := db.objects[oid]
		if !ok {
			fmt.eprintfln("no such object #%d", oid)
			os.exit(1)
		}
		fmt.printfln(
			"#%d (%s)\n  parent #%d  owner #%d  location #%d  contents #%d  next #%d  child #%d  sibling #%d  flags %d",
			oid, obj.name, obj.parent, obj.owner, obj.location, obj.contents, obj.next,
			obj.child, obj.sibling, obj.flags,
		)
		fmt.print("  ancestors:")
		cur := obj.parent
		for cur != values.NOTHING {
			p, pok := db.objects[cur]
			if !pok {
				fmt.printf(" #%d(missing)", cur)
				break
			}
			fmt.printf(" #%d(%s)", cur, p.name)
			cur = p.parent
		}
		fmt.println("")
		return
	}

	// Dump mode: `... <db> <oid> <verb-name>` prints one verb's source and exits, for
	// eyeballing whatever the audit below flags.
	if len(os.args) > 3 {
		oid, _ := strconv.parse_int(os.args[2], 10)
		obj, ok := db.objects[values.Objid(oid)]
		if !ok {
			fmt.eprintfln("no such object #%d", oid)
			os.exit(1)
		}
		fmt.printfln("// #%d (%s) parent #%d owner #%d", oid, obj.name, obj.parent, obj.owner)
		for v in obj.verbdefs {
			if v.name == os.args[3] {
				fmt.println(v.program_source)
				return
			}
		}
		fmt.eprintln("verb not found")
		os.exit(1)
	}

	fmt.printfln("=== %s ===", path)
	fmt.printfln(
		"format version %d, %d objects, max_oid #%d, %d users, %d forked tasks, %d suspended, %d connections",
		db.version, len(db.objects), db.max_oid, len(db.users),
		len(db.forked_tasks), db.suspended_task_count, len(db.connections),
	)

	problems := 0
	problems += check_graph(&db)
	problems += check_properties(&db)
	problems += report_value_types(&db)

	c := Census{calls = make(map[string]int), sites = make(map[string][dynamic]string)}
	defer {
		for k in c.calls do delete(k)
		delete(c.calls)
		for _, v in c.sites {
			for site in v do delete(site)
			delete(v)
		}
		delete(c.sites)
	}
	compile_all(&db, &c)
	fmt.printfln(
		"\nverbs: %d defined, %d with programs, %d failed to compile",
		c.verbs_total, c.verbs_prog, c.parse_fail,
	)
	problems += c.parse_fail

	problems += report_builtins(&c)
	report_nondebug_verbs(&db)
	problems += check_roundtrip(&db)

	fmt.println("")
	if problems == 0 {
		fmt.println("RESULT: no incompatibilities found")
	} else {
		fmt.printfln("RESULT: %d problem(s) found", problems)
		os.exit(1)
	}
}

// check_graph verifies the structural links the object store depends on: parent chains
// terminate, and the parent/child/sibling and location/contents/next linked lists the C
// server maintains are mutually consistent and point at objects that exist.
check_graph :: proc(db: ^dbfile.Database) -> (problems: int) {
	dangling_parent, dangling_owner, dangling_loc := 0, 0, 0
	cycles := 0
	contents_mismatch, children_mismatch := 0, 0

	for oid, obj in db.objects {
		hops := 0
		cur := obj.parent
		for cur != values.NOTHING {
			p, ok := db.objects[cur]
			if !ok {
				dangling_parent += 1
				break
			}
			cur = p.parent
			hops += 1
			if hops >= 100 {
				cycles += 1
				fmt.printfln("  parent cycle starting at #%d", oid)
				break
			}
		}
		if obj.owner != values.NOTHING && obj.owner not_in db.objects {
			dangling_owner += 1
		}
		if obj.location != values.NOTHING && obj.location not_in db.objects {
			dangling_loc += 1
		}

		// Every object in obj's contents list must agree that its location is obj.
		seen := 0
		child := obj.contents
		for child != values.NOTHING && seen < 100000 {
			co, ok := db.objects[child]
			if !ok {
				contents_mismatch += 1
				break
			}
			if co.location != oid {
				contents_mismatch += 1
			}
			child = co.next
			seen += 1
		}

		// Likewise for the child/sibling list vs. parent.
		seen = 0
		kid := obj.child
		for kid != values.NOTHING && seen < 100000 {
			ko, ok := db.objects[kid]
			if !ok {
				children_mismatch += 1
				break
			}
			if ko.parent != oid {
				children_mismatch += 1
			}
			kid = ko.sibling
			seen += 1
		}
	}

	fmt.println("\nobject graph:")
	fmt.printfln("  parent chains: %d cycles, %d dangling parents", cycles, dangling_parent)
	fmt.printfln("  dangling owners: %d, dangling locations: %d", dangling_owner, dangling_loc)
	fmt.printfln("  contents/location mismatches: %d", contents_mismatch)
	fmt.printfln("  child/parent mismatches: %d", children_mismatch)
	return cycles + contents_mismatch + children_mismatch
}

// check_properties verifies the invariant the whole propval layout depends on: an object's
// propvals are exactly one slot per property defined by itself and every ancestor, in
// ancestor-first order (db_properties.c). A count mismatch means property lookup would read
// the wrong slot -- silently, and only for some objects.
check_properties :: proc(db: ^dbfile.Database) -> (problems: int) {
	mismatches := 0
	total_defs, total_vals := 0, 0
	dupe_names := 0

	for oid, obj in db.objects {
		expected := 0
		cur := oid
		hops := 0
		for cur != values.NOTHING && hops < 100 {
			o, ok := db.objects[cur]
			if !ok {
				break
			}
			expected += len(o.propdefs)
			cur = o.parent
			hops += 1
		}
		total_defs += len(obj.propdefs)
		total_vals += len(obj.propvals)
		if expected != len(obj.propvals) {
			mismatches += 1
			if mismatches <= 10 {
				fmt.printfln(
					"  #%d: %d propvals but %d properties defined up the chain",
					oid, len(obj.propvals), expected,
				)
			}
		}

		// A name defined twice on one object would make lookup order-dependent.
		seen := make(map[string]bool)
		defer delete(seen)
		for pd in obj.propdefs {
			if pd.name in seen {
				dupe_names += 1
			}
			seen[pd.name] = true
		}
	}

	fmt.println("\nproperties:")
	fmt.printfln("  %d property definitions, %d property values", total_defs, total_vals)
	fmt.printfln("  inheritance-count mismatches: %d", mismatches)
	fmt.printfln("  duplicate names on one object: %d", dupe_names)
	return mismatches + dupe_names
}

// report_value_types counts the MOO value types actually stored in the database. An
// extended-server fork's custom type would have failed the load outright, but this makes
// the coverage explicit rather than assumed.
report_value_types :: proc(db: ^dbfile.Database) -> (problems: int) {
	counts: map[values.Var_Type]int
	defer delete(counts)
	for _, obj in db.objects {
		for pv in obj.propvals {
			tally_type(&counts, pv.value)
		}
	}
	fmt.println("\nvalue types in property values:")
	keys, _ := slice.map_keys(counts)
	defer delete(keys)
	slice.sort_by(keys, proc(a, b: values.Var_Type) -> bool {return int(a) < int(b)})
	for k in keys {
		fmt.printfln("  %-8v %d", k, counts[k])
	}
	return 0
}

tally_type :: proc(counts: ^map[values.Var_Type]int, v: values.Var) {
	counts[v.type] += 1
	if v.type == .List {
		for i in 1 ..= values.list_len(v) {
			tally_type(counts, values.list_get(v, i))
		}
	}
}

// compile_all runs every verb program through the real parser and censuses the built-in
// functions they call.
compile_all :: proc(db: ^dbfile.Database, c: ^Census) {
	for oid, obj in db.objects {
		for verb in obj.verbdefs {
			c.verbs_total += 1
			if !verb.has_program {
				continue
			}
			c.verbs_prog += 1
			c.site = fmt.tprintf("#%d:%s", oid, verb.name)

			r := compiler.parse_program(verb.program_source, db.version)
			if len(r.errors) > 0 {
				c.parse_fail += 1
				if c.parse_fail <= 20 {
					fmt.printfln("  COMPILE FAIL #%d:%s -- %s", oid, verb.name, r.errors[0])
				}
			} else {
				census_stmts(c, r.body)
			}
			compiler.free_stmts(r.body)
			compiler.name_table_destroy(&r.names)
			for e in r.errors do delete(e)
			delete(r.errors)
		}
	}
}

// report_builtins is the actual compatibility question for the built-in library: every name
// these programs call must be dispatched by builtins.table, objdb's object-aware set, or the
// scheduler's. Names the parser didn't recognize get rewritten to call_function("name", ...)
// at parse time (never a parse error), so unimplemented ones only surface as a runtime
// E_VERBNF -- which is exactly what this catches ahead of time.
report_builtins :: proc(c: ^Census) -> (problems: int) {
	names, _ := slice.map_keys(c.calls)
	defer delete(names)
	slice.sort(names)

	missing: [dynamic]string
	defer delete(missing)
	for n in names {
		if !is_implemented(n) {
			append(&missing, n)
		}
	}

	fmt.printfln("\nbuilt-in functions: %d distinct names called", len(names))
	for n in names {
		mark := is_implemented(n) ? " " : "!"
		fmt.printfln("  %s %-24s %d", mark, n, c.calls[n])
	}
	if len(missing) == 0 {
		fmt.println("  -> all implemented")
	} else {
		fmt.printfln("  -> %d NOT IMPLEMENTED:", len(missing))
		for n in missing {
			fmt.printfln("     %s  called from: %v", n, c.sites[n][:])
		}
	}
	return len(missing)
}

census_stmts :: proc(c: ^Census, stmts: []compiler.Stmt) {
	for s in stmts {
		switch v in s {
		case ^compiler.Stmt_Cond:
			for arm in v.arms {
				census_expr(c, arm.condition)
				census_stmts(c, arm.body)
			}
			census_stmts(c, v.otherwise)
		case ^compiler.Stmt_List_Loop:
			census_expr(c, v.list)
			census_stmts(c, v.body)
		case ^compiler.Stmt_Range_Loop:
			census_expr(c, v.from)
			census_expr(c, v.to)
			census_stmts(c, v.body)
		case ^compiler.Stmt_While:
			census_expr(c, v.condition)
			census_stmts(c, v.body)
		case ^compiler.Stmt_Fork:
			census_expr(c, v.time)
			census_stmts(c, v.body)
		case ^compiler.Stmt_Expr:
			census_expr(c, v.expr)
		case ^compiler.Stmt_Return:
			census_expr(c, v.expr)
		case ^compiler.Stmt_Try_Except:
			census_stmts(c, v.body)
			for arm in v.excepts {
				census_args(c, arm.codes)
				census_stmts(c, arm.body)
			}
		case ^compiler.Stmt_Try_Finally:
			census_stmts(c, v.body)
			census_stmts(c, v.handler)
		case ^compiler.Stmt_Break:
		case ^compiler.Stmt_Continue:
		}
	}
}

census_expr :: proc(c: ^Census, e: compiler.Expr) {
	if e == nil {
		return
	}
	switch v in e {
	case ^compiler.Expr_Var:
	case ^compiler.Expr_Id:
	case ^compiler.Expr_Length:
	case ^compiler.Expr_Prop:
		census_expr(c, v.obj)
		census_expr(c, v.prop)
	case ^compiler.Expr_Verb_Call:
		census_expr(c, v.obj)
		census_expr(c, v.verb)
		census_args(c, v.args)
	case ^compiler.Expr_Index:
		census_expr(c, v.base)
		census_expr(c, v.index)
	case ^compiler.Expr_Range:
		census_expr(c, v.base)
		census_expr(c, v.from)
		census_expr(c, v.to)
	case ^compiler.Expr_Assign:
		census_expr(c, v.target)
		census_expr(c, v.value)
	case ^compiler.Expr_Call:
		tally_call(c, v.name)
		// call_function("foo", ...) -- both the explicit form and the parser's rewrite of
		// an unrecognized name -- really calls foo, so count that too.
		if v.name == "call_function" && len(v.args) > 0 {
			if lit, ok := v.args[0].expr.(^compiler.Expr_Var); ok && lit.value.type == .Str {
				tally_call(c, lit.value.data.str.s)
			}
		}
		census_args(c, v.args)
	case ^compiler.Expr_Binary:
		census_expr(c, v.lhs)
		census_expr(c, v.rhs)
	case ^compiler.Expr_Unary:
		census_expr(c, v.operand)
	case ^compiler.Expr_List:
		census_args(c, v.items)
	case ^compiler.Expr_Cond:
		census_expr(c, v.condition)
		census_expr(c, v.consequent)
		census_expr(c, v.alternate)
	case ^compiler.Expr_Catch:
		census_expr(c, v.try)
		census_args(c, v.codes)
		census_expr(c, v.handler)
	case ^compiler.Expr_Scatter:
		for item in v.items {
			census_expr(c, item.default)
		}
	}
}

// tally_call must own its key: names point into the parse result, which is freed after each
// verb, so an un-cloned key would dangle by the time the report is printed.
tally_call :: proc(c: ^Census, name: string) {
	if n, ok := c.calls[name]; ok {
		c.calls[name] = n + 1
	} else {
		c.calls[strings.clone(name)] = 1
	}
	if !is_implemented(name) {
		if name not_in c.sites {
			c.sites[strings.clone(name)] = make([dynamic]string)
		}
		list := &c.sites[name]
		append(list, strings.clone(c.site))
	}
}

census_args :: proc(c: ^Census, args: []compiler.Arg) {
	for a in args {
		census_expr(c, a.expr)
	}
}

// report_nondebug_verbs counts verbs with the `d` (debug) flag CLEAR. In such a verb the C
// server does not raise errors at all: PUSH_ERROR/RAISE_ERROR (execute.c:761-780) checks
// RUN_ACTIV.debug and, when clear, pushes the error as an ordinary value for the expression
// instead of unwinding -- which core code deliberately relies on to probe for missing
// verbs/properties without a try/except. How many such verbs a core has is a direct measure
// of how much it depends on that behavior.
report_nondebug_verbs :: proc(db: ^dbfile.Database) {
	const_debug_bit :: 8 // VF_DEBUG
	nd, total := 0, 0
	for _, obj in db.objects {
		for v in obj.verbdefs {
			total += 1
			if v.perms & const_debug_bit == 0 {
				nd += 1
			}
		}
	}
	fmt.printfln("\nverbs with the `d' (debug) flag CLEAR: %d of %d", nd, total)
}

// check_roundtrip writes the database back out and reloads it, comparing structural counts:
// the same check dbfile/roundtrip_test.odin makes for LambdaCore, which is what checkpointing
// this core would depend on.
check_roundtrip :: proc(db: ^dbfile.Database) -> (problems: int) {
	tmp := "/tmp/jhverify_roundtrip.db"
	defer os.remove(tmp)
	if !dbfile.save_database(db, tmp) {
		fmt.println("\nround trip: SAVE FAILED")
		return 1
	}
	db2, lerr := dbfile.load_database(tmp)
	defer dbfile.database_destroy(&db2)
	if lerr.stage != "" {
		fmt.printfln("\nround trip: RELOAD FAILED at %s: %v", lerr.stage, lerr.err)
		return 1
	}
	nv1, np1, npv1 := 0, 0, 0
	nv2, np2, npv2 := 0, 0, 0
	for _, o in db.objects {
		nv1 += len(o.verbdefs)
		npv1 += len(o.propvals)
		for v in o.verbdefs do if v.has_program {np1 += 1}
	}
	for _, o in db2.objects {
		nv2 += len(o.verbdefs)
		npv2 += len(o.propvals)
		for v in o.verbdefs do if v.has_program {np2 += 1}
	}
	ok := db2.version == db.version && len(db2.objects) == len(db.objects) &&
		db2.max_oid == db.max_oid && len(db2.users) == len(db.users) &&
		len(db2.forked_tasks) == len(db.forked_tasks) &&
		nv1 == nv2 && np1 == np2 && npv1 == npv2
	fmt.printfln(
		"\nround trip (save + reload): objects %d/%d, verbs %d/%d, programs %d/%d, propvals %d/%d -- %s",
		len(db.objects), len(db2.objects), nv1, nv2, np1, np2, npv1, npv2,
		ok ? "identical" : "MISMATCH",
	)
	return ok ? 0 : 1
}
