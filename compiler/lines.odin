package compiler

// Line numbers, ported from decompile.c's find_hot_node()/find_line_number().
//
// The original never keeps the source text's line numbers. A verb's line numbers are positions
// in its DECOMPILED listing -- the same numbering `@list` shows, one line per simple statement
// plus one each for the structural lines (`if`, `elseif`, `else`, `endif`, `for`, `endfor`,
// `try`, `except`, `finally`, `endtry`, ...). find_line_number() recovers the line for a pc by
// decompiling the program and walking that tree with exactly the counting below, so tracebacks,
// callers(1) and the stack list handed to an `except` arm all speak in listing lines, whatever
// the stored source text looked like.
//
// This port has the tree already, so the same walk runs once at compile time and stores each
// construct's first line on it. At run time the interpreter just records the line of the
// statement (or `elseif` arm, or loop head) it is currently executing.

// assign_line_numbers numbers `stmts` starting at `first` (the original's first_lineno, which
// is always 1 for a verb or an eval()).
assign_line_numbers :: proc(stmts: []Stmt, first: int = 1) {
	lineno := first
	number_stmts(stmts, &lineno)
}

@(private = "file")
number_stmts :: proc(stmts: []Stmt, lineno: ^int) {
	for s in stmts {
		switch v in s {
		case ^Stmt_Cond:
			v.line = lineno^
			for &arm in v.arms {
				arm.line = lineno^
				lineno^ += 1 // the `if`/`elseif` line itself
				number_stmts(arm.body, lineno)
			}
			if v.otherwise != nil {
				lineno^ += 1 // the `else` line
				number_stmts(v.otherwise, lineno)
			}
		case ^Stmt_List_Loop:
			v.line = lineno^
			lineno^ += 1
			number_stmts(v.body, lineno)
		case ^Stmt_Range_Loop:
			v.line = lineno^
			lineno^ += 1
			number_stmts(v.body, lineno)
		case ^Stmt_While:
			v.line = lineno^
			lineno^ += 1
			number_stmts(v.body, lineno)
		case ^Stmt_Fork:
			v.line = lineno^
			lineno^ += 1
			number_stmts(v.body, lineno)
		case ^Stmt_Expr:
			v.line = lineno^
		case ^Stmt_Return:
			v.line = lineno^
		case ^Stmt_Break:
			v.line = lineno^
		case ^Stmt_Continue:
			v.line = lineno^
		case ^Stmt_Try_Except:
			v.line = lineno^
			lineno^ += 1 // `try`
			number_stmts(v.body, lineno)
			for &arm in v.excepts {
				arm.line = lineno^
				lineno^ += 1 // `except`
				number_stmts(arm.body, lineno)
			}
		case ^Stmt_Try_Finally:
			v.line = lineno^
			lineno^ += 1 // `try`
			number_stmts(v.body, lineno)
			lineno^ += 1 // `finally`
			number_stmts(v.handler, lineno)
		}
		// The statement itself, or for a compound one its closing `end...` line.
		lineno^ += 1
	}
}
