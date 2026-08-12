package dbfile

// LambdaMOO .db text-format structures and top-level orchestration, ported from
// src/db_file.c's read_db_file() / write_db_file(), src/db_private.h's Object/Verbdef/
// Propdef/Pval structs, and src/version.h's DB_Version enum.
//
// Verb program bodies are kept as raw MOO source text at this stage (Verbdef.program_source)
// -- compiling them is Phase 2's job (the compiler package doesn't exist yet). Structurally
// this package is already faithful to the full on-disk format, including the forked-task
// queue and active-connections trailers that real checkpoints carry.

import "../values"
import "core:strings"

// Name_Intern dedupes structural identifier strings (object/verb/property names) loaded
// from the DB. In the C original, str_intern.c is used for *both* these structural names
// and genuine STR-typed Var payloads (dbio_read_string_intern() is called from both
// read_object()'s `o->name = ...` and dbio_read_var()'s TYPE_STR case) via one shared pool.
// Re-engineered here into two pools instead of one: names are plain, never-refcounted
// strings owned by the Database for its whole lifetime (there's no reason to pay for
// refcount bookkeeping on a string nothing ever partially releases), while genuine Var
// payloads go through values.Intern_Table, which does need refcounting since individual
// property/variable values really do get replaced and freed independently at runtime.
Name_Intern :: struct {
	entries: map[string]string,
}

name_intern_init :: proc() -> Name_Intern {
	return Name_Intern{entries = make(map[string]string)}
}

name_intern_destroy :: proc(t: ^Name_Intern) {
	for _, s in t.entries {
		delete(s)
	}
	delete(t.entries)
}

intern_name :: proc(t: ^Name_Intern, s: string) -> string {
	if existing, ok := t.entries[s]; ok {
		return existing
	}
	owned := strings.clone(s)
	t.entries[owned] = owned
	return owned
}

// DB_Version ordinals are DB-accessible knowledge (stored as a raw integer in the file
// header) -- must match version.h's enum order exactly.
DBV_Prehistory :: 0
DBV_Exceptions :: 1
DBV_BreakCont :: 2
DBV_Float :: 3
DBV_BFBugFixed :: 4
Num_DB_Versions :: 5
Current_DB_Version :: Num_DB_Versions - 1

check_db_version :: proc(v: int) -> bool {
	return v >= DBV_Prehistory && v < Num_DB_Versions
}

Verbdef :: struct {
	name:           string,
	owner:          values.Objid,
	perms:          int,
	prep:           int,
	program_source: string, // raw MOO source, attached in the second pass; "" until then
	has_program:    bool,
}

Propdef :: struct {
	name: string,
}

Propval :: struct {
	value: values.Var,
	owner: values.Objid,
	perms: int,
}

Object :: struct {
	id:       values.Objid,
	recycled: bool, // matches a "#<oid> recycled" record -- a hole left by a destroyed object
	name:     string,
	flags:    int,
	owner:    values.Objid,
	location: values.Objid,
	contents: values.Objid,
	next:     values.Objid, // sibling-in-contents-list link (see db_private.h)
	parent:   values.Objid,
	child:    values.Objid,
	sibling:  values.Objid,
	verbdefs: [dynamic]Verbdef,
	propdefs: [dynamic]Propdef,
	propvals: [dynamic]Propval,
}

// Forked_Task_Record is a queued (not-yet-run) `fork` task pulled from a checkpoint,
// ported from tasks.c's write_forked_task()/read_task_queue(). Kept as raw parsed fields;
// resuming it into a live task is a Phase 6 (task scheduler) concern.
Forked_Task_Record :: struct {
	first_lineno: int,
	start_time:   int,
	task_id:      int,
	this:         values.Objid,
	player:       values.Objid,
	progr:        values.Objid,
	vloc:         values.Objid,
	debug:        int,
	verb:         string,
	verbname:     string,
	var_names:    []string,
	var_values:   []values.Var,
	program_source: string,
}

Connection_Record :: struct {
	who:      values.Objid,
	listener: values.Objid,
}

Database :: struct {
	version:            int,
	objects:            map[values.Objid]^Object, // valid (non-recycled) objects only
	max_oid:            values.Objid,
	users:              []values.Objid,
	forked_tasks:       [dynamic]Forked_Task_Record,
	suspended_task_count: int, // parsed but not decoded -- see load.odin's note
	connections:        [dynamic]Connection_Record,
	str_intern:         values.Intern_Table, // genuine STR Var payloads
	name_intern:        Name_Intern,          // structural names (objects/verbs/props)
}

database_destroy :: proc(db: ^Database) {
	values.intern_table_destroy(&db.str_intern)
	name_intern_destroy(&db.name_intern)
	for _, obj in db.objects {
		for v in obj.verbdefs {
			delete(v.program_source)
		}
		delete(obj.verbdefs)
		delete(obj.propdefs)
		for pv in obj.propvals {
			values.free_var(pv.value)
		}
		delete(obj.propvals)
		free(obj)
	}
	delete(db.objects)
	delete(db.users)
	for ft in db.forked_tasks {
		delete(ft.var_names)
		for v in ft.var_values {
			values.free_var(v)
		}
		delete(ft.var_values)
		delete(ft.program_source)
	}
	delete(db.forked_tasks)
	delete(db.connections)
}
