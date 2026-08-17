package compiler

import "core:strings"
import "core:testing"

@(private = "file")
parse_ok :: proc(t: ^testing.T, src: string) -> Parse_Result {
	r := parse_program(src, DBV_Float)
	for e in r.errors {
		testing.expectf(t, false, "parse error: %s", e)
	}
	return r
}

@(private = "file")
result_destroy :: proc(r: ^Parse_Result) {
	free_stmts(r.body)
	name_table_destroy(&r.names)
	for e in r.errors {
		delete(e)
	}
	delete(r.errors)
}

@(test)
test_parse_unary_minus_binds_tighter_than_exp :: proc(t: ^testing.T) {
	// -2^2 must be (-2)^2 == 4, NOT -(2^2) == -4 -- unary(8) > exp(7) in the precedence table.
	r := parse_ok(t, "return -2^2;")
	defer result_destroy(&r)
	testing.expect(t, len(r.body) == 1)
	ret := r.body[0].(^Stmt_Return)
	bin := ret.expr.(^Expr_Binary)
	testing.expect(t, bin.op == .Exp)
	lhs := bin.lhs.(^Expr_Var)
	testing.expect(t, lhs.value.type == .Int && lhs.value.data.num == -2) // folded, not wrapped in Negate
}

@(test)
test_parse_or_and_share_precedence_left_to_right :: proc(t: ^testing.T) {
	// Unlike C, `||`/`&&` are the SAME precedence in MOO -- `a || b && c` groups as
	// `(a || b) && c`, not `a || (b && c)`.
	r := parse_ok(t, "return a || b && c;")
	defer result_destroy(&r)
	ret := r.body[0].(^Stmt_Return)
	top := ret.expr.(^Expr_Binary)
	testing.expect(t, top.op == .And)
	_, lhs_is_or := top.lhs.(^Expr_Binary)
	testing.expect(t, lhs_is_or)
}

@(test)
test_parse_property_and_verb_call_desugar :: proc(t: ^testing.T) {
	r := parse_ok(t, `x = $foo; y = $bar(1, 2);`)
	defer result_destroy(&r)
	testing.expect(t, len(r.body) == 2)

	s1 := r.body[0].(^Stmt_Expr)
	a1 := s1.expr.(^Expr_Assign)
	prop := a1.value.(^Expr_Prop)
	obj := prop.obj.(^Expr_Var)
	testing.expect(t, obj.value.type == .Obj && obj.value.data.obj == 0)
	name := prop.prop.(^Expr_Var)
	testing.expect(t, name.value.type == .Str && name.value.data.str.s == "foo")

	s2 := r.body[1].(^Stmt_Expr)
	a2 := s2.expr.(^Expr_Assign)
	vc := a2.value.(^Expr_Verb_Call)
	testing.expect(t, len(vc.args) == 2)
}

@(test)
test_parse_scatter_assignment :: proc(t: ^testing.T) {
	r := parse_ok(t, "{a, ?b = 5, @c} = args;")
	defer result_destroy(&r)
	s := r.body[0].(^Stmt_Expr)
	asg := s.expr.(^Expr_Assign)
	sc := asg.target.(^Expr_Scatter)
	testing.expect(t, len(sc.items) == 3)
	testing.expect(t, sc.items[0].kind == .Required)
	testing.expect(t, sc.items[1].kind == .Optional && sc.items[1].default != nil)
	testing.expect(t, sc.items[2].kind == .Rest)
}

@(test)
test_parse_plain_list_assignment_becomes_scatter :: proc(t: ^testing.T) {
	// `{a, b} = expr` with no `?`/`@` at all is still scattering-assignment sugar --
	// ports the generic EXPR_LIST -> EXPR_SCATTER rewrite in parser.y's `=` action.
	r := parse_ok(t, "{a, b} = args;")
	defer result_destroy(&r)
	s := r.body[0].(^Stmt_Expr)
	asg := s.expr.(^Expr_Assign)
	sc, ok := asg.target.(^Expr_Scatter)
	testing.expect(t, ok)
	if ok {
		testing.expect(t, len(sc.items) == 2)
		testing.expect(t, sc.items[0].kind == .Required)
		testing.expect(t, sc.items[1].kind == .Required)
	}
}

@(test)
test_parse_for_range_and_try_except :: proc(t: ^testing.T) {
	r := parse_ok(t, `
		for i in [1..10]
			try
				x = x + i;
			except e (E_DIV)
				continue;
			endtry
		endfor
	`)
	defer result_destroy(&r)
	loop := r.body[0].(^Stmt_Range_Loop)
	testing.expect(t, len(loop.body) == 1)
	te := loop.body[0].(^Stmt_Try_Except)
	testing.expect(t, len(te.excepts) == 1)
	testing.expect(t, len(te.excepts[0].codes) == 1)
}

@(test)
test_parse_catch_expr :: proc(t: ^testing.T) {
	r := parse_ok(t, "x = `1 / 0 ! E_DIV => -1';")
	defer result_destroy(&r)
	s := r.body[0].(^Stmt_Expr)
	asg := s.expr.(^Expr_Assign)
	c := asg.value.(^Expr_Catch)
	testing.expect(t, len(c.codes) == 1)
	testing.expect(t, c.handler != nil)
}

@(test)
test_parse_unknown_builtin_marked_unknown :: proc(t: ^testing.T) {
	r := parse_ok(t, "this_is_not_a_real_builtin(1);")
	defer result_destroy(&r)
	s := r.body[0].(^Stmt_Expr)
	call := s.expr.(^Expr_Call)
	testing.expect(t, !call.is_known)

	r2 := parse_ok(t, "tostr(1);")
	defer result_destroy(&r2)
	s2 := r2.body[0].(^Stmt_Expr)
	call2 := s2.expr.(^Expr_Call)
	testing.expect(t, call2.is_known)
}

@(test)
test_unparse_round_trip_matches_ast_shape :: proc(t: ^testing.T) {
	src := `
		if (x > 0)
			return x + 1;
		elseif (x < 0)
			return -x;
		else
			return 0;
		endif
	`
	r1 := parse_ok(t, src)
	text := unparse_program(r1.body, &r1.names)
	defer delete(text)

	r2 := parse_program(text, DBV_Float)
	testing.expect(t, len(r2.errors) == 0)

	c1 := r1.body[0].(^Stmt_Cond)
	c2 := r2.body[0].(^Stmt_Cond)
	testing.expect(t, len(c1.arms) == len(c2.arms))
	testing.expect(t, (c1.otherwise == nil) == (c2.otherwise == nil))

	result_destroy(&r1)
	free_stmts(r2.body)
	name_table_destroy(&r2.names)
	for e in r2.errors {
		delete(e)
	}
	delete(r2.errors)
}

@(test)
test_unparse_string_escaping_round_trips :: proc(t: ^testing.T) {
	r1 := parse_ok(t, `x = "say \"hi\" \\ bye";`)
	text := unparse_program(r1.body, &r1.names)
	defer delete(text)
	testing.expect(t, strings.contains(text, `\"hi\"`))

	r2 := parse_program(text, DBV_Float)
	testing.expect(t, len(r2.errors) == 0)
	s2 := r2.body[0].(^Stmt_Expr)
	asg := s2.expr.(^Expr_Assign)
	lit := asg.value.(^Expr_Var)
	testing.expect(t, lit.value.data.str.s == `say "hi" \ bye`)

	result_destroy(&r1)
	free_stmts(r2.body)
	name_table_destroy(&r2.names)
	for e in r2.errors {
		delete(e)
	}
	delete(r2.errors)
}

// The unparser must undo the parser's `$foo` desugaring, as unparse.c does: `#0.foo` prints
// as `$foo`, `#0:foo(...)` as `$foo(...)`; anything else -- another object, a non-identifier
// or keyword name, a computed name -- keeps the explicit form. Every corified reference in
// a real core goes through this, so a slip here rewrites `$string_utils` as `#0.string_utils`
// in @list/@edit output (and, via set_verb_code, eventually in the database itself).
@(test)
test_unparse_restores_dollar_sugar :: proc(t: ^testing.T) {
	cases := [][2]string{
		{`$foo;`, `$foo;`},
		{`#0.foo;`, `$foo;`},
		{`$string_utils:left("x", 5);`, `$string_utils:left("x", 5);`},
		{`$foo(1, 2);`, `$foo(1, 2);`},
		{`#0:foo(1, 2);`, `$foo(1, 2);`},
		{`$foo.bar;`, `$foo.bar;`},
		{`#0.("dyn" + x);`, `#0.("dyn" + x);`},
		{`#0.("if");`, `#0.("if");`},
		{`#0.("E_PERM");`, `#0.("E_PERM");`},
		{`#1.foo;`, `#1.foo;`},
		{`x.foo;`, `x.foo;`},
		{`x.("if");`, `x.("if");`},
	}
	for c in cases {
		r := parse_ok(t, c[0])
		text := unparse_program(r.body, &r.names)
		testing.expectf(t, strings.trim_space(text) == c[1], "unparse(%s) = %q, want %q", c[0], strings.trim_space(text), c[1])
		delete(text)
		result_destroy(&r)
	}
}
