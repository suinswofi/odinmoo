package objdb

// Property lookup, ported from db_properties.c's db_find_property(). Two things make this
// more than a simple name lookup:
//
// 1. Nine built-in pseudo-properties (name, owner, programmer, wizard, r, w, f, location,
//    contents) are checked first, computed on the fly rather than stored -- `.name` works
//    on every object even though "name" never appears in any propdef list.
//
// 2. For a real (non-built-in) property, every object in the hierarchy carries its OWN
//    value slot for every property defined anywhere in its ancestor chain (that's what
//    dbfile's Object.propvals already holds, exactly matching the .db file's own layout --
//    see db_file.c's read_object). The index into that slice is accumulated SELF-first,
//    root-last: db_find_property's search walks from oid toward the root summing each
//    level's own propdef count as it goes, so oid's own propdefs occupy the first slots,
//    its parent's own propdefs the next, and so on -- not the more intuitive-sounding
//    root-to-self order. A slot can hold TYPE_CLEAR, meaning "no override here, inherit
//    whatever the nearest ancestor with a real value has" -- found by walking toward the
//    root, shortening the accumulated index by each ancestor's own propdef count as you go
//    (mirrors the original's `n -= o->propdefs.cur_length` pointer-arithmetic trick, just
//    expressed as slice indexing instead of raw pointer walking).

import "../dbfile"
import "../values"
import "core:strings"

Builtin_Prop :: enum {
	None,
	Name,
	Owner,
	Programmer,
	Wizard,
	R,
	W,
	F,
	Location,
	Contents,
}

@(private = "file")
builtin_prop_names := [Builtin_Prop]string {
	.None       = "",
	.Name       = "name",
	.Owner      = "owner",
	.Programmer = "programmer",
	.Wizard     = "wizard",
	.R          = "r",
	.W          = "w",
	.F          = "f",
	.Location   = "location",
	.Contents   = "contents",
}

find_builtin_prop :: proc(name: string) -> Builtin_Prop {
	for bp in Builtin_Prop {
		if bp != .None && strings.equal_fold(builtin_prop_names[bp], name) {
			return bp
		}
	}
	return .None
}

// get_builtin_prop_value computes a built-in pseudo-property's value. Contents allocates a
// fresh list (owned by the caller); everything else is a cheap scalar.
get_builtin_prop_value :: proc(db: ^dbfile.Database, oid: values.Objid, bp: Builtin_Prop) -> values.Var {
	obj := db.objects[oid]
	switch bp {
	case .None:
		return values.none_val()
	case .Name:
		return values.str_val(strings.clone(obj.name))
	case .Owner:
		return values.obj_val(obj.owner)
	case .Programmer:
		return values.int_val(is_programmer(db, oid) ? 1 : 0)
	case .Wizard:
		return values.int_val(is_wizard(db, oid) ? 1 : 0)
	case .R:
		return values.int_val(object_has_flag(db, oid, .Read) ? 1 : 0)
	case .W:
		return values.int_val(object_has_flag(db, oid, .Write) ? 1 : 0)
	case .F:
		return values.int_val(object_has_flag(db, oid, .Fertile) ? 1 : 0)
	case .Location:
		return values.obj_val(obj.location)
	case .Contents:
		return list_contents(db, oid)
	}
	return values.none_val()
}

// list_contents walks the `next`-linked contents chain (ports db_for_all_contents's use in
// GET_BI_VALUE's BP_CONTENTS case).
list_contents :: proc(db: ^dbfile.Database, oid: values.Objid) -> values.Var {
	items: [dynamic]values.Var
	obj := db.objects[oid]
	c := obj.contents
	for c != values.NOTHING {
		append(&items, values.obj_val(c))
		child, ok := db.objects[c]
		if !ok {
			break
		}
		c = child.next
	}
	return values.list_val(items[:])
}

Prop_Handle :: struct {
	builtin:      Builtin_Prop, // != .None for a built-in pseudo-property
	definer:      values.Objid, // the ancestor whose propdef list contains this property
	value_owner:  values.Objid,
	value_perms:  int,
	value_index:  int, // index into the STARTING object's propvals slice
	found:        bool,
}

// find_property ports db_find_property(): built-ins first, then a name search walking from
// oid toward the root, matching against each ancestor's OWN propdef list while accumulating
// a running index into the starting object's (oid's) propvals slice.
find_property :: proc(db: ^dbfile.Database, oid: values.Objid, name: string) -> Prop_Handle {
	if bp := find_builtin_prop(name); bp != .None {
		return Prop_Handle{builtin = bp, found = true}
	}

	n := 0
	cur := oid
	for {
		obj, ok := db.objects[cur]
		if !ok {
			break
		}
		for pd in obj.propdefs {
			if strings.equal_fold(pd.name, name) {
				start_obj := db.objects[oid]
				pv := start_obj.propvals[n]
				return Prop_Handle{definer = cur, value_owner = pv.owner, value_perms = pv.perms, value_index = n, found = true}
			}
			n += 1
		}
		if obj.parent == values.NOTHING {
			break
		}
		cur = obj.parent
	}
	return Prop_Handle{}
}

// property_value resolves a Prop_Handle to its actual Var, skipping TYPE_CLEAR slots by
// walking toward the root (ports the `while (prop->var.type == TYPE_CLEAR) ...` loop in
// db_find_property). Always returns an OWNED value the caller must eventually free: for a
// built-in pseudo-property this is already a fresh allocation (get_builtin_prop_value's own
// contract) returned as-is; for a regular stored property it's the DB's own value with an
// extra var_ref taken before returning, so callers never need to special-case which kind of
// property they asked for. (A previous version returned a mix of "fresh, already owned" and
// "borrowed, take your own ref if you want to keep it" depending on which branch ran, and
// world_get_prop's uniform `var_ref(property_value(...))` wrapper double-counted the
// already-owned builtin case -- a real, quiet leak on every `.name`/`.contents` read, since
// that extra ref is never dropped by anything. Fixed by making this function's own contract
// uniform instead of leaving it to (and getting it wrong at) the call site.)
property_value :: proc(db: ^dbfile.Database, oid: values.Objid, h: Prop_Handle) -> values.Var {
	if h.builtin != .None {
		return get_builtin_prop_value(db, oid, h.builtin)
	}
	o := oid
	n := h.value_index
	for {
		// A well-formed DB always terminates this walk: the property's definer holds a
		// non-CLEAR value (add_property sets one, and clear_property refuses to clear a
		// definer's own slot), so we stop at or before it. The bounds checks below only
		// matter for a corrupt or hand-edited .db, where without them a CLEAR-all-the-way
		// chain would walk off the root and nil-deref -- a segfault in a live server. Falling
		// back to 0 (the same value an unset property reads as) keeps that recoverable.
		obj, ok := db.objects[o]
		if !ok || n < 0 || n >= len(obj.propvals) {
			return values.int_val(0)
		}
		pv := obj.propvals[n]
		if pv.value.type != .Clear {
			return values.var_ref(pv.value)
		}
		n -= len(obj.propdefs)
		o = obj.parent
	}
}

// set_property_value ports db_set_property_value(): most built-in pseudo-properties are
// read-only (computed, not stored -- see get_builtin_prop_value), but name/owner/
// programmer/wizard/r/w/f are genuinely settable, each writing back to the actual Object
// field or flag bit it's a view onto. Wrong-typed values for the settable ones are silently
// ignored (matches the original's `goto complain` -> discard-and-return, not an error).
set_property_value :: proc(db: ^dbfile.Database, oid: values.Objid, h: Prop_Handle, v: values.Var) {
	if h.builtin != .None {
		obj, ok := db.objects[oid]
		if !ok {
			values.free_var(v)
			return
		}
		#partial switch h.builtin {
		case .Name:
			// Every obj.name is owned by the shared name-intern table (Phase 1), not
			// per-object -- route a rename through the same table (dedupes against
			// any existing identical name too) rather than giving this one object an
			// independently-owned string the table doesn't know to free later.
			if v.type == .Str {
				obj.name = dbfile.intern_name(&db.name_intern, v.data.str.s)
			}
			values.free_var(v)
		case .Owner:
			if v.type == .Obj {
				obj.owner = v.data.obj
			}
			values.free_var(v)
		case .Programmer:
			set_or_clear_flag(obj, .Programmer, values.is_true(v))
			values.free_var(v)
		case .Wizard:
			set_or_clear_flag(obj, .Wizard, values.is_true(v))
			values.free_var(v)
		case .R:
			set_or_clear_flag(obj, .Read, values.is_true(v))
			values.free_var(v)
		case .W:
			set_or_clear_flag(obj, .Write, values.is_true(v))
			values.free_var(v)
		case .F:
			set_or_clear_flag(obj, .Fertile, values.is_true(v))
			values.free_var(v)
		case:
			// Location/contents (change hierarchy, not a plain assignment -- that's
			// move(), a Phase 5 builtin this port doesn't have yet) stay read-only.
			values.free_var(v)
		}
		return
	}
	obj := db.objects[oid]
	values.free_var(obj.propvals[h.value_index].value)
	obj.propvals[h.value_index].value = v
}

@(private = "file")
set_or_clear_flag :: proc(obj: ^dbfile.Object, flag: Object_Flag, on: bool) {
	bit := 1 << uint(flag)
	if on {
		obj.flags |= bit
	} else {
		obj.flags &= ~bit
	}
}
