package objdb

// Verb bodies arrive from dbfile as raw MOO source text (see dbfile.Verbdef.program_source
// -- the .db format stores source, compiled at load time in the original, here compiled
// lazily on first call instead). This cache compiles each verb at most once and remembers
// parse failures so a broken verb doesn't get re-parsed on every call.
//
// Entries are reference-counted (Compiled_Verb.rc), porting the original's program_ref()/
// free_program() discipline: the cache holds one reference, and every activation currently
// executing the verb holds another for as long as it runs (call_verb_from). Invalidation
// only drops the cache's reference, so a set_verb_code() aimed at a verb that is still on
// some task's stack -- a suspended task whose verb is being re-@programmed, or LambdaCore's
// $code_utils:eval_d_util, whose freshly installed body starts by rewriting ITSELF -- leaves
// the running AST alive until that activation returns, instead of freeing it out from under
// the interpreter mid-statement.

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
	rc:    int, // references: 1 for the cache itself + 1 per activation currently running it
}

Compile_Cache :: struct {
	entries: map[Verb_Key]^Compiled_Verb,
}

compile_cache_init :: proc() -> Compile_Cache {
	return Compile_Cache{entries = make(map[Verb_Key]^Compiled_Verb)}
}

compile_cache_destroy :: proc(c: ^Compile_Cache) {
	for _, cv in c.entries {
		compiled_verb_release(cv)
	}
	delete(c.entries)
}

// compiled_verb_retain/release bracket a use of a cached verb that must outlive any
// invalidation happening meanwhile (i.e. running it). All callers hold big_lock, so a plain
// counter suffices. release frees the AST once the last reference is gone.
compiled_verb_retain :: proc(cv: ^Compiled_Verb) {
	cv.rc += 1
}

compiled_verb_release :: proc(cv: ^Compiled_Verb) {
	cv.rc -= 1
	if cv.rc > 0 {
		return
	}
	compiler.free_stmts(cv.body)
	compiler.name_table_destroy(&cv.names)
	free(cv)
}

// compile_cache_invalidate drops one cached entry (if present), freeing its AST -- call
// after set_verb_code() changes a verb's source (so the next call recompiles instead of
// running the stale cached body) or delete_verb() removes it entirely.
compile_cache_invalidate :: proc(cache: ^Compile_Cache, definer: values.Objid, index: int) {
	key := Verb_Key{definer = definer, index = index}
	if existing, found := cache.entries[key]; found {
		delete_key(&cache.entries, key)
		compiled_verb_release(existing)
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
		delete_key(&cache.entries, key)
		compiled_verb_release(entry)
	}
}

// get_compiled_verb compiles (and caches) the verb at the given handle. Returns ok=false if
// the source doesn't parse -- callers should surface this as an internal error (matching
// the original's "Unparsable program" load-time check, just deferred to first call here).
// The returned pointer is the cache's own reference: a caller that is about to RUN the body
// must compiled_verb_retain() it first and release it afterwards, or an invalidation during
// the run frees the AST mid-execution.
get_compiled_verb :: proc(db: ^dbfile.Database, cache: ^Compile_Cache, h: Verb_Handle) -> (cv: ^Compiled_Verb, ok: bool) {
	key := Verb_Key{definer = h.definer, index = h.index}
	if existing, found := cache.entries[key]; found {
		return existing, existing.ok
	}
	obj := db.objects[h.definer]
	vd := obj.verbdefs[h.index]
	r := compiler.parse_program(vd.program_source, db.version)
	result := new(Compiled_Verb)
	result^ = Compiled_Verb{body = r.body, names = r.names, ok = len(r.errors) == 0, rc = 1}
	for e in r.errors {
		delete(e)
	}
	delete(r.errors)
	cache.entries[key] = result
	return result, result.ok
}
