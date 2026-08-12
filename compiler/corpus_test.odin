package compiler

// The Phase 2 milestone: every one of LambdaCore.db's 1727 real verb programs must parse
// without error, and (parse -> unparse -> reparse) must reproduce an AST of the same shape.
// This turns the whole core database into a parser regression suite for free -- something
// the original project never had either, since it shipped without any test suite at all.

import "../dbfile"
import "core:fmt"
import "core:testing"

@(test)
test_corpus_all_lambdacore_verbs_parse :: proc(t: ^testing.T) {
	db, lerr := dbfile.load_database("/home/consty/LambdaMOO/LambdaCore.db")
	defer dbfile.database_destroy(&db)
	testing.expect(t, lerr.stage == "")

	total := 0
	failed := 0
	reparse_failed := 0
	shape_mismatch := 0

	for _, obj in db.objects {
		for verb in obj.verbdefs {
			if !verb.has_program {
				continue
			}
			total += 1

			r1 := parse_program(verb.program_source, db.version)
			if len(r1.errors) > 0 {
				failed += 1
				if failed <= 10 {
					fmt.printfln(
						"PARSE FAIL #%d:%s -- %s",
						obj.id,
						verb.name,
						r1.errors[0],
					)
				}
				free_stmts(r1.body)
				name_table_destroy(&r1.names)
				for e in r1.errors do delete(e)
				delete(r1.errors)
				continue
			}

			text := unparse_program(r1.body, &r1.names)
			r2 := parse_program(text, db.version)
			delete(text)

			if len(r2.errors) > 0 {
				reparse_failed += 1
				if reparse_failed <= 10 {
					fmt.printfln(
						"REPARSE FAIL #%d:%s -- %s",
						obj.id,
						verb.name,
						r2.errors[0],
					)
				}
			} else if !same_shape_stmts(r1.body, r2.body) {
				shape_mismatch += 1
				if shape_mismatch <= 10 {
					fmt.printfln("SHAPE MISMATCH #%d:%s", obj.id, verb.name)
				}
			}

			free_stmts(r1.body)
			name_table_destroy(&r1.names)
			for e in r1.errors do delete(e)
			delete(r1.errors)

			free_stmts(r2.body)
			name_table_destroy(&r2.names)
			for e in r2.errors do delete(e)
			delete(r2.errors)
		}
	}

	fmt.printfln(
		"corpus: %d verbs, %d parse failures, %d reparse failures, %d shape mismatches",
		total,
		failed,
		reparse_failed,
		shape_mismatch,
	)
	testing.expect(t, total == 1727)
	testing.expectf(t, failed == 0, "%d/%d verbs failed to parse", failed, total)
	testing.expectf(t, reparse_failed == 0, "%d/%d verbs failed to reparse after unparsing", reparse_failed, total)
	testing.expectf(t, shape_mismatch == 0, "%d/%d verbs changed AST shape after round-trip", shape_mismatch, total)
}

// same_shape_stmts is a structural comparison ignoring only the specific pointer
// identities/allocations -- kind-for-kind, field-for-field. It does not need to be a full
// deep-equality (variable *names* may legitimately differ in casing between the two parses'
// independently-built Name_Tables, though slot assignment order should match) -- just
// enough to catch a real shape divergence introduced by a decompiler bug.
same_shape_stmts :: proc(a, b: []Stmt) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if !same_shape_stmt(a[i], b[i]) {
			return false
		}
	}
	return true
}

@(private = "file")
same_shape_stmt :: proc(a, b: Stmt) -> bool {
	switch av in a {
	case ^Stmt_Cond:
		bv, ok := b.(^Stmt_Cond)
		if !ok || len(av.arms) != len(bv.arms) || (av.otherwise == nil) != (bv.otherwise == nil) {
			return false
		}
		for i in 0 ..< len(av.arms) {
			if !same_shape_expr(av.arms[i].condition, bv.arms[i].condition) ||
			   !same_shape_stmts(av.arms[i].body, bv.arms[i].body) {
				return false
			}
		}
		return same_shape_stmts(av.otherwise, bv.otherwise)
	case ^Stmt_List_Loop:
		bv, ok := b.(^Stmt_List_Loop)
		return ok && same_shape_expr(av.list, bv.list) && same_shape_stmts(av.body, bv.body)
	case ^Stmt_Range_Loop:
		bv, ok := b.(^Stmt_Range_Loop)
		return ok && same_shape_expr(av.from, bv.from) && same_shape_expr(av.to, bv.to) && same_shape_stmts(av.body, bv.body)
	case ^Stmt_While:
		bv, ok := b.(^Stmt_While)
		return ok && same_shape_expr(av.condition, bv.condition) && same_shape_stmts(av.body, bv.body)
	case ^Stmt_Fork:
		bv, ok := b.(^Stmt_Fork)
		return ok && same_shape_expr(av.time, bv.time) && same_shape_stmts(av.body, bv.body)
	case ^Stmt_Expr:
		bv, ok := b.(^Stmt_Expr)
		return ok && same_shape_expr(av.expr, bv.expr)
	case ^Stmt_Return:
		bv, ok := b.(^Stmt_Return)
		return ok && same_shape_expr(av.expr, bv.expr)
	case ^Stmt_Try_Except:
		bv, ok := b.(^Stmt_Try_Except)
		if !ok || !same_shape_stmts(av.body, bv.body) || len(av.excepts) != len(bv.excepts) {
			return false
		}
		for i in 0 ..< len(av.excepts) {
			if len(av.excepts[i].codes) != len(bv.excepts[i].codes) ||
			   !same_shape_stmts(av.excepts[i].body, bv.excepts[i].body) {
				return false
			}
		}
		return true
	case ^Stmt_Try_Finally:
		bv, ok := b.(^Stmt_Try_Finally)
		return ok && same_shape_stmts(av.body, bv.body) && same_shape_stmts(av.handler, bv.handler)
	case ^Stmt_Break:
		_, ok := b.(^Stmt_Break)
		return ok
	case ^Stmt_Continue:
		_, ok := b.(^Stmt_Continue)
		return ok
	}
	return false
}

@(private = "file")
same_shape_expr :: proc(a, b: Expr) -> bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	switch av in a {
	case ^Expr_Var:
		bv, ok := b.(^Expr_Var)
		return ok && av.value.type == bv.value.type
	case ^Expr_Id:
		_, ok := b.(^Expr_Id)
		return ok
	case ^Expr_Prop:
		bv, ok := b.(^Expr_Prop)
		return ok && same_shape_expr(av.obj, bv.obj) && same_shape_expr(av.prop, bv.prop)
	case ^Expr_Verb_Call:
		bv, ok := b.(^Expr_Verb_Call)
		return ok && same_shape_expr(av.obj, bv.obj) && same_shape_expr(av.verb, bv.verb) && same_shape_args(av.args, bv.args)
	case ^Expr_Index:
		bv, ok := b.(^Expr_Index)
		return ok && same_shape_expr(av.base, bv.base) && same_shape_expr(av.index, bv.index)
	case ^Expr_Range:
		bv, ok := b.(^Expr_Range)
		return ok && same_shape_expr(av.base, bv.base) && same_shape_expr(av.from, bv.from) && same_shape_expr(av.to, bv.to)
	case ^Expr_Assign:
		bv, ok := b.(^Expr_Assign)
		return ok && same_shape_expr(av.target, bv.target) && same_shape_expr(av.value, bv.value)
	case ^Expr_Call:
		bv, ok := b.(^Expr_Call)
		return ok && av.name == bv.name && same_shape_args(av.args, bv.args)
	case ^Expr_Binary:
		bv, ok := b.(^Expr_Binary)
		return ok && av.op == bv.op && same_shape_expr(av.lhs, bv.lhs) && same_shape_expr(av.rhs, bv.rhs)
	case ^Expr_Unary:
		bv, ok := b.(^Expr_Unary)
		return ok && av.op == bv.op && same_shape_expr(av.operand, bv.operand)
	case ^Expr_List:
		bv, ok := b.(^Expr_List)
		return ok && same_shape_args(av.items, bv.items)
	case ^Expr_Cond:
		bv, ok := b.(^Expr_Cond)
		return ok && same_shape_expr(av.condition, bv.condition) && same_shape_expr(av.consequent, bv.consequent) && same_shape_expr(av.alternate, bv.alternate)
	case ^Expr_Catch:
		bv, ok := b.(^Expr_Catch)
		return ok && same_shape_expr(av.try, bv.try) && len(av.codes) == len(bv.codes) && same_shape_expr(av.handler, bv.handler)
	case ^Expr_Length:
		_, ok := b.(^Expr_Length)
		return ok
	case ^Expr_Scatter:
		bv, ok := b.(^Expr_Scatter)
		if !ok || len(av.items) != len(bv.items) {
			return false
		}
		for i in 0 ..< len(av.items) {
			if av.items[i].kind != bv.items[i].kind {
				return false
			}
		}
		return true
	}
	return false
}

@(private = "file")
same_shape_args :: proc(a, b: []Arg) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i].splice != b[i].splice || !same_shape_expr(a[i].expr, b[i].expr) {
			return false
		}
	}
	return true
}
