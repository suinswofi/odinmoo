package objdb

// Behaviour checked against the LambdaMOO 1.8.3 sources, run against the real LambdaCore.db.
// Each expectation is what the original server answers for the same code; each was at some
// point answered differently here.

import "../builtins"
import "../compiler"
import "../dbfile"
import "../tasks"
import "../values"
import "../vm"
import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
Parity :: struct {
	db:    dbfile.Database,
	sched: tasks.Scheduler,
	ow:    Object_World,
	world: vm.World,
}

@(private = "file")
parity_open :: proc(t: ^testing.T) -> ^Parity {
	p := new(Parity)
	lerr: dbfile.Load_Error
	p.db, lerr = dbfile.load_database("LambdaCore.db")
	if lerr.stage != "" {
		testing.fail_now(t, "could not load LambdaCore.db -- run from the repo root")
	}
	p.sched = tasks.scheduler_init()
	p.ow = object_world_init(&p.db, &p.sched)
	p.world = make_world(&p.ow)
	load_server_options(&p.ow)
	return p
}

@(private = "file")
parity_close :: proc(p: ^Parity) {
	tasks.scheduler_shutdown(&p.sched)
	object_world_destroy(&p.ow)
	tasks.scheduler_destroy(&p.sched)
	dbfile.database_destroy(&p.db)
	free(p)
}

// moo runs `src` (statements) as `progr` from a verb-less root frame and returns toliteral() of
// its value, or "!E_FOO" if it raised.
@(private = "file")
moo :: proc(p: ^Parity, src: string, progr := values.Objid(2)) -> string {
	r := compiler.parse_program(src, p.db.version)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		for e in r.errors {
			delete(e)
		}
		delete(r.errors)
	}
	if len(r.errors) > 0 {
		return fmt.tprintf("!PARSE %s", r.errors[0])
	}
	act := vm.activation_make(len(r.names.names), &r.names)
	defer vm.activation_destroy(&act)
	act.this, act.caller, act.verb_loc, act.caller_programmer = values.NOTHING, values.NOTHING, values.NOTHING, values.NOTHING
	act.programmer, act.player = progr, progr
	budget: vm.Task_Budget
	vm.budget_open(&budget, &p.world, false)
	defer vm.budget_close(&budget)
	act.budget = &budget
	res := vm.run(r.body, &r.names, &p.world, &act)
	switch res.signal {
	case .Raised:
		out := fmt.tprintf("!%s", compiler.error_name(res.err.code))
		vm.error_info_destroy(&res.err)
		return out
	case .Return:
		defer values.free_var(res.value)
		lit := make([]values.Var, 1)
		lit[0] = values.var_ref(res.value)
		lr, _ := builtins.call("toliteral", values.list_val(lit))
		defer values.free_var(lr.value)
		return strings.clone(lr.value.data.str.s, context.temp_allocator)
	case .Normal, .Break, .Continue:
	}
	return "0"
}

@(private = "file")
expect_moo :: proc(t: ^testing.T, p: ^Parity, src, want: string, progr := values.Objid(2), loc := #caller_location) {
	got := moo(p, src, progr)
	testing.expectf(t, got == want, "%s\n  got:  %s\n  want: %s", src, got, want, loc = loc)
}

@(test)
test_parity_builtin_argument_checks :: proc(t: ^testing.T) {
	p := parity_open(t)
	defer parity_close(p)
	// call_bi_func checks counts and declared types for every built-in, uniformly.
	expect_moo(t, p, "return sqrt();", "!E_ARGS")
	expect_moo(t, p, "return strsub(1, 2, 3);", "!E_TYPE")
	expect_moo(t, p, "return atan(1.0, 1.0) > 0.78;", "1") // the two-argument (atan2) form
	expect_moo(t, p, "return function_info(\"strsub\");", `{"strsub", 3, 4, {2, 2, 2, -1}}`)
	// A function the server lacks: E_INVARG, with the name as the value.
	expect_moo(t, p, "try call_function(\"nope\"); except e (ANY) return {e[1], e[2], e[3]}; endtry", `{E_INVARG, "Unknown built-in function", "nope"}`)
	// A built-in's own error carries the standard message.
	expect_moo(t, p, "try verb_info(#1, 0); except e (ANY) return e[1..2]; endtry", `{E_INVARG, "Invalid argument"}`)
	expect_moo(t, p, "return is_player(#-5);", "!E_INVARG")
}

@(test)
test_parity_value_formatting :: proc(t: ^testing.T) {
	p := parity_open(t)
	defer parity_close(p)
	expect_moo(t, p, "return {tostr(0.1 + 0.2), tostr(1.0 / 3.0), tostr(1e15), toliteral(10.0)};", `{"0.3", "0.333333333333333", "1e+15", "10.0"}`)
	expect_moo(t, p, "return floatstr(1.0 / 3.0, 25, 1);", `"3.3333333333333331483e-01"`)
	// ctime() blanks a leading zero in the day of the month (ctime(3)'s layout).
	expect_moo(t, p, "s = ctime(388800); return {s[9], s[10]};", `{" ", "5"}`)
	expect_moo(t, p, "return {string_hash(\"abc\"), encode_binary(\"a\", {10, \"~\"}, 255), decode_binary(\"a~0Ab\")};", `{"900150983CD24FB0D6963F7D28E17F72", "a~0a~7e~ff", {"a", 10, "b"}}`)
}

@(test)
test_parity_loops_and_dflag :: proc(t: ^testing.T) {
	p := parity_open(t)
	defer parity_close(p)
	expect_moo(t, p, "r = {}; for o in [#1..#3] r = {@r, o}; endfor return r;", "{#1, #2, #3}")
	expect_moo(t, p, "for x in (5) endfor return 1;", "!E_TYPE")
	// In a verb without the `d' flag a bad `for' just doesn't loop (RAISE_ERROR).
	expect_moo(t, p, `o = create(#1); add_verb(o, {#2, "rx", "t"}, {"this", "none", "this"}); set_verb_code(o, "t", {"for x in (5) endfor", "return 7;"}); return o:t();`, "7")
	// `?'/`|' are %nonassoc in parser.y.
	expect_moo(t, p, "return 1 ? 2 | 0 ? 3 | 4;", "!PARSE Line 1:  syntax error")
}

@(test)
test_parity_stack_lists_and_lines :: proc(t: ^testing.T) {
	p := parity_open(t)
	defer parity_close(p)
	src := `o = create(#1);
add_verb(o, {#2, "rxd", "t"}, {"this", "none", "this"});
set_verb_code(o, "t", {"x = 1;", "if (x)", "  y = {1}[3];", "endif"});
try
  o:t();
except e (ANY)
  return {e[1], e[4][1][2], e[4][1][6], length(e[4][1])};
endtry`
	// The frame that raised, with its listing line (`y = ...` is line 3 of the listing).
	expect_moo(t, p, src, `{E_RANGE, "t", 3, 6}`)
}

@(test)
test_parity_verb_code_and_preps :: proc(t: ^testing.T) {
	p := parity_open(t)
	defer parity_close(p)
	setup := `o = create(#1); add_verb(o, {#2, "rxd", "t"}, {"this", "none", "this"}); set_verb_code(o, "t", {"x = 1 + 2 * 3 - -4;", "if (x) y = (1 + 2) * 3; endif"});`
	expect_moo(t, p, strings.concatenate({setup, " return verb_code(o, \"t\");"}, context.temp_allocator), `{"x = 1 + 2 * 3 - -4;", "if (x)", "  y = (1 + 2) * 3;", "endif"}`)
	expect_moo(t, p, strings.concatenate({setup, " return verb_code(o, \"t\", 1, 0);"}, context.temp_allocator), `{"x = (1 + (2 * 3)) - -4;", "if (x)", "y = (1 + 2) * 3;", "endif"}`)
	// db_match_prep: numbers and the slash forms verb_args() itself reports.
	expect_moo(t, p, `o = create(#1); add_verb(o, {#2, "rxd", "t"}, {"this", "3", "this"}); r = verb_args(o, "t"); set_verb_args(o, "t", r); return {r, verb_args(o, "t")[2]};`, `{{"this", "in/inside/into", "this"}, "in/inside/into"}`)
	expect_moo(t, p, `o = create(#1); return add_verb(o, {#2, "rxd", "t"}, {"this", "in front", "this"});`, "!E_INVARG")
}

@(test)
test_parity_protected_builtin_goes_through_wrapper :: proc(t: ^testing.T) {
	p := parity_open(t)
	defer parity_close(p)
	// $server_options.protect_<name> sends a call that isn't from #0 to #0:bf_<name>, once
	// load_server_options() has been called.
	setup := `add_property($server_options, "protect_length", 1, {#2, "r"});
add_verb(#0, {#2, "rxd", "bf_length"}, {"this", "none", "this"});
set_verb_code(#0, "bf_length", {"return 42;"});
load_server_options();
return length("abc");`
	expect_moo(t, p, setup, "42")
}

// A recursive call under deep expression nesting used to overflow the native stack within the
// verb-depth limit and kill the server (values/stack_guard.odin). It must come back as E_MAXREC.
@(test)
test_parity_deep_nesting_is_an_error_not_a_crash :: proc(t: ^testing.T) {
	p := parity_open(t)
	defer parity_close(p)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "return ")
	for _ in 0 ..< 190 {
		strings.write_string(&b, "(1 + ")
	}
	strings.write_string(&b, "this:r()")
	for _ in 0 ..< 190 {
		strings.write_string(&b, ")")
	}
	strings.write_string(&b, ";")
	body := strings.to_string(b)
	src := strings.concatenate({`o = create(#1); add_verb(o, {#2, "rxd", "r"}, {"this", "none", "this"}); set_verb_code(o, "r", {"`, body, `"}); return o:r();`}, context.temp_allocator)
	expect_moo(t, p, src, "!E_MAXREC")
}
