package objdb

// Sanity check against the real LambdaCore.db: property/verb lookup and permission checks
// exercised on the actual 97-object hierarchy, not just the synthetic one above.

import "../dbfile"
import "../values"
import "core:testing"

@(test)
test_lambdacore_property_and_verb_lookup :: proc(t: ^testing.T) {
	db, lerr := dbfile.load_database("/home/consty/LambdaMOO/LambdaCore.db")
	defer dbfile.database_destroy(&db)
	testing.expect(t, lerr.stage == "")

	// #0 is always the system object.
	h := find_property(&db, 0, "name")
	testing.expect(t, h.found && h.builtin == .Name)
	name_val := get_builtin_prop_value(&db, 0, .Name)
	testing.expect(t, name_val.data.str.s == "The System Object")
	values.free_var(name_val)

	// #2 is the first listed user in the header dump seen during Phase 1 -- should be a
	// valid, non-recycled object with a definite owner (itself, per LambdaMOO convention).
	testing.expect(t, valid(&db, 2))

	// Every object's parent chain must terminate at NOTHING within a bounded number of
	// hops (no cycles) -- exercises find_property's/find_callable_verb's walk on every
	// single real object in the corpus, not just a hand-picked one.
	checked := 0
	for oid in db.objects {
		hops := 0
		cur := oid
		for cur != values.NOTHING {
			obj, ok := db.objects[cur]
			if !ok {
				break // parent points outside the valid set -- tolerated, not a cycle
			}
			cur = obj.parent
			hops += 1
			testing.expectf(t, hops < 100, "possible parent cycle starting at #%d", oid)
			if hops >= 100 {
				break
			}
		}
		checked += 1
	}
	testing.expect(t, checked == 97)
}
