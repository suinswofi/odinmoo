package objdb

// Object-creation quota, ported from quota.c. It's just an ordinary property named
// "ownership_quota" on the prospective owner -- no separate quota subsystem exists. Missing
// or non-integer quota properties mean "unlimited" (decr_quota still succeeds), matching
// the original's `if (!h.ptr) return 1;` / `if (v.type != TYPE_INT) return 1;`.

import "../dbfile"
import "../values"

decr_quota :: proc(db: ^dbfile.Database, player: values.Objid) -> bool {
	if !valid(db, player) {
		return true
	}
	h := find_property(db, player, "ownership_quota")
	if !h.found || h.builtin != .None {
		return true
	}
	v := property_value(db, player, h)
	defer values.free_var(v)
	if v.type != .Int {
		return true
	}
	if v.data.num <= 0 {
		return false
	}
	set_property_value(db, player, h, values.int_val(v.data.num - 1))
	return true
}

incr_quota :: proc(db: ^dbfile.Database, player: values.Objid) {
	if !valid(db, player) {
		return
	}
	h := find_property(db, player, "ownership_quota")
	if !h.found || h.builtin != .None {
		return
	}
	v := property_value(db, player, h)
	defer values.free_var(v)
	if v.type != .Int {
		return
	}
	set_property_value(db, player, h, values.int_val(v.data.num + 1))
}
