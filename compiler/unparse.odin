package compiler

// Decompiler (AST -> MOO source text), ported from src/unparse.c/decompile.c. The original
// supports two output modes: a "minimal parens" mode that only parenthesizes a sub-
// expression when its precedence is actually lower than context requires, and a
// `fully_parenthesize` mode that wraps every nested compound expression regardless. This
// implements the latter: every position is unambiguous (parenthesized on entry) except the
// single outermost expression of a statement, so correctness never depends on getting a
// precedence-comparison table exactly right -- valuable here since this unparser's main job
// right now is round-trip validation (parse -> unparse -> reparse -> compare) against 1727
// real verb programs, not visual minimalism.

import "../values"
import "core:fmt"
import "core:strings"

unparse_program :: proc(stmts: []Stmt, names: ^Name_Table) -> string {
	b := strings.builder_make()
	unparse_stmts(&b, stmts, names, 0)
	return strings.to_string(b)
}

@(private = "file")
write_indent :: proc(b: ^strings.Builder, level: int) {
	for _ in 0 ..< level {
		strings.write_string(b, "  ")
	}
}

unparse_stmts :: proc(b: ^strings.Builder, stmts: []Stmt, names: ^Name_Table, level: int) {
	for s in stmts {
		unparse_stmt(b, s, names, level)
	}
}

@(private = "file")
var_name :: proc(names: ^Name_Table, id: int) -> string {
	if id < 0 || id >= len(names.names) {
		return "?"
	}
	return names.names[id]
}

unparse_stmt :: proc(b: ^strings.Builder, s: Stmt, names: ^Name_Table, level: int) {
	switch v in s {
	case ^Stmt_Cond:
		for arm, i in v.arms {
			write_indent(b, level)
			strings.write_string(b, i == 0 ? "if (" : "elseif (")
			unparse_expr_top(b, arm.condition, names)
			strings.write_string(b, ")\n")
			unparse_stmts(b, arm.body, names, level + 1)
		}
		if v.otherwise != nil {
			write_indent(b, level)
			strings.write_string(b, "else\n")
			unparse_stmts(b, v.otherwise, names, level + 1)
		}
		write_indent(b, level)
		strings.write_string(b, "endif\n")

	case ^Stmt_List_Loop:
		write_indent(b, level)
		fmt.sbprintf(b, "for %s in (", var_name(names, v.var_id))
		unparse_expr_top(b, v.list, names)
		strings.write_string(b, ")\n")
		unparse_stmts(b, v.body, names, level + 1)
		write_indent(b, level)
		strings.write_string(b, "endfor\n")

	case ^Stmt_Range_Loop:
		write_indent(b, level)
		fmt.sbprintf(b, "for %s in [", var_name(names, v.var_id))
		unparse_expr_top(b, v.from, names)
		strings.write_string(b, "..")
		unparse_expr_top(b, v.to, names)
		strings.write_string(b, "]\n")
		unparse_stmts(b, v.body, names, level + 1)
		write_indent(b, level)
		strings.write_string(b, "endfor\n")

	case ^Stmt_While:
		write_indent(b, level)
		if v.var_id >= 0 {
			fmt.sbprintf(b, "while %s (", var_name(names, v.var_id))
		} else {
			strings.write_string(b, "while (")
		}
		unparse_expr_top(b, v.condition, names)
		strings.write_string(b, ")\n")
		unparse_stmts(b, v.body, names, level + 1)
		write_indent(b, level)
		strings.write_string(b, "endwhile\n")

	case ^Stmt_Fork:
		write_indent(b, level)
		if v.var_id >= 0 {
			fmt.sbprintf(b, "fork %s (", var_name(names, v.var_id))
		} else {
			strings.write_string(b, "fork (")
		}
		unparse_expr_top(b, v.time, names)
		strings.write_string(b, ")\n")
		unparse_stmts(b, v.body, names, level + 1)
		write_indent(b, level)
		strings.write_string(b, "endfork\n")

	case ^Stmt_Expr:
		write_indent(b, level)
		unparse_expr_top(b, v.expr, names)
		strings.write_string(b, ";\n")

	case ^Stmt_Return:
		write_indent(b, level)
		if v.expr != nil {
			strings.write_string(b, "return ")
			unparse_expr_top(b, v.expr, names)
			strings.write_string(b, ";\n")
		} else {
			strings.write_string(b, "return;\n")
		}

	case ^Stmt_Try_Except:
		write_indent(b, level)
		strings.write_string(b, "try\n")
		unparse_stmts(b, v.body, names, level + 1)
		for arm in v.excepts {
			write_indent(b, level)
			strings.write_string(b, "except ")
			if arm.var_id >= 0 {
				fmt.sbprintf(b, "%s ", var_name(names, arm.var_id))
			}
			strings.write_string(b, "(")
			unparse_codes(b, arm.codes, names)
			strings.write_string(b, ")\n")
			unparse_stmts(b, arm.body, names, level + 1)
		}
		write_indent(b, level)
		strings.write_string(b, "endtry\n")

	case ^Stmt_Try_Finally:
		write_indent(b, level)
		strings.write_string(b, "try\n")
		unparse_stmts(b, v.body, names, level + 1)
		write_indent(b, level)
		strings.write_string(b, "finally\n")
		unparse_stmts(b, v.handler, names, level + 1)
		write_indent(b, level)
		strings.write_string(b, "endtry\n")

	case ^Stmt_Break:
		write_indent(b, level)
		if v.var_id >= 0 {
			fmt.sbprintf(b, "break %s;\n", var_name(names, v.var_id))
		} else {
			strings.write_string(b, "break;\n")
		}

	case ^Stmt_Continue:
		write_indent(b, level)
		if v.var_id >= 0 {
			fmt.sbprintf(b, "continue %s;\n", var_name(names, v.var_id))
		} else {
			strings.write_string(b, "continue;\n")
		}
	}
}

// unparse_expr_top prints e without an enclosing paren -- used only for the single
// outermost expression of a statement (an if-condition, a return value, etc.).
unparse_expr_top :: proc(b: ^strings.Builder, e: Expr, names: ^Name_Table) {
	unparse_expr(b, e, names, false)
}

// unparse_expr_nested prints e as an operand of something else: compound expressions get
// wrapped in parens (see the file header -- this is deliberately conservative).
@(private = "file")
unparse_expr_nested :: proc(b: ^strings.Builder, e: Expr, names: ^Name_Table) {
	unparse_expr(b, e, names, true)
}

@(private = "file")
is_compound :: proc(e: Expr) -> bool {
	#partial switch _ in e {
	case ^Expr_Binary, ^Expr_Unary, ^Expr_Cond, ^Expr_Assign:
		return true
	}
	return false
}

@(private = "file")
unparse_expr :: proc(b: ^strings.Builder, e: Expr, names: ^Name_Table, paren_if_compound: bool) {
	wrap := paren_if_compound && is_compound(e)
	if wrap {
		strings.write_byte(b, '(')
	}
	switch v in e {
	case ^Expr_Var:
		unparse_literal(b, v.value)
	case ^Expr_Id:
		strings.write_string(b, var_name(names, v.var_id))
	case ^Expr_Prop:
		// `#0.foo` prints as `$foo`, undoing the parser's desugaring exactly as unparse.c's
		// EXPR_PROP case does -- otherwise every corified reference in a core (`$string_utils`,
		// `$recycler`) comes back from verb_code()/@list as `#0.string_utils`, and an @edit
		// round trip through set_verb_code() would bake that form into the database source.
		if name, ok := dollar_name(v.obj, v.prop); ok {
			strings.write_byte(b, '$')
			strings.write_string(b, name)
		} else {
			unparse_expr_nested(b, v.obj, names)
			if lit, ok := v.prop.(^Expr_Var); ok && lit.value.type == .Str && is_identifier_like(lit.value.data.str.s) {
				strings.write_byte(b, '.')
				strings.write_string(b, lit.value.data.str.s)
			} else {
				strings.write_string(b, ".(")
				unparse_expr_top(b, v.prop, names)
				strings.write_byte(b, ')')
			}
		}
	case ^Expr_Verb_Call:
		// Likewise `#0:foo(args)` prints as `$foo(args)` (unparse.c's EXPR_VERB case).
		if name, ok := dollar_name(v.obj, v.verb); ok {
			strings.write_byte(b, '$')
			strings.write_string(b, name)
		} else {
			unparse_expr_nested(b, v.obj, names)
			if lit, ok := v.verb.(^Expr_Var); ok && lit.value.type == .Str && is_identifier_like(lit.value.data.str.s) {
				strings.write_byte(b, ':')
				strings.write_string(b, lit.value.data.str.s)
			} else {
				strings.write_string(b, ":(")
				unparse_expr_top(b, v.verb, names)
				strings.write_byte(b, ')')
			}
		}
		strings.write_byte(b, '(')
		unparse_args(b, v.args, names)
		strings.write_byte(b, ')')
	case ^Expr_Index:
		unparse_expr_nested(b, v.base, names)
		strings.write_byte(b, '[')
		unparse_expr_top(b, v.index, names)
		strings.write_byte(b, ']')
	case ^Expr_Range:
		unparse_expr_nested(b, v.base, names)
		strings.write_byte(b, '[')
		unparse_expr_top(b, v.from, names)
		strings.write_string(b, "..")
		unparse_expr_top(b, v.to, names)
		strings.write_byte(b, ']')
	case ^Expr_Assign:
		unparse_expr_nested(b, v.target, names)
		strings.write_string(b, " = ")
		unparse_expr_nested(b, v.value, names)
	case ^Expr_Call:
		strings.write_string(b, v.name)
		strings.write_byte(b, '(')
		unparse_args(b, v.args, names)
		strings.write_byte(b, ')')
	case ^Expr_Binary:
		unparse_expr_nested(b, v.lhs, names)
		strings.write_string(b, binop_text(v.op))
		unparse_expr_nested(b, v.rhs, names)
	case ^Expr_Unary:
		strings.write_string(b, v.op == .Not ? "!" : "-")
		unparse_expr_nested(b, v.operand, names)
	case ^Expr_List:
		strings.write_byte(b, '{')
		unparse_args(b, v.items, names)
		strings.write_byte(b, '}')
	case ^Expr_Cond:
		unparse_expr_nested(b, v.condition, names)
		strings.write_string(b, " ? ")
		unparse_expr_nested(b, v.consequent, names)
		strings.write_string(b, " | ")
		unparse_expr_nested(b, v.alternate, names)
	case ^Expr_Catch:
		strings.write_byte(b, '`')
		unparse_expr_top(b, v.try, names)
		strings.write_string(b, " ! ")
		unparse_codes(b, v.codes, names)
		if v.handler != nil {
			strings.write_string(b, " => ")
			unparse_expr_top(b, v.handler, names)
		}
		strings.write_byte(b, '\'')
	case ^Expr_Length:
		strings.write_byte(b, '$')
	case ^Expr_Scatter:
		strings.write_byte(b, '{')
		unparse_scatter(b, v.items, names)
		strings.write_byte(b, '}')
	}
	if wrap {
		strings.write_byte(b, ')')
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
unparse_args :: proc(b: ^strings.Builder, args: []Arg, names: ^Name_Table) {
	for a, i in args {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		if a.splice {
			strings.write_byte(b, '@')
		}
		unparse_expr_nested(b, a.expr, names)
	}
}

@(private = "file")
unparse_codes :: proc(b: ^strings.Builder, codes: []Arg, names: ^Name_Table) {
	if codes == nil {
		strings.write_string(b, "ANY")
		return
	}
	unparse_args(b, codes, names)
}

@(private = "file")
unparse_scatter :: proc(b: ^strings.Builder, items: []Scatter_Item, names: ^Name_Table) {
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
				unparse_expr_nested(b, it.default, names)
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
	// MOO float literals always contain a `.` or exponent so they don't get lexed back as
	// integers on reparse; Odin's %g can omit both for whole numbers (e.g. "5"), so force one.
	s := fmt.tprintf("%g", f)
	defer delete(s, context.temp_allocator)
	has_marker := false
	for c in s {
		if c == '.' || c == 'e' || c == 'E' || c == 'n' || c == 'i' { // 'n'/'i' catch nan/inf
			has_marker = true
			break
		}
	}
	strings.write_string(b, s)
	if !has_marker {
		strings.write_string(b, ".0")
	}
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
