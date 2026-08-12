package values

// String interning, ported from src/str_intern.c. Purpose (per the original's header
// comment): dedupe identical strings loaded from the .db file so the same literal (a common
// property/verb-code constant, a common property name, etc.) isn't allocated hundreds of
// times over.
//
// Re-engineered from the original: str_intern.c hand-rolls a chained hash table over
// bump-allocated 100KB "hunks" to avoid fragmenting a 1990s malloc. Odin's built-in `map`
// is a well-tuned open-addressing hash table already, so there's no equivalent reason to
// hand-roll one here -- an Intern_Table is just a `map[string]Var` guarding calls to the
// same str_val/var_ref pattern the original used on a cache hit.
//
// Only DB-load-time strings should go through this (matching the original: runtime strings
// created during normal execution are NOT auto-interned, to avoid paying hash/lookup cost on
// every string operation for a dedup benefit that only matters for the bulk, mostly-static
// data loaded once at startup).

import "core:strings"

Intern_Table :: struct {
	entries: map[string]Var,
}

intern_table_init :: proc() -> Intern_Table {
	return Intern_Table{entries = make(map[string]Var)}
}

// intern_table_destroy releases the table's own reference on every entry (dropping any
// whose refcount hits 0 as a result) before freeing the table's bookkeeping.
//
// Bug fix vs. the original: str_intern_close() (str_intern.c) never releases the refcount
// it implicitly holds on every interned string -- the table hands out a ref on first intern()
// and then simply forgets about it forever, a small permanent per-string leak. It's harmless
// in the original's usage (interned once at DB-load time, in a process that runs until exit),
// but it's still a real leak, so here the table takes ownership symmetrically: one ref in on
// intern(), released on intern_table_destroy().
intern_table_destroy :: proc(t: ^Intern_Table) {
	for _, v in t.entries {
		free_var(v)
	}
	delete(t.entries)
}

// intern ports str_intern(): on a cache hit, returns a new reference (ref-counted, no copy)
// to the existing string; on a miss, clones s, wraps it as a Var, and remembers it for future
// callers.
intern :: proc(t: ^Intern_Table, s: string) -> Var {
	if existing, ok := t.entries[s]; ok {
		return var_ref(existing)
	}
	v := str_val(strings.clone(s))
	// The map key must be independent of caller-owned `s`; use the Var's own freshly-cloned
	// string as the key so the map never outlives the memory it points into.
	t.entries[v.data.str.s] = v
	return var_ref(v)
}
