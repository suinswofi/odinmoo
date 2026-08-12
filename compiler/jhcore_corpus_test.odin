package compiler

// Same corpus check as corpus_test.odin, against the second bundled core: every one of
// jhcore.db's 2729 verb programs must parse, and (parse -> unparse -> reparse) must produce
// an AST of the same shape. JHCore is a larger, independently-evolved core than LambdaCore,
// so it exercises grammar and decompiler paths LambdaCore never reaches.

import "../dbfile"
import "core:fmt"
import "core:testing"

@(test)
test_corpus_all_jhcore_verbs_parse :: proc(t: ^testing.T) {
	db, lerr := dbfile.load_database("jhcore.db")
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
					fmt.printfln("PARSE FAIL #%d:%s -- %s", obj.id, verb.name, r1.errors[0])
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
					fmt.printfln("REPARSE FAIL #%d:%s -- %s", obj.id, verb.name, r2.errors[0])
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
		"jhcore corpus: %d verbs, %d parse failures, %d reparse failures, %d shape mismatches",
		total, failed, reparse_failed, shape_mismatch,
	)
	testing.expect(t, total == 2729)
	testing.expectf(t, failed == 0, "%d/%d verbs failed to parse", failed, total)
	testing.expectf(t, reparse_failed == 0, "%d/%d verbs failed to reparse after unparsing", reparse_failed, total)
	testing.expectf(t, shape_mismatch == 0, "%d/%d verbs changed AST shape after round-trip", shape_mismatch, total)
}
