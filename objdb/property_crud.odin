package objdb

// Property definition/introspection built-ins, ported from property.c: properties(),
// property_info(), set_property_info(), add_property(), delete_property(),
// clear_property(). (is_clear_property() already existed in object_builtins.odin.)

import "../dbfile"
import "../values"
import "../vm"
import "core:strings"

// bf_properties ports property.c's bf_properties(): the names of the propdefs `oid` defines
// directly on itself (not inherited ones).
bf_properties :: proc(w: ^Object_World, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	obj, ok := w.db.objects[v.data.obj]
	if !ok {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	items := make([]values.Var, len(obj.propdefs))
	for pd, i in obj.propdefs {
		items[i] = values.str_val(strings.clone(pd.name))
	}
	return ok_result(values.list_val(items))
}

// bf_property_info ports property.c's bf_prop_info(): {owner, perms-letters} for a
// (non-built-in) property findable from `oid`.
bf_property_info :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, name_v := values.list_get(args, 1), values.list_get(args, 2)
	if obj_v.type != .Obj || name_v.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	if !valid(w.db, obj_v.data.obj) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	h := find_property(w.db, obj_v.data.obj, name_v.data.str.s)
	if !h.found || h.builtin != .None {
		return err_result_local(.E_PROPNF, "Property not found")
	}
	if !prop_allows(w.db, h.value_perms, h.value_owner, ctx.activation.programmer, .Read) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	perms := strings.builder_make()
	if (h.value_perms & (1 << uint(Prop_Flag.Read))) != 0 {
		strings.write_byte(&perms, 'r')
	}
	if (h.value_perms & (1 << uint(Prop_Flag.Write))) != 0 {
		strings.write_byte(&perms, 'w')
	}
	if (h.value_perms & (1 << uint(Prop_Flag.Chown))) != 0 {
		strings.write_byte(&perms, 'c')
	}
	items := make([]values.Var, 2)
	items[0] = values.obj_val(h.value_owner)
	items[1] = values.str_val(strings.to_string(perms))
	return ok_result(values.list_val(items))
}

// validate_prop_info parses the {owner, perms-string [, new-name]} argument
// set_property_info/add_property both take, ports property.c's validate_prop_info().
@(private = "file")
validate_prop_info :: proc(w: ^Object_World, info: values.Var) -> (owner: values.Objid, flags: int, new_name: string, has_new_name: bool, err: values.Error) {
	if info.type != .List {
		return 0, 0, "", false, .E_TYPE
	}
	n := values.list_len(info)
	if n != 2 && n != 3 {
		return 0, 0, "", false, .E_TYPE
	}
	owner_v := values.list_get(info, 1)
	perms_v := values.list_get(info, 2)
	if owner_v.type != .Obj || perms_v.type != .Str {
		return 0, 0, "", false, .E_TYPE
	}
	if n == 3 && values.list_get(info, 3).type != .Str {
		return 0, 0, "", false, .E_TYPE
	}
	if !valid(w.db, owner_v.data.obj) {
		return 0, 0, "", false, .E_INVARG
	}
	for c in perms_v.data.str.s {
		switch c {
		case 'r', 'R':
			flags |= 1 << uint(Prop_Flag.Read)
		case 'w', 'W':
			flags |= 1 << uint(Prop_Flag.Write)
		case 'c', 'C':
			flags |= 1 << uint(Prop_Flag.Chown)
		case:
			return 0, 0, "", false, .E_INVARG
		}
	}
	owner = owner_v.data.obj
	if n == 3 {
		new_name = values.list_get(info, 3).data.str.s
		has_new_name = true
	}
	return owner, flags, new_name, has_new_name, .E_NONE
}

// bf_set_property_info ports property.c's bf_set_prop_info()/set_prop_info(): reassign a
// property's owner/perms, and optionally rename its propdef (only meaningful when called on
// the object that actually DEFINES the property -- matches the original's own behavior of
// searching for the old name only in `oid`'s own propdefs, not the whole ancestor chain, a
// real limitation of the original this port preserves rather than "improves").
bf_set_property_info :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 3 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, name_v, info_v := values.list_get(args, 1), values.list_get(args, 2), values.list_get(args, 3)
	if obj_v.type != .Obj || name_v.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	oid := obj_v.data.obj
	if !valid(w.db, oid) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	new_owner, new_flags, new_name, has_new_name, verr := validate_prop_info(w, info_v)
	if verr != .E_NONE {
		return err_result_local(verr, "Invalid property info")
	}

	h := find_property(w.db, oid, name_v.data.str.s)
	if !h.found || h.builtin != .None {
		return err_result_local(.E_PROPNF, "Property not found")
	}
	progr := ctx.activation.programmer
	if !prop_allows(w.db, h.value_perms, h.value_owner, progr, .Write) ||
	   (!is_wizard(w.db, progr) && h.value_owner != new_owner) {
		return err_result_local(.E_PERM, "Permission denied")
	}

	if has_new_name {
		obj := w.db.objects[oid]
		found_idx := -1
		for pd, i in obj.propdefs {
			if strings.equal_fold(pd.name, name_v.data.str.s) {
				found_idx = i
				break
			}
		}
		if found_idx < 0 {
			return err_result_local(.E_INVARG, "Property not defined here")
		}
		if !strings.equal_fold(name_v.data.str.s, new_name) {
			collide := find_property(w.db, oid, new_name)
			if collide.found || property_defined_at_or_below(w.db, new_name, oid) {
				return err_result_local(.E_INVARG, "Duplicate property name")
			}
		}
		obj.propdefs[found_idx].name = intern_local(w, new_name)
		h = find_property(w.db, oid, new_name)
	}

	obj := w.db.objects[oid]
	obj.propvals[h.value_index].owner = new_owner
	obj.propvals[h.value_index].perms = new_flags
	return ok_result(values.int_val(0))
}

@(private = "file")
intern_local :: proc(w: ^Object_World, s: string) -> string {
	return dbfile.intern_name(&w.db.name_intern, s)
}

// bf_add_property ports property.c's bf_add_prop(): defines a new property on `oid` with an
// initial value and {owner, perms}. Requires write access to `oid` itself, and the new
// owner must be the caller or the caller must be a wizard. Every descendant's propvals gets
// resynced to pick up the new (initially CLEAR) inherited slot -- except `oid` itself, whose
// own new slot holds the given initial value directly.
bf_add_property :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 4 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, name_v, value_v, info_v := values.list_get(args, 1), values.list_get(args, 2), values.list_get(args, 3), values.list_get(args, 4)
	if obj_v.type != .Obj || name_v.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	owner, flags, new_name, has_new_name, verr := validate_prop_info(w, info_v)
	if verr != .E_NONE {
		return err_result_local(verr, "Invalid property info")
	}
	if has_new_name {
		return err_result_local(.E_TYPE, "Unexpected rename in add_property's info")
	}
	oid := obj_v.data.obj
	if !valid(w.db, oid) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	progr := ctx.activation.programmer
	if !object_allows(w.db, oid, progr, .Write) || (progr != owner && !is_wizard(w.db, progr)) {
		return err_result_local(.E_PERM, "Permission denied")
	}

	name := name_v.data.str.s
	if find_property(w.db, oid, name).found || property_defined_at_or_below(w.db, name, oid) {
		return err_result_local(.E_INVARG, "Duplicate property name")
	}

	obj := w.db.objects[oid]
	append(&obj.propdefs, dbfile.Propdef{name = intern_local(w, name)})
	append(&obj.propvals, dbfile.Propval{value = values.var_ref(value_v), owner = owner, perms = flags})

	// Every descendant needs the new inherited (CLEAR) slot; `oid` itself already has its
	// real value appended above, so only resync the CHILDREN, not oid itself (a full
	// resync_subtree_propvals(w.db, oid, ...) would work too, but would rebuild -- and thus
	// needlessly re-snapshot/reallocate -- oid's own array that's already correct).
	for c := obj.child; c != values.NOTHING; {
		child, cok := w.db.objects[c]
		if !cok {
			break
		}
		next := child.sibling
		resync_subtree_propvals(w.db, c, owner)
		c = next
	}
	return ok_result(values.int_val(0))
}

// bf_delete_property ports property.c's bf_delete_prop(): removes a propdef DEFINED
// DIRECTLY on `oid` (not an inherited one -- matches db_delete_propdef's own-list-only
// search) and resyncs `oid` and every descendant's propvals to match.
bf_delete_property :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, name_v := values.list_get(args, 1), values.list_get(args, 2)
	if obj_v.type != .Obj || name_v.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	oid := obj_v.data.obj
	if !valid(w.db, oid) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	if !object_allows(w.db, oid, ctx.activation.programmer, .Write) {
		return err_result_local(.E_PERM, "Permission denied")
	}

	obj := w.db.objects[oid]
	found_idx := -1
	for pd, i in obj.propdefs {
		if strings.equal_fold(pd.name, name_v.data.str.s) {
			found_idx = i
			break
		}
	}
	if found_idx < 0 {
		return err_result_local(.E_PROPNF, "Property not found")
	}
	ordered_remove(&obj.propdefs, found_idx)
	resync_subtree_propvals(w.db, oid, obj.owner)
	return ok_result(values.int_val(0))
}

@(private = "file")
ordered_remove :: proc(s: ^[dynamic]dbfile.Propdef, i: int) {
	copy(s[i:], s[i + 1:])
	resize(s, len(s) - 1)
}

// bf_clear_property ports property.c's bf_clear_prop(): resets an INHERITED property
// override back to CLEAR (E_INVARG if `oid` is the property's own definer -- there's no
// ancestor value to fall back to in that case, matches the original exactly).
bf_clear_property :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, name_v := values.list_get(args, 1), values.list_get(args, 2)
	if obj_v.type != .Obj || name_v.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	oid := obj_v.data.obj
	if !valid(w.db, oid) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	h := find_property(w.db, oid, name_v.data.str.s)
	if !h.found {
		return err_result_local(.E_PROPNF, "Property not found")
	}
	progr := ctx.activation.programmer
	if h.builtin != .None || (progr != h.value_owner && !is_wizard(w.db, progr)) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	if h.definer == oid {
		return err_result_local(.E_INVARG, "Property defined here, nothing to clear to")
	}
	obj := w.db.objects[oid]
	values.free_var(obj.propvals[h.value_index].value)
	obj.propvals[h.value_index].value = values.clear_val()
	return ok_result(values.int_val(0))
}

