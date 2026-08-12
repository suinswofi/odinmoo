package objdb

// Keeping every object's `propvals` array in sync with its accumulated property layout
// (self-first, root-last -- see property.odin's header) whenever that layout changes:
// add_property/delete_property (a propdef added/removed somewhere in an ancestor chain) and
// chparent (an object's OWN position in the hierarchy changes, so its accumulated layout is
// a completely different splice of ancestors). Ported in spirit rather than line-for-line
// from db_properties.c's insert_prop_recursively/remove_prop_recursively/fix_props, which
// incrementally splice each descendant's propval array at the exact computed index. This
// port instead snapshots each affected object's CURRENT (definer, name) -> value mapping,
// recomputes its layout, and rebuilds propvals by looking up each new layout entry in the
// snapshot (reusing the value if the slot survived, defaulting to CLEAR if it's newly
// inherited) -- more allocation for a large subtree, but far simpler to get right, and DB
// sizes here don't make that tradeoff matter.

import "../dbfile"
import "../values"

@(private = "file")
Prop_Key :: struct {
	definer: values.Objid,
	name:    string,
}

// prop_layout is compute_prop_layout in property.odin's find_property, factored out here so
// both the lookup path and the resync path walk ancestors in exactly the same order (the
// order IS the index assignment).
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

// resync_subtree_propvals rebuilds `oid`'s propvals (matching its CURRENT propdef
// structure) and then does the same for every descendant, recursively -- call this once,
// after whatever propdef-structure change (add/delete/chparent) triggered it, on the single
// object whose OWN position changed (chparent's `what`) or whose propdef list changed
// (add_property/delete_property's target object). `default_owner` is used for any brand new
// (never-before-seen) slot a descendant picks up as a result of the change.
resync_subtree_propvals :: proc(db: ^dbfile.Database, oid: values.Objid, default_owner: values.Objid) {
	resync_one(db, oid, default_owner)
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
		resync_subtree_propvals(db, c, default_owner)
		c = next
	}
}

@(private = "file")
resync_one :: proc(db: ^dbfile.Database, oid: values.Objid, default_owner: values.Objid) {
	obj, ok := db.objects[oid]
	if !ok {
		return
	}

	old_layout := prop_layout(db, oid)
	defer delete(old_layout)
	snapshot := make(map[Prop_Key]values.Var, len(old_layout))
	defer delete(snapshot)
	owners := make(map[Prop_Key]values.Objid, len(old_layout))
	defer delete(owners)
	perms := make(map[Prop_Key]int, len(old_layout))
	defer delete(perms)
	for entry, i in old_layout {
		if i < len(obj.propvals) {
			snapshot[entry] = obj.propvals[i].value
			owners[entry] = obj.propvals[i].owner
			perms[entry] = obj.propvals[i].perms
		}
	}

	new_layout := prop_layout(db, oid)
	defer delete(new_layout)
	new_propvals := make([dynamic]dbfile.Propval, 0, len(new_layout))
	consumed := make(map[Prop_Key]bool, len(new_layout))
	defer delete(consumed)
	for entry in new_layout {
		if v, found := snapshot[entry]; found {
			append(&new_propvals, dbfile.Propval{value = v, owner = owners[entry], perms = perms[entry]})
			consumed[entry] = true
		} else {
			append(&new_propvals, dbfile.Propval{value = values.clear_val(), owner = default_owner, perms = 0})
		}
	}

	// Anything in the old snapshot that didn't survive into the new layout (a propdef that
	// got deleted, or -- for chparent -- an ancestor that's no longer in the chain) owned a
	// value nothing references anymore; free it.
	for entry, v in snapshot {
		if !consumed[entry] {
			values.free_var(v)
		}
	}

	delete(obj.propvals)
	obj.propvals = new_propvals
}
