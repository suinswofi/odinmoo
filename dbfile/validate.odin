package dbfile

// Structural validation of the object graph, run at the end of every load.
//
// Every walk over the object graph in `objdb` -- the parent chain in property lookup, the
// child/sibling chain in property_defined_at_or_below, the location/contents/next chains in
// move() and recycle() -- indexes db.objects with an id taken straight out of another
// object's link field, with no validity check. That is not sloppiness: it is correct, and
// stays readable, PRECISELY BECAUSE the graph is supposed to be internally consistent. The
// problem was that nothing established that invariant, so a damaged or hand-edited .db turned
// those walks into nil dereferences (Odin hands back a nil ^Object for a missing key, and the
// next field access segfaults) or, for a parent chain that loops back on itself, into an
// infinite loop inside chparent()/property lookup.
//
// Checking once, here, is what lets all of those walks stay as they are. The same checks are
// what cmd/jhverify has always reported on ("parent chains: 0 cycles, 0 dangling parents");
// this just makes them a precondition of loading rather than an after-the-fact audit. All
// three bundled cores pass unchanged.
//
// `owner` is deliberately NOT checked: an object owned by an invalid id is odd but harmless,
// because owner is only ever compared, never dereferenced.

import "../values"

// validate_hierarchies returns the first structural problem it finds, or .None.
validate_hierarchies :: proc(db: ^Database) -> Read_Error {
	link_ok :: proc(db: ^Database, id: values.Objid) -> bool {
		if id == values.NOTHING {
			return true
		}
		_, ok := db.objects[id]
		return ok
	}

	for _, obj in db.objects {
		if !link_ok(db, obj.parent) ||
		   !link_ok(db, obj.child) ||
		   !link_ok(db, obj.sibling) ||
		   !link_ok(db, obj.location) ||
		   !link_ok(db, obj.contents) ||
		   !link_ok(db, obj.next) {
			return .Bad_Format
		}
	}

	// Cycle detection. Every chain is bounded by the number of objects, so exceeding that is
	// proof of a loop -- cheaper and simpler than marking visited sets, and it cannot itself
	// run away. A cycle passes the link check above (every id in it is a real object) but
	// still hangs any walk that follows it to the end.
	limit := len(db.objects) + 1
	for _, obj in db.objects {
		steps := 0
		for id := obj.parent; id != values.NOTHING; {
			o, ok := db.objects[id]
			if !ok {
				return .Bad_Format
			}
			steps += 1
			if steps > limit {
				return .Bad_Format
			}
			id = o.parent
		}
		steps = 0
		for id := obj.location; id != values.NOTHING; {
			o, ok := db.objects[id]
			if !ok {
				return .Bad_Format
			}
			steps += 1
			if steps > limit {
				return .Bad_Format
			}
			id = o.location
		}
	}
	return .None
}
