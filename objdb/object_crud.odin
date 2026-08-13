package objdb

// Object lifecycle built-ins -- create()/recycle()/chparent()/renumber()/reset_max_object(),
// ported from objects.c/server.c. Unlike the C original (which spreads create()/recycle()
// across multiple suspend/resume "next" steps so the VM can yield around the
// :initialize/:recycle/:exitfunc/:enterfunc verb calls each triggers), this port's
// tree-walking VM just calls those verbs directly and synchronously -- the same
// simplification already used by move() and pass(), for the same reason (see
// vm/activation.odin's header note on why this port doesn't need bytecode-level
// suspend points).

import "../dbfile"
import "../values"
import "../vm"
import "core:strings"

// property_defined_at_or_below ports the property.odin-adjacent check of the same name in
// db_properties.c: true iff `oid` or any descendant of `oid` already defines a property
// named `name` (case-insensitively) directly on itself. Used by add_property (a new propdef
// can't shadow one a descendant already defines) and chparent (reparenting can't introduce a
// name collision between the new ancestor chain and the moved subtree).
property_defined_at_or_below :: proc(db: ^dbfile.Database, name: string, oid: values.Objid) -> bool {
	obj, ok := db.objects[oid]
	if !ok {
		return false
	}
	for pd in obj.propdefs {
		if strings.equal_fold(pd.name, name) {
			return true
		}
	}
	for c := obj.child; c != values.NOTHING; {
		child, cok := db.objects[c]
		if !cok {
			break
		}
		if property_defined_at_or_below(db, name, c) {
			return true
		}
		c = child.sibling
	}
	return false
}

// db_change_parent_links ports db_change_parent's LL_REMOVE/LL_APPEND splice of the
// parent/child/sibling chain (the inheritance-hierarchy counterpart to db_change_location's
// location/contents/next splice already used by move() -- see object_builtins.odin's
// db_change_location).
@(private = "file")
db_change_parent_links :: proc(db: ^dbfile.Database, oid, new_parent: values.Objid) {
	old_parent := db.objects[oid].parent
	if valid(db, old_parent) {
		p := db.objects[old_parent]
		o := db.objects[oid]
		if p.child == oid {
			p.child = o.sibling
		} else {
			lid := p.child
			for lid != values.NOTHING {
				lo := db.objects[lid]
				if lo.sibling == oid {
					lo.sibling = o.sibling
					break
				}
				lid = lo.sibling
			}
		}
		o.sibling = values.NOTHING
	}
	if valid(db, new_parent) {
		p := db.objects[new_parent]
		o := db.objects[oid]
		if p.child == values.NOTHING {
			p.child = oid
		} else {
			lid := p.child
			for db.objects[lid].sibling != values.NOTHING {
				lid = db.objects[lid].sibling
			}
			db.objects[lid].sibling = oid
		}
		o.sibling = values.NOTHING
	}
	db.objects[oid].parent = new_parent
}

@(private = "file")
next_new_objid :: proc(db: ^dbfile.Database) -> values.Objid {
	db.max_oid += 1
	return db.max_oid
}

// bf_create ports objects.c's bf_create(): a fresh object parented under `parent` (or
// NOTHING), owned by `owner` (defaults to the caller). Permission: creating under a real
// parent needs FLAG_FERTILE there (own/wizard/flag-set); owning as someone else needs
// wizard. Quota is charged to the owner (decr_quota, already implemented for property.odin's
// callers). Calls the new object's own `initialize()` verb if it defines one, best-effort
// (VERBNF is fine, MAXREC propagates).
bf_create :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	n := values.list_len(args)
	if n < 1 || n > 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	parent_v := values.list_get(args, 1)
	if parent_v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	parent := parent_v.data.obj
	progr := ctx.activation.programmer
	owner := progr
	if n == 2 {
		owner_v := values.list_get(args, 2)
		if owner_v.type != .Obj {
			return err_result_local(.E_TYPE, "Type mismatch")
		}
		owner = owner_v.data.obj
	}

	parent_ok := valid(w.db, parent) ? object_allows(w.db, parent, progr, .Fertile) : parent == values.NOTHING
	if !parent_ok || (owner != progr && !is_wizard(w.db, progr)) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	if valid(w.db, owner) && !decr_quota(w.db, owner) {
		return err_result_local(.E_QUOTA, "Quota exceeded")
	}

	oid := next_new_objid(w.db)
	obj := new(dbfile.Object)
	obj.id = oid
	obj.name = dbfile.intern_name(&w.db.name_intern, "")
	obj.owner = owner == values.NOTHING ? oid : owner
	obj.location = values.NOTHING
	obj.contents = values.NOTHING
	obj.next = values.NOTHING
	obj.parent = values.NOTHING
	obj.child = values.NOTHING
	obj.sibling = values.NOTHING
	w.db.objects[oid] = obj

	// The snapshot is empty here (a brand new object has no propvals yet), but going through
	// the same two-phase path as every other caller keeps the contract uniform -- see
	// prop_resync.odin's usage note.
	snap := prop_layout_snapshot(w.db, oid)
	defer prop_layout_snapshot_destroy(&snap)
	db_change_parent_links(w.db, oid, parent)
	resync_subtree_propvals(w.db, oid, obj.owner, &snap)

	init_args := values.list_val(make([]values.Var, 0))
	result := call_verb_from(w, ctx.world, oid, oid, "initialize", init_args, ctx, via_builtin = "create")
	if result.raised {
		// A raise from the :initialize body unwinds through create()'s caller (in the
		// original it never returns to bf_create -- the squelch path discards the
		// continuation, objects.c:286-290), as does a dispatch E_MAXREC (objects.c:279).
		// The object stays created and the quota stays spent in both servers; the caller
		// just never learns the oid. Only a MISSING :initialize (E_VERBNF) falls through
		// to return the new object normally (objects.c:281).
		if result.unwinding || result.code == .E_MAXREC {
			return result
		}
		delete(result.msg)
		values.free_var(result.rvalue)
	} else {
		values.free_var(result.value)
	}
	return ok_result(values.obj_val(oid))
}

// bf_recycle ports objects.c's bf_recycle(): best-effort `:recycle()` notification, then
// evict every content item and the object itself to NOTHING (via move(), so :exitfunc/
// :enterfunc still fire normally), flatten the inheritance hierarchy (reparent every child
// to this object's own parent, matching a `rmverb`-style "don't orphan the subtree"), refund
// quota to the owner, and finally drop the object from the DB entirely. The freed object
// number is never reused (matches db_create_object always appending, never reusing a hole).
bf_recycle :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	oid := v.data.obj
	progr := ctx.activation.programmer
	if !valid(w.db, oid) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	if !controls(w, progr, oid) {
		return err_result_local(.E_PERM, "Permission denied")
	}

	// The :recycle() notification's error handling is the most lenient of the
	// builtin-dispatched verb calls: BOTH dispatch failures -- E_VERBNF (no such verb) and
	// even E_MAXREC -- fall through and the destruction proceeds ("e == E_VERBNF or
	// E_MAXREC; fall through", objects.c:458). A raise from the verb BODY doesn't stop the
	// destruction either: the raise unwinds, and unwind_stack's squelch loop
	// (execute.c:337-358) keeps re-invoking bf_recycle's continuation while discarding
	// every verb call it attempts -- so the demolition completes with the
	// :exitfunc/:enterfunc eviction notifications suppressed, and THEN the original raise
	// continues into recycle()'s caller. `pending`/`squelch` reproduce exactly that.
	pending: vm.Call_Result
	squelch := false
	recycle_args := values.list_val(make([]values.Var, 0))
	rresult := call_verb_from(w, ctx.world, oid, oid, "recycle", recycle_args, ctx, via_builtin = "recycle")
	if rresult.raised {
		if rresult.unwinding {
			pending = rresult
			squelch = true
		} else {
			delete(rresult.msg)
			values.free_var(rresult.rvalue)
		}
	} else {
		values.free_var(rresult.value)
	}
	if !valid(w.db, oid) {
		// The :recycle() verb (or something it called) already destroyed this object.
		if squelch {
			return pending
		}
		return ok_result(values.int_val(0))
	}

	// Evict every content item, then the object itself, to NOTHING. Normally via move() so
	// :exitfunc/:enterfunc fire; in squelch mode via the bare DB-level location change, the
	// verb calls having been discarded by the unwind (see above).
	for valid(w.db, oid) && w.db.objects[oid].contents != values.NOTHING {
		c := w.db.objects[oid].contents
		if squelch {
			db_change_location(w, c, values.NOTHING)
			continue
		}
		mv_items := make([]values.Var, 2)
		mv_items[0] = values.obj_val(c)
		mv_items[1] = values.obj_val(values.NOTHING)
		mresult := bf_move(w, values.list_val(mv_items), ctx)
		if mresult.raised {
			delete(mresult.msg)
			values.free_var(mresult.rvalue)
			break // avoid looping forever if a stuck item refuses to move
		}
		values.free_var(mresult.value)
	}
	if valid(w.db, oid) && w.db.objects[oid].location != values.NOTHING {
		if squelch {
			db_change_location(w, oid, values.NOTHING)
		} else {
			mv_items := make([]values.Var, 2)
			mv_items[0] = values.obj_val(oid)
			mv_items[1] = values.obj_val(values.NOTHING)
			mresult := bf_move(w, values.list_val(mv_items), ctx)
			if mresult.raised {
				delete(mresult.msg)
				values.free_var(mresult.rvalue)
			} else {
				values.free_var(mresult.value)
			}
		}
	}
	if !valid(w.db, oid) {
		if squelch {
			return pending
		}
		return ok_result(values.int_val(0))
	}

	// Flatten the inheritance hierarchy: every child gets reparented to this object's own
	// parent rather than being left with a dangling/invalid parent. Each child loses whatever
	// properties THIS object defined, so their propvals need realigning -- snapshot the whole
	// subtree's layouts up front, before any reparenting (see prop_resync.odin's usage note);
	// reparenting one child doesn't disturb its siblings' layouts, so one snapshot covers the
	// entire loop.
	snap := prop_layout_snapshot(w.db, oid)
	defer prop_layout_snapshot_destroy(&snap)
	own_parent := w.db.objects[oid].parent
	for w.db.objects[oid].child != values.NOTHING {
		c := w.db.objects[oid].child
		db_change_parent_links(w.db, c, own_parent)
		resync_subtree_propvals(w.db, c, w.db.objects[c].owner, &snap)
	}
	db_change_parent_links(w.db, oid, values.NOTHING)

	owner := w.db.objects[oid].owner
	incr_quota(w.db, owner)
	destroy_object(w.db, oid)
	compile_cache_invalidate_object(&w.cache, oid)
	if squelch {
		// Demolition complete; NOW the :recycle body's raise continues into the caller.
		return pending
	}
	return ok_result(values.int_val(0))
}

// destroy_object frees an object's own storage (propvals/propdefs/verbdefs) and drops it
// from the DB map, ports db_destroy_object() (called only once the object is already a
// barren orphan -- no location, no contents, no parent, no children, matching that
// function's own precondition panic).
@(private = "file")
destroy_object :: proc(db: ^dbfile.Database, oid: values.Objid) {
	obj, ok := db.objects[oid]
	if !ok {
		return
	}
	for pv in obj.propvals {
		values.free_var(pv.value)
	}
	delete(obj.propvals)
	delete(obj.propdefs)
	for vd in obj.verbdefs {
		delete(vd.program_source)
	}
	delete(obj.verbdefs)
	delete_key(&db.objects, oid)
	free(obj)
}

// bf_chparent ports objects.c's bf_chparent(): validity/permission (controls the object,
// and the new parent grants FERTILE), a cycle check (E_RECMOVE), and a property name
// collision check (E_INVARG if the new ancestor chain and the moved subtree would end up
// defining the same property name twice) before actually relinking and resyncing propvals.
bf_chparent :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	what_v, parent_v := values.list_get(args, 1), values.list_get(args, 2)
	if what_v.type != .Obj || parent_v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	what, new_parent := what_v.data.obj, parent_v.data.obj
	progr := ctx.activation.programmer

	if !valid(w.db, what) || (!valid(w.db, new_parent) && new_parent != values.NOTHING) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	if !controls(w, progr, what) || (valid(w.db, new_parent) && !object_allows(w.db, new_parent, progr, .Fertile)) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	for oid := new_parent; oid != values.NOTHING; oid = w.db.objects[oid].parent {
		if oid == what {
			return err_result_local(.E_RECMOVE, "Recursive move")
		}
	}
	for anc := new_parent; anc != values.NOTHING; anc = w.db.objects[anc].parent {
		for pd in w.db.objects[anc].propdefs {
			if property_defined_at_or_below(w.db, pd.name, what) {
				return err_result_local(.E_INVARG, "Duplicate property name")
			}
		}
	}

	// Snapshot BEFORE reparenting -- `what`'s accumulated layout is about to become a
	// completely different splice of ancestors, so every slot in its (and its descendants')
	// propvals needs re-pairing by property identity. See prop_resync.odin's usage note.
	snap := prop_layout_snapshot(w.db, what)
	defer prop_layout_snapshot_destroy(&snap)
	db_change_parent_links(w.db, what, new_parent)
	resync_subtree_propvals(w.db, what, w.db.objects[what].owner, &snap)
	return ok_result(values.int_val(0))
}

// bf_renumber ports server.c's bf_renumber(): moves `oid` to the lowest currently-unused
// object number below it (if any), fixing up every link that mentions its old number
// (parent's child chain, every child's parent, location's contents chain, every content
// item's location) -- a no-op returning `oid` unchanged if no lower slot is free. Wizard-only
// (matches the original exactly -- this is a database-maintenance tool, not ordinary
// gameplay).
bf_renumber :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	old := v.data.obj
	if !valid(w.db, old) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	if !is_wizard(w.db, ctx.activation.programmer) {
		return err_result_local(.E_PERM, "Permission denied")
	}

	new_id := values.Objid(-1)
	for cand := values.Objid(0); cand < old; cand += 1 {
		if !valid(w.db, cand) {
			new_id = cand
			break
		}
	}
	if new_id < 0 {
		return ok_result(values.obj_val(old)) // no free slot below `old` -- unchanged
	}

	// Both ids need their compiled-verb cache entries dropped: `old`'s own (they're keyed
	// by an object id that's about to mean something else, if anything), and `new_id`'s
	// (a stale leftover from whatever previously occupied that slot before being recycled).
	compile_cache_invalidate_object(&w.cache, old)
	compile_cache_invalidate_object(&w.cache, new_id)

	obj := w.db.objects[old]
	delete_key(&w.db.objects, old)
	obj.id = new_id
	w.db.objects[new_id] = obj

	if valid(w.db, obj.parent) {
		p := w.db.objects[obj.parent]
		if p.child == old {
			p.child = new_id
		} else {
			for lid := p.child; lid != values.NOTHING; lid = w.db.objects[lid].sibling {
				if w.db.objects[lid].sibling == old {
					w.db.objects[lid].sibling = new_id
					break
				}
			}
		}
	}
	for c := obj.child; c != values.NOTHING; c = w.db.objects[c].sibling {
		w.db.objects[c].parent = new_id
	}
	if valid(w.db, obj.location) {
		l := w.db.objects[obj.location]
		if l.contents == old {
			l.contents = new_id
		} else {
			for lid := l.contents; lid != values.NOTHING; lid = w.db.objects[lid].next {
				if w.db.objects[lid].next == old {
					w.db.objects[lid].next = new_id
					break
				}
			}
		}
	}
	for c := obj.contents; c != values.NOTHING; c = w.db.objects[c].next {
		w.db.objects[c].location = new_id
	}

	return ok_result(values.obj_val(new_id))
}

// bf_reset_max_object ports server.c's bf_reset_max_object(): reclaims trailing recycled
// object numbers so the next create() reuses them instead of always growing -- wizard-only.
bf_reset_max_object :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 0 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	if !is_wizard(w.db, ctx.activation.programmer) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	for w.db.max_oid >= 0 && !valid(w.db, w.db.max_oid) {
		w.db.max_oid -= 1
	}
	return ok_result(values.int_val(0))
}

// bf_max_object ports server.c's bf_max_object(): the highest object number ever assigned
// (may currently be recycled -- reset_max_object() is what reclaims trailing holes).
bf_max_object :: proc(w: ^Object_World, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 0 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	return ok_result(values.obj_val(w.db.max_oid))
}
