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

	// For a slot this object is picking up by inheritance, the permissions come from the
	// parent's own slot for that property, not from nowhere: db_properties.c's fix_props
	// (:588-593) copies the parent's Pval wholesale, sets the value to CLEAR, and replaces
	// the owner with this object's owner only when PF_CHOWN is set. Defaulting to perms 0
	// instead makes every inherited property unreadable by anyone but its owner -- which
	// silently breaks utility code that reads a property off a freshly created object
	// (JHCore's $quota_utils:charge_quota reads <new object>.object_size, defined "r" on an
	// ancestor, and gets E_PERM -- aborting the whole create, and with it the connect path
	// that creates an MCP session).
	parent_slots := parent_propval_index(db, oid)
	defer delete(parent_slots)

	new_layout := prop_layout(db, oid)
	defer delete(new_layout)
	new_propvals := make([dynamic]dbfile.Propval, 0, len(new_layout))
	for key in new_layout {
		if pv, found := surviving[key]; found {
			append(&new_propvals, pv)
			delete_key(&surviving, key)
		} else {
			append(&new_propvals, fresh_propval(db, obj, key, parent_slots, default_owner))
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

// parent_propval_index maps each property in `oid`'s parent's layout to that parent's
// propval slot, so fresh_propval can find the Pval to inherit permissions from. Empty map
// when there's no (valid) parent.
@(private = "file")
parent_propval_index :: proc(db: ^dbfile.Database, oid: values.Objid) -> map[Prop_Key]int {
	index := make(map[Prop_Key]int)
	obj, ok := db.objects[oid]
	if !ok || obj.parent == values.NOTHING {
		return index
	}
	parent, pok := db.objects[obj.parent]
	if !pok {
		return index
	}
	layout := prop_layout(db, obj.parent)
	defer delete(layout)
	for key, i in layout {
		if i < len(parent.propvals) {
			index[key] = i
		}
	}
	return index
}

// fresh_propval builds the Pval for a slot this object is newly inheriting, following
// fix_props (db_properties.c:588-593): the parent's Pval with a CLEAR value, re-owned to
// this object's owner only if the property is PF_CHOWN ("c"). With no parent slot to copy --
// a propdef defined on this object itself -- there is nothing to inherit, so the caller's
// default owner and no permission bits stand, as before.
@(private = "file")
fresh_propval :: proc(
	db: ^dbfile.Database,
	obj: ^dbfile.Object,
	key: Prop_Key,
	parent_slots: map[Prop_Key]int,
	default_owner: values.Objid,
) -> dbfile.Propval {
	slot, found := parent_slots[key]
	if !found {
		return dbfile.Propval{value = values.clear_val(), owner = default_owner, perms = 0}
	}
	parent, pok := db.objects[obj.parent]
	if !pok || slot >= len(parent.propvals) {
		return dbfile.Propval{value = values.clear_val(), owner = default_owner, perms = 0}
	}
	src := parent.propvals[slot]
	owner := src.owner
	if src.perms & (1 << uint(Prop_Flag.Chown)) != 0 {
		owner = obj.owner
	}
	return dbfile.Propval{value = values.clear_val(), owner = owner, perms = src.perms}
}
