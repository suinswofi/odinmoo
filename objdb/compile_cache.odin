package objdb

// Verb bodies arrive from dbfile as raw MOO source text (see dbfile.Verbdef.program_source
// -- the .db format stores source, compiled at load time in the original, here compiled
// lazily on first call instead). This cache compiles each verb at most once and remembers
// parse failures so a broken verb doesn't get re-parsed on every call.

import "../compiler"
import "../dbfile"
import "../values"

Verb_Key :: struct {
	definer: values.Objid,
	index:   int,
}

Compiled_Verb :: struct {
	body:  []compiler.Stmt,
	names: compiler.Name_Table,
	ok:    bool, // false if the source failed to parse
}

Compile_Cache :: struct {
	entries: map[Verb_Key]Compiled_Verb,
}

compile_cache_init :: proc() -> Compile_Cache {
	return Compile_Cache{entries = make(map[Verb_Key]Compiled_Verb)}
}

compile_cache_destroy :: proc(c: ^Compile_Cache) {
	for _, cv in c.entries {
		compiler.free_stmts(cv.body)
		names := cv.names
		compiler.name_table_destroy(&names)
	}
	delete(c.entries)
}

// compile_cache_invalidate drops one cached entry (if present), freeing its AST -- call
// after set_verb_code() changes a verb's source (so the next call recompiles instead of
// running the stale cached body) or delete_verb() removes it entirely.
compile_cache_invalidate :: proc(cache: ^Compile_Cache, definer: values.Objid, index: int) {
	key := Verb_Key{definer = definer, index = index}
	if existing, found := cache.entries[key]; found {
		compiler.free_stmts(existing.body)
		names := existing.names
		compiler.name_table_destroy(&names)
		delete_key(&cache.entries, key)
	}
}

// compile_cache_invalidate_object drops every cached entry for a given definer object --
// call after recycle() destroys an object or renumber() changes one's id, either of which
// can leave stale entries keyed by an object id that now means something else (or nothing).
compile_cache_invalidate_object :: proc(cache: ^Compile_Cache, definer: values.Objid) {
	to_remove: [dynamic]Verb_Key
	defer delete(to_remove)
	for key in cache.entries {
		if key.definer == definer {
			append(&to_remove, key)
		}
	}
	for key in to_remove {
		entry := cache.entries[key]
		compiler.free_stmts(entry.body)
		names := entry.names
		compiler.name_table_destroy(&names)
		delete_key(&cache.entries, key)
	}
}

// get_compiled_verb compiles (and caches) the verb at the given handle. Returns ok=false if
// the source doesn't parse -- callers should surface this as an internal error (matching
// the original's "Unparsable program" load-time check, just deferred to first call here).
get_compiled_verb :: proc(db: ^dbfile.Database, cache: ^Compile_Cache, h: Verb_Handle) -> (cv: Compiled_Verb, ok: bool) {
	key := Verb_Key{definer = h.definer, index = h.index}
	if existing, found := cache.entries[key]; found {
		return existing, existing.ok
	}
	obj := db.objects[h.definer]
	vd := obj.verbdefs[h.index]
	r := compiler.parse_program(vd.program_source, db.version)
	result := Compiled_Verb{body = r.body, names = r.names, ok = len(r.errors) == 0}
	for e in r.errors {
		delete(e)
	}
	delete(r.errors)
	cache.entries[key] = result
	return result, result.ok
}
