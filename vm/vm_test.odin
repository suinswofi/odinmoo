package vm

import "../compiler"
import "../values"
import "core:mem"
import "core:testing"

@(private = "file")
run_src :: proc(t: ^testing.T, src: string, world: ^World) -> Stmt_Result {
	r := compiler.parse_program(src, compiler.DBV_Float)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		for e in r.errors {
			delete(e)
		}
		delete(r.errors)
	}
	for e in r.errors {
		testing.expectf(t, false, "parse error: %s", e)
	}
	act := activation_make(len(r.names.names))
	defer activation_destroy(&act)
	return run(r.body, &r.names, world, &act)
}

@(private = "file")
expect_return_int :: proc(t: ^testing.T, src: string, want: i32, world: ^World = nil) {
	w := world
	local_world: World
	if w == nil {
		local_world = World{}
		w = &local_world
	}
	result := run_src(t, src, w)
	defer {
		if result.signal == .Return {
			values.free_var(result.value)
		} else if result.signal == .Raised {
			error_info_destroy_local(&result.err)
		}
	}
	if !testing.expectf(t, result.signal == .Return, "expected Return, got %v (%s)", result.signal, result.signal == .Raised ? result.err.msg : "") {
		return
	}
	testing.expectf(t, result.value.type == .Int, "expected Int result, got %v", result.value.type)
	testing.expectf(t, result.value.data.num == want, "expected %d, got %d", want, result.value.data.num)
}

@(private = "file")
expect_raised :: proc(t: ^testing.T, src: string, code: values.Error) {
	local_world: World
	result := run_src(t, src, &local_world)
	defer {
		if result.signal == .Return {
			values.free_var(result.value)
		} else if result.signal == .Raised {
			error_info_destroy_local(&result.err)
		}
	}
	testing.expectf(t, result.signal == .Raised, "expected Raised, got %v", result.signal)
	if result.signal == .Raised {
		testing.expectf(t, result.err.code == code, "expected %v, got %v", code, result.err.code)
	}
}

@(test)
test_arithmetic_basic :: proc(t: ^testing.T) {
	expect_return_int(t, "return 1 + 2 * 3;", 7)
	expect_return_int(t, "return (1 + 2) * 3;", 9)
	expect_return_int(t, "return 2 ^ 10;", 1024)
	expect_return_int(t, "return -2^2;", 4) // unary binds tighter than ^
	expect_return_int(t, "return 7 % 3;", 1)
	expect_return_int(t, "return 10 / 3;", 3)
}

@(test)
test_arithmetic_strict_no_int_float_coercion :: proc(t: ^testing.T) {
	// MOO does not auto-convert between int and float -- this is E_TYPE, not 2.5.
	expect_raised(t, "return 1 + 1.5;", .E_TYPE)
	expect_raised(t, "return 1 < 1.5;", .E_TYPE)
}

@(test)
test_division_and_modulus_by_zero :: proc(t: ^testing.T) {
	expect_raised(t, "return 1 / 0;", .E_DIV)
	expect_raised(t, "return 1 % 0;", .E_DIV)
}

@(test)
test_string_concat_and_comparison :: proc(t: ^testing.T) {
	w := World{}
	r := run_src(t, `return "foo" + "bar";`, &w)
	defer values.free_var(r.value)
	testing.expect(t, r.signal == .Return)
	testing.expect(t, r.value.type == .Str)
	testing.expect(t, r.value.data.str.s == "foobar")

	expect_return_int(t, `return "abc" < "abd";`, 1)
	// Surprising MOO trivia, confirmed against execute.c's OP_EQ (`equality(rhs, lhs, 0)`
	// -- the 0 is case_matters): `==` is case-INsensitive for strings. equal() the builtin
	// (Phase 5) is the case-sensitive one.
	expect_return_int(t, `return "ABC" == "abc";`, 1)
}

@(test)
test_and_or_short_circuit_yield_operand_value :: proc(t: ^testing.T) {
	expect_return_int(t, "return 0 && 5;", 0)
	expect_return_int(t, "return 3 && 5;", 5)
	expect_return_int(t, "return 3 || 5;", 3)
	expect_return_int(t, "return 0 || 5;", 5)
	// Same precedence, left-to-right: (1 || 0) && 0 == 0, not 1 || (0 && 0) == 1.
	expect_return_int(t, "return 1 || 0 && 0;", 0)
}

@(test)
test_ternary_and_unary :: proc(t: ^testing.T) {
	expect_return_int(t, "return 1 ? 10 | 20;", 10)
	expect_return_int(t, "return 0 ? 10 | 20;", 20)
	expect_return_int(t, "return !0;", 1)
	expect_return_int(t, "return !5;", 0)
}

@(test)
test_list_index_and_range :: proc(t: ^testing.T) {
	expect_return_int(t, "return {10, 20, 30}[2];", 20)
	expect_raised(t, "return {10, 20, 30}[5];", .E_RANGE)
	expect_raised(t, "return {10, 20, 30}[0];", .E_RANGE)

	w := World{}
	r := run_src(t, "return {10, 20, 30, 40}[2..3];", &w)
	defer values.free_var(r.value)
	testing.expect(t, r.value.type == .List)
	testing.expect(t, values.list_len(r.value) == 2)
	testing.expect(t, values.list_get(r.value, 1).data.num == 20)
}

@(test)
test_list_assignment_cow :: proc(t: ^testing.T) {
	src := `
		x = {1, 2, 3};
		y = x;
		y[1] = 99;
		return x[1] + y[1] * 100;
	`
	// x unaffected by mutating y (COW): x[1]==1, y[1]==99 -> 1 + 9900 == 9901
	expect_return_int(t, src, 9901)
}

@(test)
test_nested_index_assignment :: proc(t: ^testing.T) {
	src := `
		x = {{1, 2}, {3, 4}};
		x[1][2] = 99;
		return x[1][2];
	`
	expect_return_int(t, src, 99)
}

@(test)
test_range_assignment_on_string :: proc(t: ^testing.T) {
	w := World{}
	r := run_src(t, `s = "hello world"; s[1..5] = "HELLO"; return s;`, &w)
	defer values.free_var(r.value)
	testing.expect(t, r.value.type == .Str)
	testing.expect(t, r.value.data.str.s == "HELLO world")
}

@(test)
test_dollar_length_in_index_and_range :: proc(t: ^testing.T) {
	expect_return_int(t, "x = {1,2,3,4,5}; return x[$];", 5)
	w := World{}
	r := run_src(t, "x = {1,2,3,4,5}; return x[2..$];", &w)
	defer values.free_var(r.value)
	testing.expect(t, values.list_len(r.value) == 4)
}

@(test)
test_control_flow_if_elseif_else :: proc(t: ^testing.T) {
	src := `
		x = 5;
		if (x > 10)
			return 1;
		elseif (x > 3)
			return 2;
		else
			return 3;
		endif
	`
	expect_return_int(t, src, 2)
}

@(test)
test_for_list_loop :: proc(t: ^testing.T) {
	src := `
		total = 0;
		for x in ({1, 2, 3, 4, 5})
			total = total + x;
		endfor
		return total;
	`
	expect_return_int(t, src, 15)
}

@(test)
test_for_range_loop :: proc(t: ^testing.T) {
	src := `
		total = 0;
		for i in [1..10]
			total = total + i;
		endfor
		return total;
	`
	expect_return_int(t, src, 55)
}

@(test)
test_while_break_continue_named :: proc(t: ^testing.T) {
	src := `
		total = 0;
		i = 0;
		while outer (1)
			i = i + 1;
			if (i > 10)
				break outer;
			endif
			if (i % 2 == 0)
				continue outer;
			endif
			total = total + i;
		endwhile
		return total;
	`
	// sums odd numbers 1..9 (loop stops once i>10): 1+3+5+7+9 = 25
	expect_return_int(t, src, 25)
}

@(test)
test_nested_loop_named_break_skips_inner :: proc(t: ^testing.T) {
	src := `
		count = 0;
		for i in [1..3]
			for j in [1..3]
				if (j == 2)
					break;
				endif
				count = count + 1;
			endfor
		endfor
		return count;
	`
	// inner loop breaks (unnamed -> innermost) after j==1 each time: 3 outer iterations * 1 = 3
	expect_return_int(t, src, 3)
}

@(test)
test_try_except_catches_matching_code :: proc(t: ^testing.T) {
	src := `
		try
			return 1 / 0;
		except e (E_DIV)
			return 42;
		endtry
	`
	expect_return_int(t, src, 42)
}

@(test)
test_try_except_binds_exception_tuple :: proc(t: ^testing.T) {
	src := `
		try
			return 1 / 0;
		except e (E_DIV)
			return e[1] == E_DIV;
		endtry
	`
	expect_return_int(t, src, 1)
}

@(test)
test_try_except_any_catches_everything :: proc(t: ^testing.T) {
	src := `
		try
			return {1,2,3}[10];
		except e (ANY)
			return 7;
		endtry
	`
	expect_return_int(t, src, 7)
}

@(test)
test_try_except_unmatched_propagates :: proc(t: ^testing.T) {
	src := `
		try
			return 1 / 0;
		except e (E_TYPE)
			return 42;
		endtry
	`
	expect_raised(t, src, .E_DIV)
}

@(test)
test_try_finally_runs_on_normal_and_return :: proc(t: ^testing.T) {
	src := `
		x = 0;
		try
			x = 1;
		finally
			x = x + 10;
		endtry
		return x;
	`
	expect_return_int(t, src, 11)
}

@(test)
test_try_finally_runs_despite_raised_error :: proc(t: ^testing.T) {
	src := `
		x = 0;
		try
			try
				x = 1 / 0;
			finally
				x = 99;
			endtry
		except e (E_DIV)
			return x;
		endtry
	`
	expect_return_int(t, src, 99)
}

@(test)
test_catch_expr_with_default :: proc(t: ^testing.T) {
	expect_return_int(t, "return `1 / 0 ! E_DIV => -1';", -1)
}

@(test)
test_catch_expr_without_default_yields_code :: proc(t: ^testing.T) {
	src := "return `1 / 0 ! E_DIV' == E_DIV;"
	expect_return_int(t, src, 1)
}

@(test)
test_scatter_assignment_required_optional_rest :: proc(t: ^testing.T) {
	src := `
		{a, ?b = 100, @c} = {1, 2, 3, 4};
		return a + b + length(c);
	`
	m := mock_world_init()
	defer mock_world_destroy(&m)
	world := make_mock_world(&m)
	expect_return_int(t, src, 1 + 2 + 2, &world) // a=1, b=2 (consumed from list), c={3,4} len 2
}

@(test)
test_scatter_arity_error :: proc(t: ^testing.T) {
	expect_raised(t, "{a, b} = {1};", .E_ARGS)
}

@(test)
test_property_get_set_via_world :: proc(t: ^testing.T) {
	m := mock_world_init()
	defer mock_world_destroy(&m)
	world := make_mock_world(&m)

	src := `
		#0.foo = 42;
		return #0.foo;
	`
	expect_return_int(t, src, 42, &world)
}

@(test)
test_property_not_found_raises :: proc(t: ^testing.T) {
	m := mock_world_init()
	defer mock_world_destroy(&m)
	world := make_mock_world(&m)
	result := run_src(t, "return #0.nope;", &world)
	defer {
		if result.signal == .Raised {
			error_info_destroy_local(&result.err)
		} else {
			values.free_var(result.value)
		}
	}
	testing.expect(t, result.signal == .Raised)
	testing.expect(t, result.err.code == .E_PROPNF)
}

@(test)
test_verb_call_via_world :: proc(t: ^testing.T) {
	m := mock_world_init()
	defer mock_world_destroy(&m)
	mock_define_verb(&m, 0, "double", "return args[1] * 2;")
	world := make_mock_world(&m)

	// #0:double(21) -- a bare int argument becomes args == {21}; wrapping it in braces
	// would instead pass a one-element LIST as the sole argument (args == {{21}}).
	expect_return_int(t, "return #0:double(21);", 42, &world)
}

@(test)
test_dollar_style_shorthand_desugars_to_sysobj :: proc(t: ^testing.T) {
	m := mock_world_init()
	defer mock_world_destroy(&m)
	mock_define_verb(&m, 0, "greet", `return "hi";`)
	world := make_mock_world(&m)

	src := `return $greet();`
	r := run_src(t, src, &world)
	defer values.free_var(r.value)
	testing.expect(t, r.signal == .Return)
	testing.expect(t, r.value.type == .Str && r.value.data.str.s == "hi")
}

@(test)
test_builtin_call_via_world :: proc(t: ^testing.T) {
	m := mock_world_init()
	defer mock_world_destroy(&m)
	world := make_mock_world(&m)

	src := `return tostr("n=", 5);`
	r := run_src(t, src, &world)
	defer values.free_var(r.value)
	testing.expect(t, r.signal == .Return)
	testing.expect(t, r.value.type == .Str && r.value.data.str.s == "n=5")
}

// test_caught_statement_type_error_frees_its_message covers a whole class of ownership bug
// rather than one expression: Error_Info.msg is owned, so every raise site has to hand over an
// allocated string. Two statement-level raises (a `for` over a non-list, and a range loop with
// non-integer bounds) used to pass a string *literal* instead, which meant delete()ing static
// data the moment anything handled the exception -- invisible until the error is actually
// caught, i.e. in exactly the try/except code written to handle it.
//
// This runs each case under its own tracking allocator and asserts bad_free_array is empty,
// because the enclosing test runner reports invalid frees as warnings rather than failures --
// checking it here is what makes this an actual regression test and not just a behavior test
// that would keep passing while quietly corrupting the heap.
@(test)
test_caught_statement_type_error_frees_its_message :: proc(t: ^testing.T) {
	for src in ([]string{
		`try for x in (5) endfor except e (ANY) return e[1] == E_TYPE; endtry return 0;`,
		`try for i in ["a".."b"] endfor except e (ANY) return e[1] == E_TYPE; endtry return 0;`,
	}) {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
		{
			context.allocator = mem.tracking_allocator(&track)
			expect_return_int(t, src, 1)
		}
		if len(track.bad_free_array) > 0 {
			testing.expectf(t, false, "%s: %d invalid free(s), first at %v", src, len(track.bad_free_array), track.bad_free_array[0].location)
		}
		mem.tracking_allocator_destroy(&track)
	}
}

// Labelled break/continue must target the NAMED loop, not the innermost one. This was broken
// for as long as it existed: the parser registered a loop's variable in the name table only
// AFTER parsing the loop body, so `break i` inside the body resolved `i` with find() against a
// table that did not contain it yet, got -1, and silently degraded to an unlabelled break.
//
// The reason it survived the 4456-verb corpus test is worth keeping in mind for anything
// similar: that test checks parse -> unparse -> reparse SHAPE, never runtime behaviour, and
// the bug only bites when the body does not otherwise mention the loop variable before
// breaking on it -- which real verb code, reading the variable it is iterating, almost always
// does. Every case below is written so the label is the only reference.
@(test)
test_labelled_break_targets_the_named_loop :: proc(t: ^testing.T) {
	expect_return_int(t, `n = 0; for i in [1..3] for j in [1..3] break i; endfor n = n + 100; endfor return n;`, 0)
	expect_return_int(t, `n = 0; for i in [1..3] for j in [1..3] break j; endfor n = n + 100; endfor return n;`, 300)
	expect_return_int(t, `n = 0; for i in [1..3] for j in [1..3] break; endfor n = n + 100; endfor return n;`, 300)
	expect_return_int(t, `n = 0; for i in ({1, 2, 3}) for j in ({1, 2}) break i; endfor n = n + 100; endfor return n;`, 0)
	expect_return_int(t, `n = 0; a = 0; while lbl (a < 3) a = a + 1; while (1) break lbl; endwhile n = n + 100; endwhile return n;`, 0)
}

@(test)
test_labelled_continue_targets_the_named_loop :: proc(t: ^testing.T) {
	// `continue i` abandons the rest of the inner loop AND the rest of this outer iteration.
	expect_return_int(t, `n = 0; for i in [1..3] for j in [1..3] if (j == 2) continue i; endif n = n + 1; endfor endfor return n;`, 3)
	// ... where the unlabelled form only skips the rest of the inner iteration: 2 per outer.
	expect_return_int(t, `n = 0; for i in [1..3] for j in [1..3] if (j == 2) continue; endif n = n + 1; endfor endfor return n;`, 6)
}

// A range loop is bounded by definition, so it must terminate even when its bound is the
// largest representable integer. It used to increment past `to` before re-testing, and i32
// addition wraps: the counter went from max(i32) to min(i32), which is still <= to, and the
// loop restarted from the bottom of the range and never finished. Distinct from this port's
// documented lack of a tick budget -- that allows an unbounded loop to be WRITTEN; this made
// a loop the language guarantees is finite run forever.
@(test)
test_range_loop_terminates_at_integer_limits :: proc(t: ^testing.T) {
	expect_return_int(t, `n = 0; for i in [2147483645..2147483647] n = n + 1; endfor return n;`, 3)
	expect_return_int(t, `n = 0; for i in [-2147483647 - 1 .. -2147483646] n = n + 1; endfor return n;`, 3)
	expect_return_int(t, `n = 0; for i in [1..3] n = n + 1; endfor return n;`, 3)
	expect_return_int(t, `n = 0; for i in [3..1] n = n + 1; endfor return n;`, 0) // empty range
}

// INT_MIN / -1 and INT_MIN % -1 overflow, and on x86 that is a hardware trap (the same SIGFPE
// as dividing by zero), not a wrong answer -- it took the whole server down from any MOO
// expression, with no error to catch. Wrapping matches what this port already does at the same
// boundary for -(-2147483648) and abs(-2147483648).
@(test)
test_integer_division_at_the_overflow_boundary :: proc(t: ^testing.T) {
	expect_return_int(t, `x = -2147483647 - 1; return x / -1;`, -2147483648)
	expect_return_int(t, `x = -2147483647 - 1; return x % -1;`, 0)
	// Ordinary division is unaffected, including MOO's truncate-toward-zero convention.
	expect_return_int(t, `return 7 / 2;`, 3)
	expect_return_int(t, `return -7 / 2;`, -3)
	expect_return_int(t, `return -7 % 3;`, -1)
}

// ---- Task budget (budget.odin) ----

@(private = "file")
expect_budget_abort :: proc(t: ^testing.T, label: string, src: string) {
	local_world := World{}
	result := run_src(t, src, &local_world)
	defer {
		if result.signal == .Return {
			values.free_var(result.value)
		} else if result.signal == .Raised {
			error_info_destroy_local(&result.err)
		}
	}
	if !testing.expectf(t, result.signal == .Raised, "%s: expected the task to be aborted, got %v", label, result.signal) {
		return
	}
	testing.expectf(t, result.err.uncatchable, "%s: the abort must be uncatchable", label)
	testing.expectf(t, result.err.code == .E_QUOTA, "%s: expected E_QUOTA, got %v", label, result.err.code)
}

// Every shape of unterminating loop has to be charged. An empty-bodied one is the case that
// matters most and is easiest to miss: it runs no statements at all, so a budget charged
// only per statement never touches it (see charge_iteration in exec_stmt.odin). In the real
// server such a loop holds big_lock forever, which is not a hung task but a hung server.
@(test)
test_unterminating_loops_are_aborted :: proc(t: ^testing.T) {
	expect_budget_abort(t, "while with a body", "x = 0; while (1) x = x + 1; endwhile return x;")
	expect_budget_abort(t, "empty while", "while (1) endwhile return 1;")
	expect_budget_abort(t, "empty range for", "for i in [1..2000000000] endfor return 1;")
	expect_budget_abort(t, "nested empty while", "while (1) while (1) endwhile endwhile return 1;")
}

// The abort must not be interceptable, or the budget buys nothing: a handler that swallows
// it puts the task straight back into the loop it was aborted out of.
@(test)
test_budget_abort_is_not_catchable :: proc(t: ^testing.T) {
	expect_budget_abort(t, "except (ANY)", "while (1) try x = 1; except (ANY) endtry endwhile return 1;")
	expect_budget_abort(t, "try/except around the loop", "try while (1) endwhile except (ANY) return 2; endtry return 1;")
	expect_budget_abort(t, "try/finally", "try while (1) endwhile finally return 3; endtry")
}

// eval_catch (the `expr ! codes => handler'` form) has its own copy of the same guard, on the
// expression side rather than the statement side. Reaching it needs a call, since no bare
// expression can loop -- so the loop lives in a verb the mock world dispatches to.
@(test)
test_budget_abort_is_not_catchable_by_backtick :: proc(t: ^testing.T) {
	m := mock_world_init()
	defer mock_world_destroy(&m)
	mock_define_verb(&m, 1, "spin", "while (1) endwhile return 1;")
	world := make_mock_world(&m)
	result := run_src(t, "return `#1:spin() ! ANY => 0';", &world)
	defer {
		if result.signal == .Return {
			values.free_var(result.value)
		} else if result.signal == .Raised {
			error_info_destroy_local(&result.err)
		}
	}
	if !testing.expectf(t, result.signal == .Raised, "expected the abort to pass through the catch, got %v", result.signal) {
		return
	}
	testing.expect(t, result.err.uncatchable)
}

// One task, one allowance. A verb that spends most of the budget must leave the rest of the
// task short of it -- if each call were handed a fresh Task_Budget, "call another verb" would
// be all it took to run forever. Each call below burns ~20000 of the 30000 ticks, so the
// first can succeed and the second cannot.
//
// (Deliberately NOT tested by unbounded verb RECURSION: the ceiling on that is objdb's
// MAX_VERB_DEPTH, which this package's mock World has no equivalent of, so recursing here
// overflows the native stack long before any budget runs out.)
@(test)
test_budget_is_shared_across_verb_calls :: proc(t: ^testing.T) {
	m := mock_world_init()
	defer mock_world_destroy(&m)
	mock_define_verb(&m, 1, "spend", "for i in [1..20000] endfor return 1;")
	world := make_mock_world(&m)
	result := run_src(t, "a = #1:spend(); b = #1:spend(); return 1;", &world)
	defer {
		if result.signal == .Return {
			values.free_var(result.value)
		} else if result.signal == .Raised {
			error_info_destroy_local(&result.err)
		}
	}
	if !testing.expectf(t, result.signal == .Raised, "the second call should exhaust the shared budget, got %v", result.signal) {
		return
	}
	testing.expect(t, result.err.uncatchable)
}

// Ordinary errors stay catchable -- the uncatchable flag must be specific to the budget.
@(test)
test_ordinary_errors_remain_catchable :: proc(t: ^testing.T) {
	expect_return_int(t, "try return 1/0; except (E_DIV) return 7; endtry", 7)
	expect_return_int(t, "return `(1/0) ! ANY => 9';", 9)
}

// A loop well inside the allowance runs to completion, and ticks_left() reports against the
// real remainder rather than a constant -- which is what makes the in-database
// suspend_if_needed idiom work.
@(test)
test_budget_leaves_ordinary_work_alone :: proc(t: ^testing.T) {
	expect_return_int(t, "x = 0; for i in [1..1000] x = x + 1; endfor return x;", 1000)
	local_world := World{}
	r := run_src(t, "n = 0; for i in [1..100] n = n + 1; endfor return n;", &local_world)
	defer {
		if r.signal == .Return {values.free_var(r.value)} else if r.signal == .Raised {error_info_destroy_local(&r.err)}
	}
	testing.expect(t, r.signal == .Return)
}

// ---- Regression: `for x in (expr)` requires a LIST ----
//
// "The expression is evaluated and should return a list; if it does not, E_TYPE is raised"
// (Programmer's Manual, 4.1.2). This used to also accept a string and iterate its bytes -- a
// Stunt/ToastStunt extension that a comment here wrongly described as MOO behaviour. Accepting
// it turned code that should have raised E_TYPE on an unexpected string into code that quietly
// looped over its characters instead.
@(test)
test_for_list_loop_requires_a_list :: proc(t: ^testing.T) {
	expect_raised(t, `for c in ("abc") endfor return 1;`, .E_TYPE)
	expect_raised(t, `for c in (17) endfor return 1;`, .E_TYPE)
	expect_raised(t, `for c in (#3) endfor return 1;`, .E_TYPE)
	// A list still iterates, and an empty one is not an error.
	expect_return_int(t, `n = 0; for x in ({4, 5, 6}) n = n + x; endfor return n;`, 15)
	expect_return_int(t, `n = 7; for x in ({}) n = 0; endfor return n;`, 7)
}
