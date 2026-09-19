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
	// Every chain is bounded by the number of objects, so exceeding that is proof of a loop --
	// cheaper and simpler than marking visited sets, and it cannot itself run away. A cycle
	// passes the link check above (every id in it is a real object) but still hangs any walk
	// that follows it to the end.
	//
	// parent and location were checked here from the start; contents/next and child/sibling
	// were not, and that was a straightforward hole in the same invariant, because objdb walks
	// those two just as unguardedly: db_change_location and list_contents and match_contents
	// follow contents->next, while bf_children, property_defined_at_or_below,
	// db_change_parent_links and prop_resync's subtree walks follow child->sibling. A .db with
	// `#1.contents = #2; #2.next = #2` loaded cleanly and then spun forever (or grew a list
	// until the process died) the first time anyone looked in that room.
	//
	// Cost is linear, not quadratic: each object's contents and child lists are walked once
	// each, and summed over all objects that is at most one visit per object per chain kind
	// (an object appears in exactly one contents list and one child list in a well-formed DB).
	// A cycle is what makes a single walk long, and `limit` cuts that one off immediately.
	limit := len(db.objects) + 1
	for _, obj in db.objects {
		if !chain_ok(db, obj.parent, .Parent, limit) ||
		   !chain_ok(db, obj.location, .Location, limit) ||
		   !chain_ok(db, obj.contents, .Next, limit) ||
		   !chain_ok(db, obj.child, .Sibling, limit) {
			return .Bad_Format
		}
	}
	// Runs last: it walks parent chains, which the loop above has just proved terminate.
	return check_propval_layout(db)
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
@(private = "file")
check_propval_layout :: proc(db: ^Database) -> Read_Error {
	for oid, obj in db.objects {
		want := 0
		cur := oid
		for {
			o, ok := db.objects[cur]
			if !ok {
				break
			}
			want += len(o.propdefs)
			if o.parent == values.NOTHING {
				break
			}
			cur = o.parent
		}
		if len(obj.propvals) != want {
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

// chain_ok walks from `head` following `l`, failing on a dangling id or on more than `limit`
// steps (which, `limit` being the object count, can only mean the chain loops).
@(private = "file")
chain_ok :: proc(db: ^Database, head: values.Objid, l: Link, limit: int) -> bool {
	steps := 0
	for id := head; id != values.NOTHING; {
		o, ok := db.objects[id]
		if !ok {
			return false
		}
		steps += 1
		if steps > limit {
			return false
		}
		id = follow_link(o, l)
	}
	return true
}
