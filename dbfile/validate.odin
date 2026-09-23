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
// A second precondition lives here too: every object's propvals array must be exactly as long
// as its accumulated property layout (see check_propval_layout below). objdb indexes that
// array with a running count derived from the parent chain, also without a bounds check.
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

	// Cycle detection, on ALL FOUR chains objdb walks -- not just the two it used to cover.
	// A cycle passes the link check above (every id in it is a real object) but still hangs
	// any walk that follows it to the end.
	//
	// parent and location were checked here from the start; contents/next and child/sibling
	// were not, and that was a straightforward hole in the same invariant, because objdb walks
	// those two just as unguardedly: db_change_location and list_contents and match_contents
	// follow contents->next, while bf_children, property_defined_at_or_below,
	// db_change_parent_links and prop_resync's subtree walks follow child->sibling. A .db with
	// `#1.contents = #2; #2.next = #2` loaded cleanly and then spun forever (or grew a list
	// until the process died) the first time anyone looked in that room.
	for l in Link {
		if !chains_terminate(db, l) {
			return .Bad_Format
		}
	}
	// Runs last: it walks parent chains, which the loop above has just proved terminate.
	return check_propval_layout(db)
}

// chains_terminate proves that following `l` from every object ends at NOTHING, in time
// linear in the object count.
//
// It used to walk each object's chain to the end independently, cutting a walk off after
// object-count steps as proof of a loop. That is linear for contents/next and child/sibling in
// a well-formed file, where each list is walked once from its head, but NOT for parent and
// location: every object re-walked its whole ancestor (or container) chain, O(objects x
// depth), and `create()` in a loop builds that depth. A 32000-deep parent chain took 19.5
// seconds to validate -- on every restart, before the server listened -- and 64000 about 80.
//
// So each object is resolved once: a walk stops at the first object already proven to reach
// NOTHING, and everything it passed through is then marked proven too. Reaching an object
// that is on the CURRENT walk is the loop.
@(private = "file")
chains_terminate :: proc(db: ^Database, l: Link) -> bool {
	Mark :: enum u8 {
		Unvisited,
		On_Walk,
		Proven,
	}
	marks := make(map[values.Objid]Mark, len(db.objects))
	defer delete(marks)
	path := make([dynamic]values.Objid, 0, 16)
	defer delete(path)
	for start in db.objects {
		clear(&path)
		id := start
		for id != values.NOTHING {
			m := marks[id]
			if m == .Proven {
				break
			}
			if m == .On_Walk {
				return false
			}
			o, ok := db.objects[id]
			if !ok {
				return false
			}
			marks[id] = .On_Walk
			append(&path, id)
			id = follow_link(o, l)
		}
		for p in path {
			marks[p] = .Proven
		}
	}
	return true
}

// check_propval_layout enforces the other invariant objdb indexes unguardedly. find_property
// (objdb/property.odin) accumulates a running index across the ancestor chain's propdef lists
// and then reads the STARTING object's propvals at that index, with no bounds check, because a
// well-formed database guarantees the two agree -- every object carries one value slot per
// property defined anywhere above it. Nothing made that a precondition of loading, so a
// hand-edited or truncated .db turned an ordinary `obj.prop` read into an out-of-range panic,
// far from the actual damage. cmd/jhverify has always audited this ("inheritance-count
// mismatches: 0"); this makes it a load-time precondition, exactly as the graph checks above
// are. All three bundled cores pass unchanged.
//
// The walk below is deliberately the same shape as find_property's -- self first, then up to
// the root -- because the walk order IS the index assignment; if they ever disagree, this is
// the half that is wrong.
//
// Each object's expected count is its own propdefs plus its parent's expected count, so it is
// memoized rather than re-walked to the root per object -- for the same O(objects x depth)
// reason chains_terminate explains.
@(private = "file")
check_propval_layout :: proc(db: ^Database) -> Read_Error {
	want := make(map[values.Objid]int, len(db.objects))
	defer delete(want)
	path := make([dynamic]^Object, 0, 16)
	defer delete(path)
	for oid in db.objects {
		// Climb to the first ancestor whose count is already known (or past the root), then
		// fill in counts back down the path.
		clear(&path)
		base := 0
		for cur := oid; cur != values.NOTHING; {
			if n, known := want[cur]; known {
				base = n
				break
			}
			o, ok := db.objects[cur]
			if !ok {
				break
			}
			append(&path, o)
			cur = o.parent
		}
		for i := len(path) - 1; i >= 0; i -= 1 {
			base += len(path[i].propdefs)
			want[path[i].id] = base
		}
	}
	for oid, obj in db.objects {
		if len(obj.propvals) != want[oid] {
			return .Bad_Format
		}
	}
	return .None
}

// Link names which field a chain walk follows out of each object it reaches. The four values
// are exactly the four chains objdb follows without a validity check of its own.
@(private = "file")
Link :: enum {
	Parent, // o.parent  -- the inheritance chain
	Location, // o.location -- the containment chain
	Next, // o.next     -- the rest of the contents list this object is in
	Sibling, // o.sibling  -- the rest of the child list this object is in
}

@(private = "file")
follow_link :: proc(o: ^Object, l: Link) -> values.Objid {
	switch l {
	case .Parent:
		return o.parent
	case .Location:
		return o.location
	case .Next:
		return o.next
	case .Sibling:
		return o.sibling
	}
	return values.NOTHING
}
