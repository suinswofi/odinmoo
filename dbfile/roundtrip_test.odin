package dbfile

// Write-then-reread round trip against the real LambdaCore.db -- the concrete validation
// for write.odin, added for Phase 8's checkpoint support. Structural counts (not a byte-
// for-byte diff) are what matter: this port's writer doesn't need to reproduce the
// original's exact formatting choices (e.g. float precision, field ordering trivia), only
// to write something this same reader loads back into an equivalent database.

import "core:os"
import "core:testing"

@(test)
test_save_and_reload_lambdacore_db :: proc(t: ^testing.T) {
	db1, lerr1 := load_database("LambdaCore.db")
	defer database_destroy(&db1)
	testing.expect(t, lerr1.stage == "")

	tmp_path := "/tmp/lambdacore_roundtrip_test.db"
	defer os.remove(tmp_path)
	ok := save_database(&db1, tmp_path)
	testing.expect(t, ok)

	db2, lerr2 := load_database(tmp_path)
	defer database_destroy(&db2)
	testing.expectf(t, lerr2.stage == "", "reload failed at %s: %v", lerr2.stage, lerr2.err)

	testing.expect(t, db2.version == db1.version)
	testing.expect(t, len(db2.objects) == len(db1.objects))
	testing.expect(t, db2.max_oid == db1.max_oid)
	testing.expect(t, len(db2.users) == len(db1.users))
	testing.expect(t, len(db2.forked_tasks) == len(db1.forked_tasks))
	testing.expect(t, db2.suspended_task_count == db1.suspended_task_count)
	testing.expect(t, len(db2.connections) == len(db1.connections))

	nverbs1, nverbs2 := 0, 0
	nprogs1, nprogs2 := 0, 0
	npropvals1, npropvals2 := 0, 0
	for _, o in db1.objects {
		nverbs1 += len(o.verbdefs)
		npropvals1 += len(o.propvals)
		for v in o.verbdefs {
			if v.has_program {
				nprogs1 += 1
			}
		}
	}
	for _, o in db2.objects {
		nverbs2 += len(o.verbdefs)
		npropvals2 += len(o.propvals)
		for v in o.verbdefs {
			if v.has_program {
				nprogs2 += 1
			}
		}
	}
	testing.expectf(t, nverbs1 == nverbs2, "verbdefs: %d vs %d", nverbs1, nverbs2)
	testing.expectf(t, nprogs1 == nprogs2, "verb programs: %d vs %d", nprogs1, nprogs2)
	testing.expectf(t, npropvals1 == npropvals2, "propvals: %d vs %d", npropvals1, npropvals2)

	// Spot-check actual content survived, not just counts: #0's name and a couple of
	// verb sources should be byte-identical after the round trip.
	sys1 := db1.objects[0]
	sys2 := db2.objects[0]
	testing.expect(t, sys1.name == sys2.name)
	testing.expect(t, len(sys1.verbdefs) == len(sys2.verbdefs))
	if len(sys1.verbdefs) == len(sys2.verbdefs) {
		for i in 0 ..< len(sys1.verbdefs) {
			testing.expectf(
				t,
				sys1.verbdefs[i].program_source == sys2.verbdefs[i].program_source,
				"verb #0:%d source mismatch after round trip",
				i,
			)
		}
	}
}
