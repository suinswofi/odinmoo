package compiler

// Decompiler (AST -> MOO source text), ported from unparse.c.
//
// Two independent options, exactly as the original's unparse_program() takes them:
//
//   fully_parenthesize -- every operator expression that is an operand of another expression
//     is wrapped in parentheses (bracket_lt/bracket_le's `expr_prec[child] < expr_prec[PROP]`
//     test). Without it, parentheses appear only where precedence and associativity require
//     them, from the same table the original uses (prec_table).
//   indent -- statement bodies are indented two spaces per level.
//
// verb_code() defaults to minimal parentheses with indentation (what @list shows); the database
// stores verbs fully parenthesized and unindented (db_io.c's dbio_write_program).

import "../values"
import "core:fmt"
import "core:strings"

@(private = "file")
Unparser :: struct {
	b:      ^strings.Builder,
	names:  ^Name_Table,
	parens: bool, // fully_parenthesize
	indent: bool,
}

unparse_program :: proc(stmts: []Stmt, names: ^Name_Table, fully_parenthesize := false, indent := true) -> string {
	b := strings.builder_make()
	u := Unparser{b = &b, names = names, parens = fully_parenthesize, indent = indent}
	unparse_stmts_u(&u, stmts, 0)
	return strings.to_string(b)
}

@(private = "file")
write_indent :: proc(u: ^Unparser, level: int) {
	if !u.indent {
		return
	}
	for _ in 0 ..< level {
		strings.write_string(u.b, "  ")
	}
}

@(private = "file")
unparse_stmts_u :: proc(u: ^Unparser, stmts: []Stmt, level: int) {
	for s in stmts {
		unparse_stmt_u(u, s, level)
	}
}

@(private = "file")
var_name :: proc(names: ^Name_Table, id: int) -> string {
	if id < 0 || id >= len(names.names) {
		return "?"
	}
	return names.names[id]
}

@(private = "file")
unparse_stmt_u :: proc(u: ^Unparser, s: Stmt, level: int) {
	b, names := u.b, u.names
	switch v in s {
	case ^Stmt_Cond:
		for arm, i in v.arms {
			write_indent(u, level)
			strings.write_string(b, i == 0 ? "if (" : "elseif (")
			unparse_expr(u, arm.condition)
			strings.write_string(b, ")\n")
			unparse_stmts_u(u, arm.body, level + 1)
		}
		if v.otherwise != nil {
			write_indent(u, level)
			strings.write_string(b, "else\n")
			unparse_stmts_u(u, v.otherwise, level + 1)
		}
		write_indent(u, level)
		strings.write_string(b, "endif\n")

	case ^Stmt_List_Loop:
		write_indent(u, level)
		fmt.sbprintf(b, "for %s in (", var_name(names, v.var_id))
		unparse_expr(u, v.list)
		strings.write_string(b, ")\n")
		unparse_stmts_u(u, v.body, level + 1)
		write_indent(u, level)
		strings.write_string(b, "endfor\n")

	case ^Stmt_Range_Loop:
		write_indent(u, level)
		fmt.sbprintf(b, "for %s in [", var_name(names, v.var_id))
		unparse_expr(u, v.from)
		strings.write_string(b, "..")
		unparse_expr(u, v.to)
		strings.write_string(b, "]\n")
		unparse_stmts_u(u, v.body, level + 1)
		write_indent(u, level)
		strings.write_string(b, "endfor\n")

	case ^Stmt_While:
		write_indent(u, level)
		if v.var_id >= 0 {
			fmt.sbprintf(b, "while %s (", var_name(names, v.var_id))
		} else {
			strings.write_string(b, "while (")
		}
		unparse_expr(u, v.condition)
		strings.write_string(b, ")\n")
		unparse_stmts_u(u, v.body, level + 1)
		write_indent(u, level)
		strings.write_string(b, "endwhile\n")

	case ^Stmt_Fork:
		write_indent(u, level)
		if v.var_id >= 0 {
			fmt.sbprintf(b, "fork %s (", var_name(names, v.var_id))
		} else {
			strings.write_string(b, "fork (")
		}
		unparse_expr(u, v.time)
		strings.write_string(b, ")\n")
		unparse_stmts_u(u, v.body, level + 1)
		write_indent(u, level)
		strings.write_string(b, "endfork\n")

	case ^Stmt_Expr:
		write_indent(u, level)
		unparse_expr(u, v.expr)
		strings.write_string(b, ";\n")

	case ^Stmt_Return:
		write_indent(u, level)
		if v.expr != nil {
			strings.write_string(b, "return ")
			unparse_expr(u, v.expr)
			strings.write_string(b, ";\n")
		} else {
			strings.write_string(b, "return;\n")
		}

	case ^Stmt_Try_Except:
		write_indent(u, level)
		strings.write_string(b, "try\n")
		unparse_stmts_u(u, v.body, level + 1)
		for arm in v.excepts {
			write_indent(u, level)
			strings.write_string(b, "except ")
			if arm.var_id >= 0 {
				fmt.sbprintf(b, "%s ", var_name(names, arm.var_id))
			}
			strings.write_string(b, "(")
			unparse_codes(u, arm.codes)
			strings.write_string(b, ")\n")
			unparse_stmts_u(u, arm.body, level + 1)
		}
		write_indent(u, level)
		strings.write_string(b, "endtry\n")

	case ^Stmt_Try_Finally:
		write_indent(u, level)
		strings.write_string(b, "try\n")
		unparse_stmts_u(u, v.body, level + 1)
		write_indent(u, level)
		strings.write_string(b, "finally\n")
		unparse_stmts_u(u, v.handler, level + 1)
		write_indent(u, level)
		strings.write_string(b, "endtry\n")

	case ^Stmt_Break:
		write_indent(u, level)
		if v.var_id >= 0 {
			fmt.sbprintf(b, "break %s;\n", var_name(names, v.var_id))
		} else {
			strings.write_string(b, "break;\n")
		}

	case ^Stmt_Continue:
		write_indent(u, level)
		if v.var_id >= 0 {
			fmt.sbprintf(b, "continue %s;\n", var_name(names, v.var_id))
		} else {
			strings.write_string(b, "continue;\n")
		}
	}
}

// PROP_PREC is prec_table's level for `.`/`:`/`[]` -- the boundary fully_parenthesize tests
// against.
@(private = "file")
PROP_PREC :: 9

// expr_prec ports unparse.c's prec_table. (A scattering target isn't in the table -- 0 -- and
// only ever appears as an assignment's left side, which is never bracketed.)
@(private = "file")
expr_prec :: proc(e: Expr) -> int {
	switch v in e {
	case ^Expr_Assign:
		return 1
	case ^Expr_Cond:
		return 2
	case ^Expr_Binary:
		switch v.op {
		case .Or, .And:
			return 3
		case .Eq, .Ne, .Lt, .Le, .Gt, .Ge, .In:
			return 4
		case .Plus, .Minus:
			return 5
		case .Times, .Divide, .Mod:
			return 6
		case .Exp:
			return 7
		}
	case ^Expr_Unary:
		return 8
	case ^Expr_Prop, ^Expr_Verb_Call, ^Expr_Index, ^Expr_Range:
		return 9
	case ^Expr_Var, ^Expr_Id, ^Expr_List, ^Expr_Call, ^Expr_Length, ^Expr_Catch:
		return 10
	case ^Expr_Scatter:
		return 0
	}
	return 10
}

// bracket_lt/bracket_le port unparse.c's: parenthesize `child` when fully parenthesizing an
// operator expression, or when its precedence is lower than (lt) / no higher than (le) the
// parent's.
@(private = "file")
bracket_lt :: proc(u: ^Unparser, parent_prec: int, child: Expr) {
	cp := expr_prec(child)
	bracket(u, (u.parens && cp < PROP_PREC) || parent_prec > cp, child)
}

@(private = "file")
bracket_le :: proc(u: ^Unparser, parent_prec: int, child: Expr) {
	cp := expr_prec(child)
	bracket(u, (u.parens && cp < PROP_PREC) || parent_prec >= cp, child)
}

@(private = "file")
bracket :: proc(u: ^Unparser, wrap: bool, child: Expr) {
	if wrap {
		strings.write_byte(u.b, '(')
	}
	unparse_expr(u, child)
	if wrap {
		strings.write_byte(u.b, ')')
	}
}

// unparse_name_expr ports unparse_name_expr(): the name part of `.name`/`:name` is written bare
// when it's a string literal shaped like an identifier, else as `(expr)`.
@(private = "file")
unparse_name_expr :: proc(u: ^Unparser, e: Expr) {
	if lit, ok := e.(^Expr_Var); ok && lit.value.type == .Str && is_identifier_like(lit.value.data.str.s) {
		strings.write_string(u.b, lit.value.data.str.s)
		return
	}
	strings.write_byte(u.b, '(')
	unparse_expr(u, e)
	strings.write_byte(u.b, ')')
}

@(private = "file")
unparse_expr :: proc(u: ^Unparser, e: Expr) {
	b, names := u.b, u.names
	switch v in e {
	case ^Expr_Var:
		unparse_literal(b, v.value)
	case ^Expr_Id:
		strings.write_string(b, var_name(names, v.var_id))
	case ^Expr_Prop:
		// `#0.foo` prints as `$foo`, undoing the parser's desugaring.
		if name, ok := dollar_name(v.obj, v.prop); ok {
			strings.write_byte(b, '$')
			strings.write_string(b, name)
		} else {
			bracket_lt(u, 9, v.obj)
			if lit, ok := v.obj.(^Expr_Var); ok && lit.value.type == .Int {
				strings.write_byte(b, ' ') // so `1 .foo` doesn't lex as the float `1.`
			}
			strings.write_byte(b, '.')
			unparse_name_expr(u, v.prop)
		}
	case ^Expr_Verb_Call:
		if name, ok := dollar_name(v.obj, v.verb); ok {
			strings.write_byte(b, '$')
			strings.write_string(b, name)
		} else {
			bracket_lt(u, 9, v.obj)
			strings.write_byte(b, ':')
			unparse_name_expr(u, v.verb)
		}
		strings.write_byte(b, '(')
		unparse_args(u, v.args)
		strings.write_byte(b, ')')
	case ^Expr_Index:
		bracket_lt(u, 9, v.base)
		strings.write_byte(b, '[')
		unparse_expr(u, v.index)
		strings.write_byte(b, ']')
	case ^Expr_Range:
		bracket_lt(u, 9, v.base)
		strings.write_byte(b, '[')
		unparse_expr(u, v.from)
		strings.write_string(b, "..")
		unparse_expr(u, v.to)
		strings.write_byte(b, ']')
	case ^Expr_Assign:
		unparse_expr(u, v.target)
		strings.write_string(b, " = ")
		unparse_expr(u, v.value)
	case ^Expr_Call:
		if v.is_known {
			strings.write_string(b, v.name)
			strings.write_byte(b, '(')
			unparse_args(u, v.args)
		} else {
			// The parser compiled an unknown `foo(...)` to call_function("foo", ...), and
			// that is what the original's decompiler shows.
			strings.write_string(b, "call_function(")
			unparse_string_literal(b, v.name)
			if len(v.args) > 0 {
				strings.write_string(b, ", ")
				unparse_args(u, v.args)
			}
		}
		strings.write_byte(b, ')')
	case ^Expr_Binary:
		prec := expr_prec(e)
		if v.op == .Exp { // right-associative
			bracket_le(u, prec, v.lhs)
			strings.write_string(b, binop_text(v.op))
			bracket_lt(u, prec, v.rhs)
		} else {
			bracket_lt(u, prec, v.lhs)
			strings.write_string(b, binop_text(v.op))
			bracket_le(u, prec, v.rhs)
		}
	case ^Expr_Unary:
		strings.write_string(b, v.op == .Not ? "!" : "-")
		bracket_lt(u, 8, v.operand)
	case ^Expr_List:
		strings.write_byte(b, '{')
		unparse_args(u, v.items)
		strings.write_byte(b, '}')
	case ^Expr_Cond:
		bracket_le(u, 2, v.condition)
		strings.write_string(b, " ? ")
		unparse_expr(u, v.consequent)
		strings.write_string(b, " | ")
		bracket_le(u, 2, v.alternate)
	case ^Expr_Catch:
		strings.write_byte(b, '`')
		unparse_expr(u, v.try)
		strings.write_string(b, " ! ")
		unparse_codes(u, v.codes)
		if v.handler != nil {
			strings.write_string(b, " => ")
			unparse_expr(u, v.handler)
		}
		strings.write_byte(b, '\'')
	case ^Expr_Length:
		strings.write_byte(b, '$')
	case ^Expr_Scatter:
		strings.write_byte(b, '{')
		unparse_scatter(u, v.items)
		strings.write_byte(b, '}')
	}
}

@(private = "file")
binop_text :: proc(op: Binary_Op) -> string {
	switch op {
	case .Plus: return " + "
	case .Minus: return " - "
	case .Times: return " * "
	case .Divide: return " / "
	case .Mod: return " % "
	case .Exp: return " ^ "
	case .And: return " && "
	case .Or: return " || "
	case .Eq: return " == "
	case .Ne: return " != "
	case .Lt: return " < "
	case .Le: return " <= "
	case .Gt: return " > "
	case .Ge: return " >= "
	case .In: return " in "
	}
	return " ? "
}

@(private = "file")
unparse_args :: proc(u: ^Unparser, args: []Arg) {
	for a, i in args {
		if i > 0 {
			strings.write_string(u.b, ", ")
		}
		if a.splice {
			strings.write_byte(u.b, '@')
		}
		unparse_expr(u, a.expr)
	}
}

@(private = "file")
unparse_codes :: proc(u: ^Unparser, codes: []Arg) {
	if codes == nil {
		strings.write_string(u.b, "ANY")
		return
	}
	unparse_args(u, codes)
}

@(private = "file")
unparse_scatter :: proc(u: ^Unparser, items: []Scatter_Item) {
	b, names := u.b, u.names
	for it, i in items {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		switch it.kind {
		case .Required:
			strings.write_string(b, var_name(names, it.var_id))
		case .Rest:
			strings.write_byte(b, '@')
			strings.write_string(b, var_name(names, it.var_id))
		case .Optional:
			strings.write_byte(b, '?')
			strings.write_string(b, var_name(names, it.var_id))
			if it.default != nil {
				strings.write_string(b, " = ")
				unparse_expr(u, it.default)
			}
		}
	}
}

@(private = "file")
// is_identifier_like ports unparse.c's ok_identifier(): a name that can be written bare
// after `.`/`:`/`$` -- identifier characters AND not a keyword (keywords are
// case-insensitive in MOO, so `If` is as unusable as `if`; a property literally named
// "if" has to print as `.("if")`, since `.if` would not lex back as a name).
is_identifier_like :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c, i in s {
		is_alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
		is_digit := c >= '0' && c <= '9'
		if i == 0 && !is_alpha {
			return false
		}
		if !is_alpha && !is_digit {
			return false
		}
	}
	lower_buf: [16]byte
	if len(s) <= len(lower_buf) {
		for i in 0 ..< len(s) {
			c := s[i]
			lower_buf[i] = c + ('a' - 'A') if c >= 'A' && c <= 'Z' else c
		}
		if _, is_kw := keywords[string(lower_buf[:len(s)])]; is_kw {
			return false
		}
	}
	return true
}

// dollar_name recognizes the `$name` shape -- object part a literal #0, name part an
// identifier-like string literal -- and returns the name.
@(private = "file")
dollar_name :: proc(obj, name: Expr) -> (string, bool) {
	o, ok_o := obj.(^Expr_Var)
	if !ok_o || o.value.type != .Obj || o.value.data.obj != 0 {
		return "", false
	}
	n, ok_n := name.(^Expr_Var)
	if !ok_n || n.value.type != .Str || !is_identifier_like(n.value.data.str.s) {
		return "", false
	}
	return n.value.data.str.s, true
}

@(private = "file")
unparse_literal :: proc(b: ^strings.Builder, v: values.Var) {
	switch v.type {
	case .Int:
		fmt.sbprintf(b, "%d", v.data.num)
	case .Float:
		unparse_float(b, v.data.fnum)
	case .Str:
		unparse_string_literal(b, v.data.str.s)
	case .Obj:
		fmt.sbprintf(b, "#%d", v.data.obj)
	case .Err:
		strings.write_string(b, error_name(v.data.err))
	case .Clear, .None, .Catch, .Finally, .List:
	// Never appear as parsed literals; nothing to print.
	}
}

@(private = "file")
unparse_float :: proc(b: ^strings.Builder, f: f64) {
	// The decompiler prints a float literal exactly as tostr() would (unparse_value's "%g"
	// through stream_printf), which always includes a `.` or an exponent.
	strings.write_string(b, values.format_float(f, context.temp_allocator))
}

@(private = "file")
unparse_string_literal :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in s {
		if c == '"' || c == '\\' {
			strings.write_byte(b, '\\')
		}
		strings.write_rune(b, c)
	}
	strings.write_byte(b, '"')
}

error_name :: proc(e: values.Error) -> string {
	switch e {
	case .E_NONE: return "E_NONE"
	case .E_TYPE: return "E_TYPE"
	case .E_DIV: return "E_DIV"
	case .E_PERM: return "E_PERM"
	case .E_PROPNF: return "E_PROPNF"
	case .E_VERBNF: return "E_VERBNF"
	case .E_VARNF: return "E_VARNF"
	case .E_INVIND: return "E_INVIND"
	case .E_RECMOVE: return "E_RECMOVE"
	case .E_MAXREC: return "E_MAXREC"
	case .E_RANGE: return "E_RANGE"
	case .E_ARGS: return "E_ARGS"
	case .E_NACC: return "E_NACC"
	case .E_INVARG: return "E_INVARG"
	case .E_QUOTA: return "E_QUOTA"
	case .E_FLOAT: return "E_FLOAT"
	}
	return "E_?"
}
