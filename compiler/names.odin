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

import "core:strings"

Name_Table :: struct {
	names: [dynamic]string, // owned; index == slot
}

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
}

// find_or_add ports find_or_add_name(): case-insensitive lookup, adding a new slot (owning
// its own clone of name) on miss.
find_or_add :: proc(t: ^Name_Table, name: string) -> int {
	for n, i in t.names {
		if strings.equal_fold(n, name) {
			return i
		}
	}
	append(&t.names, strings.clone(name))
	return len(t.names) - 1
}

// find ports find_name(): case-insensitive lookup, -1 on miss (does not add).
find :: proc(t: ^Name_Table, name: string) -> int {
	for n, i in t.names {
		if strings.equal_fold(n, name) {
			return i
		}
	}
	return -1
}
