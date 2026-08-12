package dbfile

// Structural load test against the real LambdaCore.db shipped in the repo -- this is the
// Phase 1 milestone: "load LambdaCore.db, report counts" with a concrete pass/fail signal,
// cross-checked against both `grep -c` over the raw file and the reference C `moo -e`
// binary's own load log (97 objects, 1727 verb programs, matching exactly).

import "core:testing"

@(test)
test_load_lambdacore_db :: proc(t: ^testing.T) {
	db, lerr := load_database("/home/consty/LambdaMOO/LambdaCore.db")
	defer database_destroy(&db)

	testing.expect(t, lerr.stage == "", lerr.stage)
	testing.expect(t, db.version == 4)
	testing.expect(t, len(db.objects) == 97)
	testing.expect(t, db.max_oid == 96)
	testing.expect(t, len(db.users) == 5)
	testing.expect(t, len(db.forked_tasks) == 1)
	testing.expect(t, db.suspended_task_count == 0)
	testing.expect(t, len(db.connections) == 0)

	nverbs := 0
	nverbs_with_program := 0
	for _, obj in db.objects {
		nverbs += len(obj.verbdefs)
		for v in obj.verbdefs {
			if v.has_program {
				nverbs_with_program += 1
			}
		}
	}
	testing.expect(t, nverbs_with_program == 1727) // matches grep -c '^#N:N$' exactly
	testing.expect(t, nverbs == 1728)               // one verbdef has no attached program

	// #0 is always the system object; sanity-check a couple of well-known fields survived
	// the round trip through our record parser.
	sysobj, found := db.objects[0]
	testing.expect(t, found)
	testing.expect(t, sysobj.name == "The System Object")
}

@(test)
test_load_rejects_bad_header :: proc(t: ^testing.T) {
	db, lerr := load_database_bytes(transmute([]byte)string("not a moo db\n"))
	defer database_destroy(&db)
	testing.expect(t, lerr.stage == "header")
}
