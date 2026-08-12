package objdb

// Verb lookup, ported from db_verbs.c's db_find_callable_verb()/find_verbdef_by_name().
// Unlike properties, verbs aren't duplicated per descendant -- dispatch just walks from oid
// toward the root, and the first ancestor with a name-matching, executable (VF_EXEC) verb
// wins. (The original also maintains a hash-bucket verb cache here for performance; that's
// a pure speed optimization with no semantic effect, so it's not ported.)

import "../dbfile"
import "../values"

Verb_Handle :: struct {
	definer: values.Objid,
	index:   int, // index into definer's verbdefs slice
	found:   bool,
}

// find_callable_verb ports db_find_callable_verb(): requires VF_EXEC (the 'x' permission
// bit) -- a verb without it can be found for editing (see find_defined_verb) but not called.
find_callable_verb :: proc(db: ^dbfile.Database, oid: values.Objid, name: string) -> Verb_Handle {
	cur := oid
	for {
		obj, ok := db.objects[cur]
		if !ok {
			return Verb_Handle{}
		}
		for vd, i in obj.verbdefs {
			if verb_name_matches(vd.name, name) && (vd.perms & (1 << uint(Verb_Flag.Exec))) != 0 {
				return Verb_Handle{definer = cur, index = i, found = true}
			}
		}
		if obj.parent == values.NOTHING {
			return Verb_Handle{}
		}
		cur = obj.parent
	}
}

// find_defined_verb ports db_find_defined_verb(): looks only at oid's OWN verbdefs (no
// inheritance walk, no VF_EXEC requirement) -- used for editing/introspection builtins like
// verb_code()/set_verb_code(), not for `obj:verb(...)` dispatch.
find_defined_verb :: proc(db: ^dbfile.Database, oid: values.Objid, name: string) -> Verb_Handle {
	obj, ok := db.objects[oid]
	if !ok {
		return Verb_Handle{}
	}
	for vd, i in obj.verbdefs {
		if verb_name_matches(vd.name, name) {
			return Verb_Handle{definer = oid, index = i, found = true}
		}
	}
	return Verb_Handle{}
}
