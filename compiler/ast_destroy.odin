package compiler

// Deep AST teardown. The original never needed this in one place -- `dealloc_node`/
// `free_stmt` (ast.c) free individual nodes as compilation proceeds, since C has no
// borrow-checking to make "who owns this tree" self-evident. Here, a Parse_Result's `body`
// owns its whole tree outright (nothing aliases into it once parsing finishes), so a single
// recursive destroy matches the actual ownership shape.

import "../values"

free_stmts :: proc(stmts: []Stmt) {
	for s in stmts {
		free_stmt(s)
	}
	delete(stmts)
}

free_stmt :: proc(s: Stmt) {
	switch v in s {
	case ^Stmt_Cond:
		for arm in v.arms {
			free_expr(arm.condition)
			free_stmts(arm.body)
		}
		delete(v.arms)
		free_stmts(v.otherwise)
		free(v)
	case ^Stmt_List_Loop:
		free_expr(v.list)
		free_stmts(v.body)
		free(v)
	case ^Stmt_Range_Loop:
		free_expr(v.from)
		free_expr(v.to)
		free_stmts(v.body)
		free(v)
	case ^Stmt_While:
		free_expr(v.condition)
		free_stmts(v.body)
		free(v)
	case ^Stmt_Fork:
		free_expr(v.time)
		free_stmts(v.body)
		free(v)
	case ^Stmt_Expr:
		free_expr(v.expr)
		free(v)
	case ^Stmt_Return:
		free_expr(v.expr)
		free(v)
	case ^Stmt_Try_Except:
		free_stmts(v.body)
		for arm in v.excepts {
			free_args(arm.codes)
			free_stmts(arm.body)
		}
		delete(v.excepts)
		free(v)
	case ^Stmt_Try_Finally:
		free_stmts(v.body)
		free_stmts(v.handler)
		free(v)
	case ^Stmt_Break:
		free(v)
	case ^Stmt_Continue:
		free(v)
	}
}

free_args :: proc(args: []Arg) {
	for a in args {
		free_expr(a.expr)
	}
	delete(args)
}

free_expr :: proc(e: Expr) {
	switch v in e {
	case ^Expr_Var:
		values.free_var(v.value)
		free(v)
	case ^Expr_Id:
		free(v)
	case ^Expr_Prop:
		free_expr(v.obj)
		free_expr(v.prop)
		free(v)
	case ^Expr_Verb_Call:
		free_expr(v.obj)
		free_expr(v.verb)
		free_args(v.args)
		free(v)
	case ^Expr_Index:
		free_expr(v.base)
		free_expr(v.index)
		free(v)
	case ^Expr_Range:
		free_expr(v.base)
		free_expr(v.from)
		free_expr(v.to)
		free(v)
	case ^Expr_Assign:
		free_expr(v.target)
		free_expr(v.value)
		free(v)
	case ^Expr_Call:
		delete(v.name)
		free_args(v.args)
		free(v)
	case ^Expr_Binary:
		free_expr(v.lhs)
		free_expr(v.rhs)
		free(v)
	case ^Expr_Unary:
		free_expr(v.operand)
		free(v)
	case ^Expr_List:
		free_args(v.items)
		free(v)
	case ^Expr_Cond:
		free_expr(v.condition)
		free_expr(v.consequent)
		free_expr(v.alternate)
		free(v)
	case ^Expr_Catch:
		free_expr(v.try)
		free_args(v.codes)
		free_expr(v.handler)
		free(v)
	case ^Expr_Length:
		free(v)
	case ^Expr_Scatter:
		for it in v.items {
			free_expr(it.default)
		}
		delete(v.items)
		free(v)
	}
}
