package compiler

// Deep AST copy -- the ownership counterpart to ast_destroy.odin's free_stmts (each clone_*
// mirrors the corresponding free_* exactly; if a node type gains an owned field, both files
// change together).
//
// Exists for `fork`: the original refcounts the enclosing Program (tasks.c's
// enqueue_forked_task2 does program_ref()) so a queued forked task keeps its code alive no
// matter what happens to the program that spawned it -- set_verb_code() replacing the verb,
// eval()'s program being torn down when eval() returns, a test freeing its parse result.
// This port's ASTs are plain owned trees with no refcount header, so the equivalent
// guarantee is a deep copy taken at fork time (tasks/fork.odin's do_fork); everything else
// still runs the single shared tree it was handed. Forks are rare and verb bodies small, so
// the copy is noise next to the OS thread spawn right beside it.

import "../values"

clone_stmts :: proc(stmts: []Stmt) -> []Stmt {
	out := make([]Stmt, len(stmts))
	for s, i in stmts {
		out[i] = clone_stmt(s)
	}
	return out
}

clone_stmt :: proc(s: Stmt) -> Stmt {
	switch v in s {
	case ^Stmt_Cond:
		c := new(Stmt_Cond)
		arms := make([]Cond_Arm, len(v.arms))
		for arm, i in v.arms {
			arms[i] = Cond_Arm{condition = clone_expr(arm.condition), body = clone_stmts(arm.body)}
		}
		c.arms = arms
		c.otherwise = clone_stmts(v.otherwise)
		return c
	case ^Stmt_List_Loop:
		c := new(Stmt_List_Loop)
		c.var_id = v.var_id
		c.list = clone_expr(v.list)
		c.body = clone_stmts(v.body)
		return c
	case ^Stmt_Range_Loop:
		c := new(Stmt_Range_Loop)
		c.var_id = v.var_id
		c.from = clone_expr(v.from)
		c.to = clone_expr(v.to)
		c.body = clone_stmts(v.body)
		return c
	case ^Stmt_While:
		c := new(Stmt_While)
		c.var_id = v.var_id
		c.condition = clone_expr(v.condition)
		c.body = clone_stmts(v.body)
		return c
	case ^Stmt_Fork:
		c := new(Stmt_Fork)
		c.var_id = v.var_id
		c.time = clone_expr(v.time)
		c.body = clone_stmts(v.body)
		return c
	case ^Stmt_Expr:
		c := new(Stmt_Expr)
		c.expr = clone_expr(v.expr)
		return c
	case ^Stmt_Return:
		c := new(Stmt_Return)
		c.expr = clone_expr(v.expr)
		return c
	case ^Stmt_Try_Except:
		c := new(Stmt_Try_Except)
		c.body = clone_stmts(v.body)
		excepts := make([]Except_Arm, len(v.excepts))
		for arm, i in v.excepts {
			excepts[i] = Except_Arm{var_id = arm.var_id, codes = clone_args(arm.codes), body = clone_stmts(arm.body)}
		}
		c.excepts = excepts
		return c
	case ^Stmt_Try_Finally:
		c := new(Stmt_Try_Finally)
		c.body = clone_stmts(v.body)
		c.handler = clone_stmts(v.handler)
		return c
	case ^Stmt_Break:
		c := new(Stmt_Break)
		c.var_id = v.var_id
		return c
	case ^Stmt_Continue:
		c := new(Stmt_Continue)
		c.var_id = v.var_id
		return c
	}
	return nil
}

// clone_args preserves nil-ness: several owners (Expr_Catch.codes, Except_Arm.codes) use
// nil to mean ANY, which is distinct from an empty list.
clone_args :: proc(args: []Arg) -> []Arg {
	if args == nil {
		return nil
	}
	out := make([]Arg, len(args))
	for a, i in args {
		out[i] = Arg{splice = a.splice, expr = clone_expr(a.expr)}
	}
	return out
}

clone_expr :: proc(e: Expr) -> Expr {
	switch v in e {
	case ^Expr_Var:
		c := new(Expr_Var)
		c.value = values.var_ref(v.value) // refcounted payload; free_expr's free_var balances it
		return c
	case ^Expr_Id:
		c := new(Expr_Id)
		c.var_id = v.var_id
		return c
	case ^Expr_Prop:
		c := new(Expr_Prop)
		c.obj = clone_expr(v.obj)
		c.prop = clone_expr(v.prop)
		return c
	case ^Expr_Verb_Call:
		c := new(Expr_Verb_Call)
		c.obj = clone_expr(v.obj)
		c.verb = clone_expr(v.verb)
		c.args = clone_args(v.args)
		return c
	case ^Expr_Index:
		c := new(Expr_Index)
		c.base = clone_expr(v.base)
		c.index = clone_expr(v.index)
		return c
	case ^Expr_Range:
		c := new(Expr_Range)
		c.base = clone_expr(v.base)
		c.from = clone_expr(v.from)
		c.to = clone_expr(v.to)
		return c
	case ^Expr_Assign:
		c := new(Expr_Assign)
		c.target = clone_expr(v.target)
		c.value = clone_expr(v.value)
		return c
	case ^Expr_Call:
		c := new(Expr_Call)
		c.name = clone_string_local(v.name)
		c.is_known = v.is_known
		c.args = clone_args(v.args)
		return c
	case ^Expr_Binary:
		c := new(Expr_Binary)
		c.op = v.op
		c.lhs = clone_expr(v.lhs)
		c.rhs = clone_expr(v.rhs)
		return c
	case ^Expr_Unary:
		c := new(Expr_Unary)
		c.op = v.op
		c.operand = clone_expr(v.operand)
		return c
	case ^Expr_List:
		c := new(Expr_List)
		c.items = clone_args(v.items)
		return c
	case ^Expr_Cond:
		c := new(Expr_Cond)
		c.condition = clone_expr(v.condition)
		c.consequent = clone_expr(v.consequent)
		c.alternate = clone_expr(v.alternate)
		return c
	case ^Expr_Catch:
		c := new(Expr_Catch)
		c.try = clone_expr(v.try)
		c.codes = clone_args(v.codes)
		c.handler = clone_expr(v.handler)
		return c
	case ^Expr_Length:
		return new(Expr_Length)
	case ^Expr_Scatter:
		c := new(Expr_Scatter)
		items := make([]Scatter_Item, len(v.items))
		for it, i in v.items {
			items[i] = Scatter_Item{kind = it.kind, var_id = it.var_id, default = clone_expr(it.default)}
		}
		c.items = items
		return c
	}
	return nil
}

// name_table_clone gives a fork job its own Name_Table (destroy with name_table_destroy),
// for the same lifetime reason as clone_stmts above.
name_table_clone :: proc(t: ^Name_Table) -> Name_Table {
	out := Name_Table{}
	for n in t.names {
		append(&out.names, clone_string_local(n))
	}
	return out
}

@(private = "file")
clone_string_local :: proc(s: string) -> string {
	buf := make([]byte, len(s))
	copy(buf, s)
	return string(buf)
}
