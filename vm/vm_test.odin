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
