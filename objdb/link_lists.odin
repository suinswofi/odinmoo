package objdb

// The two singly-linked lists threaded through objects -- a parent's children
// (child -> sibling -> sibling ...) and a location's contents (contents -> next -> next ...) --
// and the splices that maintain them, ported from db_objects.c's LL_REMOVE/LL_APPEND.
//
// Upstream both operations walk the list: appending finds the tail, removing finds the
// predecessor. Here each step of that walk is also a db.objects hash lookup, so the cost per
// call was about 30ns per sibling -- 1.2ms per create() under a parent with 40000 children, and
// a loop of 30000 create()s after 10000 existing ones took 15.5 seconds, all inside built-ins
// holding big_lock. move() into a crowded room and recycle() of an object with many children
// paid the same way.
//
// Both walks are now O(1) through HINTS kept on dbfile.Object (last_child/last_content on the
// list's owner, prev_sibling/prev_content on each member). A hint is never trusted: it is used
// only when an O(1) look at the real links proves it right -- the claimed tail is in the list
// and has no successor; the claimed predecessor is in the list and points at the object being
// removed -- and otherwise the walk runs exactly as before. That is what lets the hints be
// in-memory only, start out as garbage (a freshly loaded database, a test that links objects by
// hand, the zero value), and go stale under renumber(), without any of it being a correctness
// question. "In the list" is read off the member's own parent/location field, which a
// well-formed database keeps in agreement with the list it is threaded into.
//
// List ORDER is MOO-visible (children(), .contents) and unchanged: appends still go at the end.

import "../dbfile"
import "../values"

Chain :: enum {
	Children, // owner.child, member.sibling, member.parent
	Contents, // owner.contents, member.next, member.location
}

@(private = "file")
head_ptr :: proc(o: ^dbfile.Object, c: Chain) -> ^values.Objid {
	return c == .Children ? &o.child : &o.contents
}

@(private = "file")
next_ptr :: proc(o: ^dbfile.Object, c: Chain) -> ^values.Objid {
	return c == .Children ? &o.sibling : &o.next
}

@(private = "file")
owner_of :: proc(o: ^dbfile.Object, c: Chain) -> values.Objid {
	return c == .Children ? o.parent : o.location
}

@(private = "file")
tail_hint :: proc(o: ^dbfile.Object, c: Chain) -> ^values.Objid {
	return c == .Children ? &o.last_child : &o.last_content
}

@(private = "file")
prev_hint :: proc(o: ^dbfile.Object, c: Chain) -> ^values.Objid {
	return c == .Children ? &o.prev_sibling : &o.prev_content
}

// chain_unlink removes `oid` from `owner`'s list. `oid` must be in it.
chain_unlink :: proc(db: ^dbfile.Database, c: Chain, owner, oid: values.Objid) {
	ow := db.objects[owner]
	o := db.objects[oid]
	succ := next_ptr(o, c)^
	pred := values.NOTHING
	if head_ptr(ow, c)^ == oid {
		head_ptr(ow, c)^ = succ
	} else {
		h := prev_hint(o, c)^
		if ho, ok := db.objects[h]; ok && h != oid && owner_of(ho, c) == owner && next_ptr(ho, c)^ == oid {
			pred = h
		} else {
			for lid := head_ptr(ow, c)^; lid != values.NOTHING; {
				lo := db.objects[lid]
				if next_ptr(lo, c)^ == oid {
					pred = lid
					break
				}
				lid = next_ptr(lo, c)^
			}
		}
		if pred != values.NOTHING {
			next_ptr(db.objects[pred], c)^ = succ
		}
	}
	if so, ok := db.objects[succ]; ok && succ != values.NOTHING {
		prev_hint(so, c)^ = pred
	}
	if tail_hint(ow, c)^ == oid {
		tail_hint(ow, c)^ = pred
	}
	next_ptr(o, c)^ = values.NOTHING
}

// chain_append adds `oid` at the end of `owner`'s list. `oid` must not be in any list of this
// kind (unlinked first), and its own parent/location field is the caller's to set.
chain_append :: proc(db: ^dbfile.Database, c: Chain, owner, oid: values.Objid) {
	ow := db.objects[owner]
	o := db.objects[oid]
	prev := values.NOTHING
	if head_ptr(ow, c)^ == values.NOTHING {
		head_ptr(ow, c)^ = oid
	} else {
		t := tail_hint(ow, c)^
		to, ok := db.objects[t]
		if !ok || t == oid || owner_of(to, c) != owner || next_ptr(to, c)^ != values.NOTHING {
			t = head_ptr(ow, c)^
			for next_ptr(db.objects[t], c)^ != values.NOTHING {
				t = next_ptr(db.objects[t], c)^
			}
			to = db.objects[t]
		}
		next_ptr(to, c)^ = oid
		prev = t
	}
	next_ptr(o, c)^ = values.NOTHING
	prev_hint(o, c)^ = prev
	tail_hint(ow, c)^ = oid
}
