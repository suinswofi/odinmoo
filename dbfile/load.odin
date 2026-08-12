package dbfile

// Top-level orchestration, ported from db_file.c's read_db_file(): header, object table,
// verb-program second pass, then the forked/suspended-task-queue and active-connections
// trailers that a live checkpoint carries.

import "../values"
import "core:os"
import "core:strconv"
import "core:strings"

Load_Error :: struct {
	stage: string,
	err:   Read_Error,
}

// load_database reads a whole .db file from disk. Returns an owned Database (release with
// database_destroy) plus a Load_Error with stage == "" on success.
load_database :: proc(path: string) -> (db: Database, lerr: Load_Error) {
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		return db, Load_Error{stage = "read file", err = .Unexpected_EOF}
	}
	defer delete(data)
	return load_database_bytes(data)
}

load_database_bytes :: proc(data: []byte) -> (db: Database, lerr: Load_Error) {
	r := reader_make(data)
	db.objects = make(map[values.Objid]^Object)
	db.str_intern = values.intern_table_init()
	db.name_intern = name_intern_init()

	version, verr := read_header(&r)
	if verr != .None {
		return db, Load_Error{"header", verr}
	}
	if !check_db_version(version) {
		return db, Load_Error{"header", .Bad_Format}
	}
	db.version = version

	nobjs, nprogs, _, nusers, herr := read_counts(&r)
	if herr != .None {
		return db, Load_Error{"counts", herr}
	}

	users := make([]values.Objid, nusers)
	for i in 0 ..< nusers {
		o, oerr := read_objid(&r)
		if oerr != .None {
			return db, Load_Error{"users", oerr}
		}
		users[i] = o
	}
	db.users = users

	for i in 0 ..< nobjs {
		obj, oerr := read_object(&r, version, &db.name_intern, &db.str_intern, values.Objid(i))
		if oerr != .None {
			return db, Load_Error{"objects", oerr}
		}
		if obj.id > db.max_oid {
			db.max_oid = obj.id
		}
		if !obj.recycled {
			db.objects[obj.id] = obj
		} else {
			free(obj)
		}
	}

	for _ in 0 ..< nprogs {
		oid, vnum, perr := read_program_header(&r)
		if perr != .None {
			return db, Load_Error{"programs", perr}
		}
		obj, found := db.objects[oid]
		if !found || vnum < 0 || vnum >= len(obj.verbdefs) {
			return db, Load_Error{"programs", .Bad_Format}
		}
		src, serr := read_program_text(&r)
		if serr != .None {
			return db, Load_Error{"programs", serr}
		}
		obj.verbdefs[vnum].program_source = src
		obj.verbdefs[vnum].has_program = true
	}

	if terr := read_task_queue(&r, version, &db); terr != .None {
		return db, Load_Error{"task queue", terr}
	}

	if cerr := read_active_connections(&r, &db); cerr != .None {
		return db, Load_Error{"active connections", cerr}
	}

	return db, Load_Error{}
}

// read_header ports the "** LambdaMOO Database, Format Version %u **" line.
read_header :: proc(r: ^Reader) -> (version: int, err: Read_Error) {
	line, lerr := read_line(r)
	if lerr != .None {
		return 0, lerr
	}
	prefix := "** LambdaMOO Database, Format Version "
	suffix := " **"
	if !strings.has_prefix(line, prefix) || !strings.has_suffix(line, suffix) {
		return 0, .Bad_Format
	}
	num_str := line[len(prefix):len(line) - len(suffix)]
	n, ok := strconv.parse_int(num_str, 10)
	if !ok {
		return 0, .Bad_Format
	}
	return n, .None
}

read_counts :: proc(r: ^Reader) -> (nobjs, nprogs, dummy, nusers: int, err: Read_Error) {
	vals: [4]int
	for i in 0 ..< 4 {
		v, verr := read_num(r)
		if verr != .None {
			return 0, 0, 0, 0, verr
		}
		vals[i] = v
	}
	return vals[0], vals[1], vals[2], vals[3], .None
}

// read_program_header ports the "#<oid>:<vnum>\n" line preceding each verb's source text.
// vnum in the file is 0-based (see db_file.c's comment "DB file is 0-based").
read_program_header :: proc(r: ^Reader) -> (oid: values.Objid, vnum: int, err: Read_Error) {
	line, lerr := read_line(r)
	if lerr != .None {
		return 0, 0, lerr
	}
	if len(line) < 1 || line[0] != '#' {
		return 0, 0, .Bad_Format
	}
	colon := strings.index_byte(line, ':')
	if colon < 0 {
		return 0, 0, .Bad_Format
	}
	oid_n, ok1 := strconv.parse_int(line[1:colon], 10)
	vnum_n, ok2 := strconv.parse_int(line[colon + 1:], 10)
	if !ok1 || !ok2 {
		return 0, 0, .Bad_Format
	}
	return values.Objid(oid_n), vnum_n, .None
}
