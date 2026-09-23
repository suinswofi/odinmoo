package compiler

// Variable name table, ported from src/sym_table.c. Local variable names resolve to a
// small integer "slot" (an index into the runtime environment array at execution time);
// resolution is case-insensitive and first-occurrence casing wins (`find_or_add_name`'s
// `mystrcasecmp` scan) -- e.g. `X = 1; x = 2;` both refer to the same slot, printed back as
// whichever spelling was seen first when decompiling.
//
// Slots 0..first_user_slot-1 are pre-bound to the fixed set of built-in runtime constants
// (NUM, OBJ, STR, ..., player, this, caller, ..., and INT/FLOAT from DBV_Float onward) --
// ported verbatim from sym_table.c's new_builtin_names(), including the exact slot order
// (SLOT_NUM..SLOT_IOBJSTR, then SLOT_INT/SLOT_FLOAT), since that order is baked into every
// compiled verb's variable-name table on disk.

import "../values"
import "core:strings"

Name_Table :: struct {
	names: [dynamic]string, // owned; index == slot
	// ASCII-lowercased name -> slot, keys owned. Built only once a table outgrows
	// NAME_INDEX_THRESHOLD: the linear scan below is what find_or_add_name does upstream, and
	// it made parsing O(identifiers x distinct names) -- 80000 distinct variables in one
	// eval() string took 37 seconds to parse, under big_lock. Built eagerly (on add, and on
	// clone) rather than lazily from `find`, because a compiled verb's table is shared by every
	// task running it and `find` must stay read-only.
	index: map[string]int,
}

// NAME_INDEX_THRESHOLD is where the hash index takes over from the scan. Almost every verb
// sits below it, and they are the tables looked up on every verb call (call_verb_from's
// builtin-slot finds), where a scan of a few short names beats hashing a folded key.
NAME_INDEX_THRESHOLD :: 32

builtin_slot_names := []string{
	"NUM", "OBJ", "STR", "LIST", "ERR",
	"player", "this", "caller", "verb", "args",
	"argstr", "dobj", "dobjstr", "prepstr", "iobj", "iobjstr",
}
builtin_slot_names_with_float := []string{"INT", "FLOAT"}

first_user_slot :: proc(version: int) -> int {
	count := len(builtin_slot_names)
	if version >= DBV_Float {
		count += len(builtin_slot_names_with_float)
	}
	return count
}

name_table_make :: proc(version: int) -> Name_Table {
	t := Name_Table{}
	for n in builtin_slot_names {
		append(&t.names, strings.clone(n))
	}
	if version >= DBV_Float {
		for n in builtin_slot_names_with_float {
			append(&t.names, strings.clone(n))
		}
	}
	return t
}

name_table_destroy :: proc(t: ^Name_Table) {
	for n in t.names {
		delete(n)
	}
	delete(t.names)
	for k in t.index {
		delete(k)
	}
	delete(t.index)
}

// find_or_add ports find_or_add_name(): case-insensitive lookup, adding a new slot (owning
// its own clone of name) on miss.
find_or_add :: proc(t: ^Name_Table, name: string) -> int {
	if slot := find(t, name); slot >= 0 {
		return slot
	}
	append(&t.names, strings.clone(name))
	slot := len(t.names) - 1
	if t.index != nil {
		t.index[fold_name(name)] = slot
	} else if len(t.names) > NAME_INDEX_THRESHOLD {
		name_table_build_index(t)
	}
	return slot
}

// find ports find_name(): case-insensitive lookup, -1 on miss (does not add). Read-only.
find :: proc(t: ^Name_Table, name: string) -> int {
	if t.index != nil {
		// Fold into a stack buffer when the name fits, so a lookup allocates nothing.
		buf: [64]byte
		key: string
		if len(name) <= len(buf) {
			for i in 0 ..< len(name) {
				buf[i] = values.ascii_lower(name[i])
			}
			key = string(buf[:len(name)])
		} else {
			key = fold_name(name)
		}
		slot, ok := t.index[key]
		if len(name) > len(buf) {
			delete(key)
		}
		return ok ? slot : -1
	}
	for n, i in t.names {
		if values.strings_equal_fold(n, name) {
			return i
		}
	}
	return -1
}

// name_table_build_index (re)builds t.index from t.names. First occurrence wins, matching the
// scan: a table never holds two names that fold equal, but a table assembled by hand could.
name_table_build_index :: proc(t: ^Name_Table) {
	if t.index == nil {
		t.index = make(map[string]int, len(t.names) * 2)
	}
	for n, i in t.names {
		key := fold_name(n)
		if key in t.index {
			delete(key)
			continue
		}
		t.index[key] = i
	}
}

// fold_name returns an owned ASCII-lowercased copy -- ASCII only, like values.strings_equal_fold.
@(private = "file")
fold_name :: proc(name: string) -> string {
	buf := make([]byte, len(name))
	for i in 0 ..< len(name) {
		buf[i] = values.ascii_lower(name[i])
	}
	return string(buf)
}

