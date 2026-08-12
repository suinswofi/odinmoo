package objdb

// Keeping every object's `propvals` array in sync with its accumulated property layout
// (self-first, root-last -- see property.odin's header) whenever that layout changes:
// add_property/delete_property (a propdef added/removed somewhere in an ancestor chain) and
// chparent/recycle (an object's OWN position in the hierarchy changes, so its accumulated
// layout is a completely different splice of ancestors). Ported in spirit rather than
// line-for-line from db_properties.c's insert_prop_recursively/remove_prop_recursively/
// fix_props, which incrementally splice each descendant's propval array at the exact computed
// index. This port instead re-pairs values with the properties they belong to by (definer,
// name) identity, which is far simpler to get right than index arithmetic, at the cost of
// rebuilding the array rather than splicing it -- and these mutations are rare (building/
// programming, never ordinary play), so that tradeoff is free in practice.
//
// USAGE IS TWO-PHASE, and the order matters:
//
//	snap := prop_layout_snapshot(db, oid)   // BEFORE touching propdefs or parent links
//	defer prop_layout_snapshot_destroy(&snap)
//	... mutate propdefs / reparent ...
//	resync_subtree_propvals(db, oid, default_owner, &snap)
//
// The snapshot is what makes the re-pairing possible: a propvals array is just values by
// position, with nothing in it saying which property each slot is for -- that mapping lives
// implicitly in the propdef layout, which the mutation is in the middle of changing. Capturing
// the layout first pins down what the existing slots meant; recomputing it after says where
// they need to go. (An earlier version computed both "before" and "after" layouts *after* the
// mutation, which of course produced two identical layouts -- so every slot appeared to be in
// the right place already, and a delete_property silently shifted every later property's value
// down one slot and dropped the last one. Hence the loud comment: capture before, resync
// after.)

import "../dbfile"
import "../values"

@(private = "file")
Prop_Key :: struct {
	definer: values.Objid,
	name:    string,
}

// Prop_Layout_Snapshot records, for an object and every descendant, which property each of
// its propvals slots currently belongs to. Opaque to callers -- build it with
// prop_layout_snapshot, hand it to resync_subtree_propvals, then destroy it.
Prop_Layout_Snapshot :: struct {
	layouts: map[values.Objid][dynamic]Prop_Key,
}

// prop_layout_snapshot captures `oid` and every descendant's CURRENT property layout. Call it
// before the propdef/parent-link mutation whose effects resync_subtree_propvals will later
// reconcile.
prop_layout_snapshot :: proc(db: ^dbfile.Database, oid: values.Objid) -> Prop_Layout_Snapshot {
	snap := Prop_Layout_Snapshot {
		layouts = make(map[values.Objid][dynamic]Prop_Key),
	}
	snapshot_subtree(db, oid, &snap)
	return snap
}

prop_layout_snapshot_destroy :: proc(snap: ^Prop_Layout_Snapshot) {
	for _, layout in snap.layouts {
		delete(layout)
	}
	delete(snap.layouts)
}

@(private = "file")
snapshot_subtree :: proc(db: ^dbfile.Database, oid: values.Objid, snap: ^Prop_Layout_Snapshot) {
	obj, ok := db.objects[oid]
	if !ok {
		return
	}
	snap.layouts[oid] = prop_layout(db, oid)
	for c := obj.child; c != values.NOTHING; {
		child, cok := db.objects[c]
		if !cok {
			break
		}
		next := child.sibling
		snapshot_subtree(db, c, snap)
		c = next
	}
}

// prop_layout walks the ancestor chain in exactly the order find_property (property.odin)
// assigns propval indices in -- the walk order IS the index assignment, so both paths must
// agree here or lookups land on the wrong slot.
@(private = "file")
prop_layout :: proc(db: ^dbfile.Database, oid: values.Objid) -> [dynamic]Prop_Key {
	layout: [dynamic]Prop_Key
	cur := oid
	for {
		obj, ok := db.objects[cur]
		if !ok {
			break
		}
		for pd in obj.propdefs {
			append(&layout, Prop_Key{definer = cur, name = pd.name})
		}
		if obj.parent == values.NOTHING {
			break
		}
		cur = obj.parent
	}
	return layout
}

// resync_subtree_propvals rebuilds `oid`'s propvals to match its CURRENT propdef structure,
// then does the same for every descendant. `snap` must have been captured (see
// prop_layout_snapshot) before the change that prompted this call. `default_owner` is used for
// any brand new (never-before-seen) slot an object picks up as a result of the change.
resync_subtree_propvals :: proc(db: ^dbfile.Database, oid: values.Objid, default_owner: values.Objid, snap: ^Prop_Layout_Snapshot) {
	resync_one(db, oid, default_owner, snap)
	obj, ok := db.objects[oid]
	if !ok {
		return
	}
	for c := obj.child; c != values.NOTHING; {
		child, cok := db.objects[c]
		if !cok {
			break
		}
		next := child.sibling
		resync_subtree_propvals(db, c, default_owner, snap)
		c = next
	}
}

@(private = "file")
resync_one :: proc(db: ^dbfile.Database, oid: values.Objid, default_owner: values.Objid, snap: ^Prop_Layout_Snapshot) {
	obj, ok := db.objects[oid]
	if !ok {
		return
	}
	old_layout := snap.layouts[oid] // empty for an object that didn't exist at capture time (create)

	// Pair each existing slot with the property it belonged to BEFORE the change. Entries are
	// removed from this map as they're re-placed below, so whatever remains at the end is
	// exactly the set of values the new layout has no home for.
	// (A malformed DB with two propdefs of the same name on one object would collapse into a
	// single entry here and lose one value -- it can't double-free, and add_property's own
	// duplicate check makes that state unreachable through any supported path.)
	surviving := make(map[Prop_Key]dbfile.Propval, len(old_layout))
	defer delete(surviving)
	for key, i in old_layout {
		if i >= len(obj.propvals) {
			break // malformed/partially-built object; keep what we can rather than crashing
		}
		surviving[key] = obj.propvals[i]
	}

	new_layout := prop_layout(db, oid)
	defer delete(new_layout)
	new_propvals := make([dynamic]dbfile.Propval, 0, len(new_layout))
	for key in new_layout {
		if pv, found := surviving[key]; found {
			append(&new_propvals, pv)
			delete_key(&surviving, key)
		} else {
			append(&new_propvals, dbfile.Propval{value = values.clear_val(), owner = default_owner, perms = 0})
		}
	}

	// Left over: a propdef that got deleted, or (for chparent/recycle) an ancestor that's no
	// longer in the chain. Nothing references those values anymore.
	for _, pv in surviving {
		values.free_var(pv.value)
	}

	delete(obj.propvals)
	obj.propvals = new_propvals
}
