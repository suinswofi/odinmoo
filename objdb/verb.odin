package objdb

// Verb lookup, ported from db_verbs.c's db_find_callable_verb()/find_verbdef_by_name().
// Unlike properties, verbs aren't duplicated per descendant -- dispatch just walks from oid
// toward the root, and the first ancestor with a name-matching, executable (VF_EXEC) verb
// wins.
//
// Callable lookups go through a cache, as they do upstream (db_verbs.c's verb cache). It was
// left out at first as "a pure speed optimization", but the walk it saves is the hottest path
// in the server -- every obj:verb(), pass() and :tell -- and it matches every alias pattern of
// every verb on every ancestor: 380 verbs on LambdaCore's #2, about 3.5us, which was ~80% of
// the cost of a call like #2:title(). Negative results are cached too, because cores probe for
// optional verbs with d-clear calls all the time.
//
// The cache is correct only while the verbs and the hierarchy it was filled from stand still,
// so verb_cache_clear runs on every change to either -- the same events the original's
// db_priv_affected_callable_verb_lookup covers: add_verb/delete_verb, set_verb_info (names and
// the x bit), chparent, recycle, renumber. A lookup from an id that isn't a live object is
// never cached, because create() can later make that id real.

import "../dbfile"
import "../values"
import "core:strings"

// VERB_CACHE_MAX bounds the cache: a loop calling o:("v" + tostr(i))() would otherwise add an
// entry per distinct name forever. Reaching it just starts the cache over.
VERB_CACHE_MAX :: 1 << 16

// verb_cache_clear drops every cached lookup. Call it after ANY change to a verbdef's name,
// perms or position, or to the parent chain or existence of any object.
verb_cache_clear :: proc(db: ^dbfile.Database) {
	for k in db.verb_cache {
		delete(k)
	}
	clear(&db.verb_cache)
}

Verb_Handle :: struct {
	definer: values.Objid,
	index:   int, // index into definer's verbdefs slice
	found:   bool,
}

// find_callable_verb ports db_find_callable_verb(): requires VF_EXEC (the 'x' permission
// bit) -- a verb without it can be found for editing (see find_defined_verb) but not called.
find_callable_verb :: proc(db: ^dbfile.Database, oid: values.Objid, name: string) -> Verb_Handle {
	if _, live := db.objects[oid]; !live {
		return Verb_Handle{}
	}
	// Key: the start id's four bytes, then the ASCII-folded name (verb_name_matches folds ASCII
	// only). Built in a stack buffer so a hit allocates nothing; a name too long for it just
	// skips the cache.
	buf: [132]byte
	if len(name) + 4 > len(buf) {
		return find_callable_verb_uncached(db, oid, name)
	}
	id := u32(oid)
	buf[0], buf[1], buf[2], buf[3] = byte(id), byte(id >> 8), byte(id >> 16), byte(id >> 24)
	for i in 0 ..< len(name) {
		buf[4 + i] = values.ascii_lower(name[i])
	}
	key := string(buf[:4 + len(name)])
	if e, hit := db.verb_cache[key]; hit {
		return Verb_Handle{definer = e.definer, index = e.index, found = e.found}
	}
	h := find_callable_verb_uncached(db, oid, name)
	if len(db.verb_cache) >= VERB_CACHE_MAX {
		verb_cache_clear(db)
	}
	db.verb_cache[strings.clone(key)] = dbfile.Verb_Cache_Entry{definer = h.definer, index = h.index, found = h.found}
	return h
}

@(private = "file")
find_callable_verb_uncached :: proc(db: ^dbfile.Database, oid: values.Objid, name: string) -> Verb_Handle {
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
