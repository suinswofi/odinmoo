package compiler

// Recursive-descent/precedence-climbing parser, replacing parser.y's yacc grammar (Odin's
// toolchain has no yacc equivalent). Binding powers below are transcribed directly from the
// grammar's %left/%right/%nonassoc declarations (low to high): assignment(1, right) <
// ternary(2) < or/and(3, same level -- unlike C, `||` and `&&` share one precedence in MOO,
// left-to-right) < comparisons(4) < +-(5) < */%(6) < ^(7, right) < unary !/-(8) <
// postfix .:[ $ (9, tightest). Because unary binds *tighter* than `^`, `-2^2` parses as
// `(-2)^2 == 4`, not `-(2^2)` -- a real gotcha worth flagging since it's the opposite of
// most languages' convention.

import "../values"
import "core:fmt"
import "core:strings"

ASSIGN_BP :: 1
COND_BP :: 2
OR_AND_BP :: 3
COMPARE_BP :: 4
ADDSUB_BP :: 5
MULDIV_BP :: 6
EXP_BP :: 7

Loop_Entry :: struct {
	name:       string, // "" means unnamed
	is_barrier: bool,
}

Parser :: struct {
	lexer:         Lexer,
	cur:           Token,
	names:         Name_Table,
	version:       int,
	errors:        [dynamic]string,
	dollars_depth: int,
	loop_stack:    [dynamic]Loop_Entry,
}

parser_make :: proc(src: string, version: int) -> Parser {
	p := Parser{lexer = lexer_make(src, version), version = version, names = name_table_make(version)}
	p.cur = next_token(&p.lexer)
	return p
}

parser_destroy :: proc(p: ^Parser) {
	lexer_destroy(&p.lexer)
	name_table_destroy(&p.names)
	for e in p.errors {
		delete(e)
	}
	delete(p.errors)
	delete(p.loop_stack)
}

@(private = "file")
parser_error :: proc(p: ^Parser, msg: string) {
	append(&p.errors, fmt.aprintfln("Line %d:  %s", p.cur.line, msg))
}

@(private = "file")
parser_errorf :: proc(p: ^Parser, format: string, args: ..any) {
	msg := fmt.aprintf(format, ..args)
	defer delete(msg)
	parser_error(p, msg)
}

@(private = "file")
advance :: proc(p: ^Parser) -> Token {
	tok := p.cur
	p.cur = next_token(&p.lexer)
	return tok
}

// expect consumes the current token if it matches `kind`, else records an error and leaves
// the parser positioned where it is (best-effort recovery -- real verb code is
// well-formed, so this path exists mainly so a stray malformed program degrades gracefully
// instead of infinite-looping, not to reproduce bison's panic-mode recovery exactly).
@(private = "file")
expect :: proc(p: ^Parser, kind: Token_Kind) -> Token {
	if p.cur.kind != kind {
		parser_errorf(p, "Unexpected token (wanted %v, got %v)", kind, p.cur.kind)
		return p.cur
	}
	return advance(p)
}

Parse_Result :: struct {
	body:   []Stmt,
	names:  Name_Table,
	errors: [dynamic]string,
}

// parse_program ports parse_program()/the `program: statements` rule: a whole verb body.
parse_program :: proc(src: string, version: int) -> Parse_Result {
	p := parser_make(src, version)
	body := parse_statements(&p)
	if p.cur.kind != .EOF {
		parser_errorf(&p, "Unexpected token at end of program: %v", p.cur.kind)
	}
	lexer_destroy(&p.lexer)
	delete(p.loop_stack)
	for e in p.lexer.errors {
		append(&p.errors, e)
	}
	return Parse_Result{body = body, names = p.names, errors = p.errors}
}

@(private = "file")
at_block_end :: proc(p: ^Parser) -> bool {
	#partial switch p.cur.kind {
	case .EOF, .Endif, .Else, .Elseif, .Endfor, .Endwhile, .Endfork, .Endtry, .Except, .Finally:
		return true
	}
	return false
}

parse_statements :: proc(p: ^Parser) -> []Stmt {
	stmts: [dynamic]Stmt
	for !at_block_end(p) {
		s, has := parse_statement(p)
		if has {
			append(&stmts, s)
		}
	}
	return stmts[:]
}

// parse_statement ports the `statement:` production. Returns has=false for a bare `;`
// (which the original represents as a null Stmt* that statements-list-building skips).
parse_statement :: proc(p: ^Parser) -> (stmt: Stmt, has: bool) {
	#partial switch p.cur.kind {
	case .Semi:
		advance(p)
		return nil, false
	case .If:
		return parse_if(p), true
	case .For:
		return parse_for(p), true
	case .While:
		return parse_while(p), true
	case .Fork:
		return parse_fork(p), true
	case .Break:
		advance(p)
		var_id := -1
		if p.cur.kind == .Id {
			tok := advance(p)
			var_id = find(&p.names, tok.str_val)
			check_loop_name(p, tok.str_val, true)
			delete(tok.str_val)
		} else {
			check_loop_name(p, "", true)
		}
		expect(p, .Semi)
		s := new(Stmt_Break)
		s.var_id = var_id
		return s, true
	case .Continue:
		advance(p)
		var_id := -1
		if p.cur.kind == .Id {
			tok := advance(p)
			var_id = find(&p.names, tok.str_val)
			check_loop_name(p, tok.str_val, false)
			delete(tok.str_val)
		} else {
			check_loop_name(p, "", false)
		}
		expect(p, .Semi)
		s := new(Stmt_Continue)
		s.var_id = var_id
		return s, true
	case .Return:
		advance(p)
		s := new(Stmt_Return)
		if p.cur.kind != .Semi {
			s.expr = parse_expr(p, ASSIGN_BP)
		}
		expect(p, .Semi)
		return s, true
	case .Try:
		return parse_try(p), true
	}
	s := new(Stmt_Expr)
	s.expr = parse_expr(p, ASSIGN_BP)
	expect(p, .Semi)
	return s, true
}

@(private = "file")
parse_if :: proc(p: ^Parser) -> Stmt {
	advance(p) // 'if'
	expect(p, .LParen)
	cond := parse_expr(p, ASSIGN_BP)
	expect(p, .RParen)
	body := parse_statements(p)

	arms: [dynamic]Cond_Arm
	append(&arms, Cond_Arm{condition = cond, body = body})
	for p.cur.kind == .Elseif {
		advance(p)
		expect(p, .LParen)
		c := parse_expr(p, ASSIGN_BP)
		expect(p, .RParen)
		b := parse_statements(p)
		append(&arms, Cond_Arm{condition = c, body = b})
	}
	otherwise: []Stmt
	if p.cur.kind == .Else {
		advance(p)
		otherwise = parse_statements(p)
	}
	expect(p, .Endif)

	s := new(Stmt_Cond)
	s.arms = arms[:]
	s.otherwise = otherwise
	return s
}

@(private = "file")
parse_for :: proc(p: ^Parser) -> Stmt {
	advance(p) // 'for'
	id_tok := expect(p, .Id)
	expect(p, .In)

	if p.cur.kind == .LBracket {
		advance(p)
		from := parse_expr(p, ASSIGN_BP)
		expect(p, .To)
		to := parse_expr(p, ASSIGN_BP)
		expect(p, .RBracket)
		push_loop_name(p, id_tok.str_val)
		body := parse_statements(p)
		expect(p, .Endfor)
		pop_loop_name(p)

		s := new(Stmt_Range_Loop)
		s.var_id = find_or_add(&p.names, id_tok.str_val)
		s.from = from
		s.to = to
		s.body = body
		delete(id_tok.str_val)
		return s
	}

	expect(p, .LParen)
	list_expr := parse_expr(p, ASSIGN_BP)
	expect(p, .RParen)
	push_loop_name(p, id_tok.str_val)
	body := parse_statements(p)
	expect(p, .Endfor)
	pop_loop_name(p)

	s := new(Stmt_List_Loop)
	s.var_id = find_or_add(&p.names, id_tok.str_val)
	s.list = list_expr
	s.body = body
	delete(id_tok.str_val)
	return s
}

@(private = "file")
parse_while :: proc(p: ^Parser) -> Stmt {
	advance(p) // 'while'
	name := ""
	name_owned := false
	if p.cur.kind == .Id {
		tok := advance(p)
		name = tok.str_val
		name_owned = true
	}
	expect(p, .LParen)
	cond := parse_expr(p, ASSIGN_BP)
	expect(p, .RParen)
	push_loop_name(p, name)
	body := parse_statements(p)
	expect(p, .Endwhile)
	pop_loop_name(p)

	s := new(Stmt_While)
	s.var_id = name == "" ? -1 : find_or_add(&p.names, name)
	s.condition = cond
	s.body = body
	if name_owned {
		delete(name)
	}
	return s
}

@(private = "file")
parse_fork :: proc(p: ^Parser) -> Stmt {
	advance(p) // 'fork'
	name := ""
	name_owned := false
	if p.cur.kind == .Id {
		tok := advance(p)
		name = tok.str_val
		name_owned = true
	}
	expect(p, .LParen)
	time_expr := parse_expr(p, ASSIGN_BP)
	expect(p, .RParen)
	suspend_loop_scope(p) // break/continue can't cross a fork boundary
	body := parse_statements(p)
	expect(p, .Endfork)
	resume_loop_scope(p)

	s := new(Stmt_Fork)
	s.var_id = name == "" ? -1 : find_or_add(&p.names, name)
	s.time = time_expr
	s.body = body
	if name_owned {
		delete(name)
	}
	return s
}

@(private = "file")
parse_try :: proc(p: ^Parser) -> Stmt {
	advance(p) // 'try'
	body := parse_statements(p)

	if p.cur.kind == .Finally {
		advance(p)
		handler := parse_statements(p)
		expect(p, .Endtry)
		s := new(Stmt_Try_Finally)
		s.body = body
		s.handler = handler
		return s
	}

	arms: [dynamic]Except_Arm
	seen_any := false
	for p.cur.kind == .Except {
		advance(p)
		if seen_any {
			parser_error(p, "Unreachable EXCEPT clause")
		}
		var_id := -1
		if p.cur.kind == .Id {
			tok := advance(p)
			var_id = find_or_add(&p.names, tok.str_val)
			delete(tok.str_val)
		}
		expect(p, .LParen)
		codes := parse_codes(p)
		if codes == nil {
			seen_any = true
		}
		expect(p, .RParen)
		arm_body := parse_statements(p)
		append(&arms, Except_Arm{var_id = var_id, codes = codes, body = arm_body})
	}
	expect(p, .Endtry)

	s := new(Stmt_Try_Except)
	s.body = body
	s.excepts = arms[:]
	return s
}

// parse_codes ports the `codes:` nonterminal: ANY (-> nil) or a non-empty comma list.
@(private = "file")
parse_codes :: proc(p: ^Parser) -> []Arg {
	if p.cur.kind == .Any {
		advance(p)
		return nil
	}
	return parse_ne_arglist(p)
}

// ---- Expressions ----

parse_expr :: proc(p: ^Parser, min_bp: int) -> Expr {
	lhs := parse_unary(p)

	for {
		#partial switch p.cur.kind {
		case .Assign:
			if min_bp > ASSIGN_BP {
				return lhs
			}
			advance(p)
			rhs := parse_expr(p, ASSIGN_BP)
			lhs = build_assign(p, lhs, rhs)
			continue
		case .Question:
			if min_bp > COND_BP {
				return lhs
			}
			advance(p)
			conseq := parse_expr(p, ASSIGN_BP)
			expect(p, .Pipe)
			alt := parse_expr(p, COND_BP + 1)
			c := new(Expr_Cond)
			c.condition = lhs
			c.consequent = conseq
			c.alternate = alt
			lhs = c
			continue
		}

		op, prec, right_assoc, ok := binop_info(p.cur.kind)
		if !ok || prec < min_bp {
			return lhs
		}
		advance(p)
		next_min := right_assoc ? prec : prec + 1
		rhs := parse_expr(p, next_min)
		b := new(Expr_Binary)
		b.op = op
		b.lhs = lhs
		b.rhs = rhs
		lhs = b
	}
}

@(private = "file")
binop_info :: proc(k: Token_Kind) -> (op: Binary_Op, prec: int, right_assoc: bool, ok: bool) {
	#partial switch k {
	case .Or:
		return .Or, OR_AND_BP, false, true
	case .And:
		return .And, OR_AND_BP, false, true
	case .Eq:
		return .Eq, COMPARE_BP, false, true
	case .Ne:
		return .Ne, COMPARE_BP, false, true
	case .Lt:
		return .Lt, COMPARE_BP, false, true
	case .Le:
		return .Le, COMPARE_BP, false, true
	case .Gt:
		return .Gt, COMPARE_BP, false, true
	case .Ge:
		return .Ge, COMPARE_BP, false, true
	case .In:
		return .In, COMPARE_BP, false, true
	case .Plus:
		return .Plus, ADDSUB_BP, false, true
	case .Minus:
		return .Minus, ADDSUB_BP, false, true
	case .Star:
		return .Times, MULDIV_BP, false, true
	case .Slash:
		return .Divide, MULDIV_BP, false, true
	case .Percent:
		return .Mod, MULDIV_BP, false, true
	case .Caret:
		return .Exp, EXP_BP, true, true
	}
	return {}, 0, false, false
}

// build_assign ports the `expr '=' expr` and `'{' scatter '}' '=' expr` actions: validates
// (and where needed, rewrites) the LHS shape, matching the original's checks exactly.
@(private = "file")
build_assign :: proc(p: ^Parser, lhs: Expr, rhs: Expr) -> Expr {
	target := lhs
	#partial switch v in lhs {
	case ^Expr_List:
		if len(v.items) == 0 {
			parser_error(p, "Empty list in scattering assignment.")
		} else {
			items := convert_arglist_to_scatter(p, v.items)
			vet_scatter(p, items)
			delete(v.items)
			free(v)
			sc := new(Expr_Scatter)
			sc.items = items
			target = sc
		}
	case ^Expr_Scatter:
	// Already built by parse_brace's dedicated scatter path.
	case ^Expr_Range:
		check_assign_lvalue(p, v.base)
	case ^Expr_Index:
		check_assign_lvalue(p, v)
	case ^Expr_Id, ^Expr_Prop:
	// valid targets as-is
	case:
		parser_error(p, "Illegal expression on left side of assignment.")
	}

	a := new(Expr_Assign)
	a.target = target
	a.value = rhs
	return a
}

// check_assign_lvalue ports the tail of the `expr '=' expr` action: unwrap any nesting of
// EXPR_INDEX (e.g. `a[1][2]`, or the base of a range target like `info[2][i..i]`), then
// require the innermost expression to be a bare variable or property reference.
@(private = "file")
check_assign_lvalue :: proc(p: ^Parser, e: Expr) {
	cur := e
	for {
		idx, is_idx := cur.(^Expr_Index)
		if !is_idx {
			break
		}
		cur = idx.base
	}
	#partial switch _ in cur {
	case ^Expr_Id, ^Expr_Prop:
		return
	}
	parser_error(p, "Illegal expression on left side of assignment.")
}

// convert_arglist_to_scatter ports scatter_from_arglist(): every element must reduce to a
// bare identifier (splice -> SCAT_REST, plain -> SCAT_REQUIRED).
@(private = "file")
convert_arglist_to_scatter :: proc(p: ^Parser, items: []Arg) -> []Scatter_Item {
	result := make([dynamic]Scatter_Item, 0, len(items))
	for item in items {
		id, ok := item.expr.(^Expr_Id)
		if !ok {
			parser_error(p, "Scattering assignment targets must be simple variables.")
			free_expr(item.expr)
			continue
		}
		kind := item.splice ? Scatter_Kind.Rest : Scatter_Kind.Required
		append(&result, Scatter_Item{kind = kind, var_id = id.var_id})
		free(id)
	}
	return result[:]
}

@(private = "file")
vet_scatter :: proc(p: ^Parser, items: []Scatter_Item) {
	seen_rest := false
	for it in items {
		if it.kind == .Rest {
			if seen_rest {
				parser_error(p, "More than one `@' target in scattering assignment.")
			}
			seen_rest = true
		}
	}
	if len(items) > 255 {
		parser_error(p, "Too many targets in scattering assignment.")
	}
}

@(private = "file")
parse_unary :: proc(p: ^Parser) -> Expr {
	#partial switch p.cur.kind {
	case .Bang:
		advance(p)
		operand := parse_unary(p)
		u := new(Expr_Unary)
		u.op = .Not
		u.operand = operand
		return u
	case .Minus:
		advance(p)
		operand := parse_unary(p)
		if v, ok := operand.(^Expr_Var); ok {
			#partial switch v.value.type {
			case .Int:
				v.value.data.num = -v.value.data.num
				return v
			case .Float:
				v.value.data.fnum = -v.value.data.fnum
				return v
			}
		}
		u := new(Expr_Unary)
		u.op = .Negate
		u.operand = operand
		return u
	}
	return parse_postfix(p, parse_primary(p))
}

// parse_postfix ports the `.`/`:`/`[` chain -- the highest-precedence, nonassoc level.
@(private = "file")
parse_postfix :: proc(p: ^Parser, base: Expr) -> Expr {
	cur := base
	for {
		#partial switch p.cur.kind {
		case .Dot:
			advance(p)
			if p.cur.kind == .LParen {
				advance(p)
				prop := parse_expr(p, ASSIGN_BP)
				expect(p, .RParen)
				e := new(Expr_Prop)
				e.obj = cur
				e.prop = prop
				cur = e
			} else {
				tok := expect(p, .Id)
				prop := new(Expr_Var)
				prop.value = values.str_val(tok.str_val)
				e := new(Expr_Prop)
				e.obj = cur
				e.prop = prop
				cur = e
			}
		case .Colon:
			advance(p)
			verb: Expr
			if p.cur.kind == .LParen {
				advance(p)
				verb = parse_expr(p, ASSIGN_BP)
				expect(p, .RParen)
			} else {
				tok := expect(p, .Id)
				v := new(Expr_Var)
				v.value = values.str_val(tok.str_val)
				verb = v
			}
			expect(p, .LParen)
			args := parse_arglist(p)
			expect(p, .RParen)
			e := new(Expr_Verb_Call)
			e.obj = cur
			e.verb = verb
			e.args = args
			cur = e
		case .LBracket:
			advance(p)
			p.dollars_depth += 1
			idx := parse_expr(p, ASSIGN_BP)
			if p.cur.kind == .To {
				advance(p)
				to := parse_expr(p, ASSIGN_BP)
				p.dollars_depth -= 1
				expect(p, .RBracket)
				e := new(Expr_Range)
				e.base = cur
				e.from = idx
				e.to = to
				cur = e
			} else {
				p.dollars_depth -= 1
				expect(p, .RBracket)
				e := new(Expr_Index)
				e.base = cur
				e.index = idx
				cur = e
			}
		case:
			return cur
		}
	}
}

@(private = "file")
parse_primary :: proc(p: ^Parser) -> Expr {
	#partial switch p.cur.kind {
	case .Int:
		tok := advance(p)
		e := new(Expr_Var)
		e.value = values.int_val(tok.int_val)
		return e
	case .Float:
		tok := advance(p)
		e := new(Expr_Var)
		e.value = values.float_val(tok.float_val)
		return e
	case .String:
		tok := advance(p)
		e := new(Expr_Var)
		e.value = values.str_val(tok.str_val)
		return e
	case .Object:
		tok := advance(p)
		e := new(Expr_Var)
		e.value = values.obj_val(tok.obj_val)
		return e
	case .Error:
		tok := advance(p)
		e := new(Expr_Var)
		e.value = values.err_val(tok.err_val)
		return e
	case .Dollar:
		advance(p)
		if p.cur.kind == .Id {
			return parse_dollar_ref(p)
		}
		if p.dollars_depth == 0 {
			parser_error(p, "Illegal context for `$' expression.")
		}
		return new(Expr_Length)
	case .Id:
		return parse_id_or_call(p)
	case .LParen:
		advance(p)
		e := parse_expr(p, ASSIGN_BP)
		expect(p, .RParen)
		return e
	case .LBrace:
		return parse_brace(p)
	case .Backtick:
		return parse_catch(p)
	}
	parser_errorf(p, "Unexpected token: %v", p.cur.kind)
	advance(p)
	e := new(Expr_Var)
	e.value = values.int_val(0)
	return e
}

// parse_dollar_ref ports the `$foo` / `$foo(args)` shorthand: desugars to
// `#0.("foo")` / `#0:("foo")(args)`, exactly as the original grammar action does.
@(private = "file")
parse_dollar_ref :: proc(p: ^Parser) -> Expr {
	tok := advance(p) // the identifier after '$'
	obj := new(Expr_Var)
	obj.value = values.obj_val(0)
	name := new(Expr_Var)
	name.value = values.str_val(tok.str_val)

	if p.cur.kind == .LParen {
		advance(p)
		args := parse_arglist(p)
		expect(p, .RParen)
		e := new(Expr_Verb_Call)
		e.obj = obj
		e.verb = name
		e.args = args
		return e
	}
	e := new(Expr_Prop)
	e.obj = obj
	e.prop = name
	return e
}

// parse_id_or_call ports the bare tID (variable reference) vs. tID '(' arglist ')'
// (built-in function call, with the call_function() rewrite for unrecognized names).
@(private = "file")
parse_id_or_call :: proc(p: ^Parser) -> Expr {
	tok := advance(p)
	if p.cur.kind == .LParen {
		advance(p)
		args := parse_arglist(p)
		expect(p, .RParen)
		e := new(Expr_Call)
		e.name = tok.str_val
		e.is_known = is_known_builtin(tok.str_val)
		e.args = args
		return e
	}
	id := new(Expr_Id)
	id.var_id = find_or_add(&p.names, tok.str_val)
	delete(tok.str_val)
	return id
}

// parse_catch ports `` '`' expr '!' codes default '\'' `` (the backtick/quote catch
// expression, e.g. `` `x / 0 ! E_DIV => -1' ``).
@(private = "file")
parse_catch :: proc(p: ^Parser) -> Expr {
	advance(p) // '`'
	try_expr := parse_expr(p, ASSIGN_BP)
	expect(p, .Bang)
	codes := parse_codes(p)
	handler: Expr
	if p.cur.kind == .Arrow {
		advance(p)
		handler = parse_expr(p, ASSIGN_BP)
	}
	expect(p, .Quote)

	e := new(Expr_Catch)
	e.try = try_expr
	e.codes = codes
	e.handler = handler
	return e
}

// parse_brace ports both `'{' arglist '}'` (plain list literal) and
// `'{' scatter '}' '=' expr` (scattering assignment target) -- unified here into one parse
// that preserves item order (needed since scatter binds positionally), then decides which
// shape to build once the full item sequence is known: any `?` item found means this must
// be a scattering-assignment target as a whole, immediately followed by `=`.
@(private = "file")
parse_brace :: proc(p: ^Parser) -> Expr {
	advance(p) // '{'

	items: [dynamic]Brace_Item
	if p.cur.kind != .RBrace {
		append(&items, parse_brace_item(p))
		for p.cur.kind == .Comma {
			advance(p)
			append(&items, parse_brace_item(p))
		}
	}
	expect(p, .RBrace)

	saw_question := false
	for it in items {
		if it.is_question {
			saw_question = true
			break
		}
	}

	if saw_question {
		scat_items := make([dynamic]Scatter_Item, 0, len(items))
		for it in items {
			if it.is_question {
				append(&scat_items, it.scat)
				continue
			}
			id, ok := it.arg.expr.(^Expr_Id)
			if !ok {
				parser_error(p, "Scattering assignment targets must be simple variables.")
				free_expr(it.arg.expr)
				continue
			}
			kind := it.arg.splice ? Scatter_Kind.Rest : Scatter_Kind.Required
			append(&scat_items, Scatter_Item{kind = kind, var_id = id.var_id})
			free(id)
		}
		delete(items)
		vet_scatter(p, scat_items[:])
		expect(p, .Assign)
		rhs := parse_expr(p, ASSIGN_BP)
		sc := new(Expr_Scatter)
		sc.items = scat_items[:]
		a := new(Expr_Assign)
		a.target = sc
		a.value = rhs
		return a
	}

	args := make([]Arg, len(items))
	for it, i in items {
		args[i] = it.arg
	}
	delete(items)
	lst := new(Expr_List)
	lst.items = args
	return lst
}

@(private = "file")
Brace_Item :: struct {
	is_question: bool,
	scat:        Scatter_Item, // valid iff is_question
	arg:         Arg,          // valid iff !is_question
}

@(private = "file")
parse_brace_item :: proc(p: ^Parser) -> Brace_Item {
	if p.cur.kind == .Question {
		advance(p)
		tok := expect(p, .Id)
		var_id := find_or_add(&p.names, tok.str_val)
		delete(tok.str_val)
		default_expr: Expr
		if p.cur.kind == .Assign {
			advance(p)
			default_expr = parse_expr(p, ASSIGN_BP)
		}
		return Brace_Item{is_question = true, scat = Scatter_Item{kind = .Optional, var_id = var_id, default = default_expr}}
	}
	if p.cur.kind == .At {
		advance(p)
		e := parse_expr(p, ASSIGN_BP)
		return Brace_Item{arg = Arg{splice = true, expr = e}}
	}
	e := parse_expr(p, ASSIGN_BP)
	return Brace_Item{arg = Arg{expr = e}}
}

parse_arglist :: proc(p: ^Parser) -> []Arg {
	if p.cur.kind == .RParen {
		return nil
	}
	return parse_ne_arglist(p)
}

parse_ne_arglist :: proc(p: ^Parser) -> []Arg {
	items: [dynamic]Arg
	append(&items, parse_one_arg(p))
	for p.cur.kind == .Comma {
		advance(p)
		append(&items, parse_one_arg(p))
	}
	return items[:]
}

@(private = "file")
parse_one_arg :: proc(p: ^Parser) -> Arg {
	if p.cur.kind == .At {
		advance(p)
		e := parse_expr(p, ASSIGN_BP)
		return Arg{splice = true, expr = e}
	}
	e := parse_expr(p, ASSIGN_BP)
	return Arg{expr = e}
}

// ---- Loop-name stack (break/continue validation), ported from parser.y's
// push_loop_name/pop_loop_name/suspend_loop_scope/resume_loop_scope/check_loop_name. ----

@(private = "file")
push_loop_name :: proc(p: ^Parser, name: string) {
	append(&p.loop_stack, Loop_Entry{name = name == "" ? "" : name})
}

@(private = "file")
pop_loop_name :: proc(p: ^Parser) {
	if len(p.loop_stack) == 0 || p.loop_stack[len(p.loop_stack) - 1].is_barrier {
		return
	}
	pop(&p.loop_stack)
}

@(private = "file")
suspend_loop_scope :: proc(p: ^Parser) {
	append(&p.loop_stack, Loop_Entry{is_barrier = true})
}

@(private = "file")
resume_loop_scope :: proc(p: ^Parser) {
	if len(p.loop_stack) == 0 || !p.loop_stack[len(p.loop_stack) - 1].is_barrier {
		return
	}
	pop(&p.loop_stack)
}

@(private = "file")
check_loop_name :: proc(p: ^Parser, name: string, is_break: bool) {
	kind_str := is_break ? "break" : "continue"
	if name == "" {
		if len(p.loop_stack) == 0 || p.loop_stack[len(p.loop_stack) - 1].is_barrier {
			parser_errorf(p, "No enclosing loop for `%s' statement", kind_str)
		}
		return
	}
	for i := len(p.loop_stack) - 1; i >= 0; i -= 1 {
		e := p.loop_stack[i]
		if e.is_barrier {
			break
		}
		if e.name != "" && strings.equal_fold(e.name, name) {
			return
		}
	}
	parser_errorf(p, "Invalid loop name in `%s' statement: %s", kind_str, name)
}
