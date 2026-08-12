package dbfile

// Low-level primitives for the LambdaMOO .db text format, ported from src/db_io.c's
// dbio_read_* family. The C original streams from a buffered FILE*; here we load the whole
// file into memory up front (LambdaCore.db is ~2.3MB, comfortably fits) and read from a
// byte-slice cursor instead. This is a deliberate simplification, not a behavior change:
// db_io.c's dbio_read_string() already special-cases "line longer than my 1024-byte buffer"
// by spilling into a Stream and looping -- a workaround for a fixed-size C buffer that simply
// isn't a concern once the source is an in-memory slice; a "read to next newline" here has no
// length limit to work around in the first place.

import "../values"
import "core:strconv"
import "core:strings"

Reader :: struct {
	data: []byte,
	pos:  int,
}

Read_Error :: enum {
	None,
	Unexpected_EOF,
	Bad_Number,
	Bad_Format,
}

reader_make :: proc(data: []byte) -> Reader {
	return Reader{data = data, pos = 0}
}

reader_at_eof :: proc(r: ^Reader) -> bool {
	return r.pos >= len(r.data)
}

// read_line consumes bytes up to and including the next '\n' (or to EOF), returning the
// line WITHOUT the trailing newline. Ports the line-oriented half of dbio_read_string /
// dbio_read_num / dbio_scanf's per-field newline handling.
read_line :: proc(r: ^Reader) -> (line: string, err: Read_Error) {
	if reader_at_eof(r) {
		return "", .Unexpected_EOF
	}
	start := r.pos
	for r.pos < len(r.data) && r.data[r.pos] != '\n' {
		r.pos += 1
	}
	line = string(r.data[start:r.pos])
	if r.pos < len(r.data) {
		r.pos += 1 // consume the newline
	}
	return line, .None
}

// read_num ports dbio_read_num(): a decimal integer alone on its own line.
read_num :: proc(r: ^Reader) -> (n: int, err: Read_Error) {
	line, lerr := read_line(r)
	if lerr != .None {
		return 0, lerr
	}
	v, ok := strconv.parse_int(line, 10)
	if !ok {
		return 0, .Bad_Number
	}
	return v, .None
}

read_objid :: proc(r: ^Reader) -> (o: values.Objid, err: Read_Error) {
	n, nerr := read_num(r)
	return values.Objid(n), nerr
}

read_float :: proc(r: ^Reader) -> (f: f64, err: Read_Error) {
	line, lerr := read_line(r)
	if lerr != .None {
		return 0, lerr
	}
	v, ok := strconv.parse_f64(line)
	if !ok {
		return 0, .Bad_Number
	}
	return v, .None
}

// read_string ports dbio_read_string(): one line of text, empty string allowed.
// Ownership: returns a slice into the reader's own backing buffer (no allocation) --
// callers that need an independent, owned copy must strings.clone() it (this mirrors the
// original's contract, where callers either str_dup or str_intern the result immediately).
read_string :: proc(r: ^Reader) -> (s: string, err: Read_Error) {
	return read_line(r)
}

// read_string_owned is read_string plus an explicit clone, for callers that need to hold
// the result past the reader's lifetime (e.g. into a long-lived DB structure).
read_string_owned :: proc(r: ^Reader) -> (s: string, err: Read_Error) {
	line, lerr := read_line(r)
	if lerr != .None {
		return "", lerr
	}
	return strings.clone(line), .None
}

// expect_literal consumes `lit` followed by a newline, failing if the line doesn't match.
// Used for the fixed-text trailer lines ("0 clocks", "N active connections", etc.) that the
// C original parses with dbio_scanf's literal-text matching.
expect_line :: proc(r: ^Reader, expected: string) -> Read_Error {
	line, lerr := read_line(r)
	if lerr != .None {
		return lerr
	}
	if line != expected {
		return .Bad_Format
	}
	return .None
}

// read_var ports dbio_read_var(): a type tag line, then type-dependent payload.
// version is the DB_Version this file was written under (needed for the Prehistory-era
// TYPE_ANY quirk, ported verbatim from db_io.c's dbio_read_var).
read_var :: proc(r: ^Reader, version: int, intern: ^values.Intern_Table) -> (v: values.Var, err: Read_Error) {
	tag, terr := read_num(r)
	if terr != .None {
		return values.none_val(), terr
	}
	if tag == -1 && version == DBV_Prehistory {
		tag = int(values.Var_Type.None)
	}
	switch values.Var_Type(tag) {
	case .Clear:
		return values.clear_val(), .None
	case .None:
		return values.none_val(), .None
	case .Str:
		s, serr := read_string(r)
		if serr != .None {
			return values.none_val(), serr
		}
		return values.intern(intern, s), .None
	case .Obj:
		n, nerr := read_num(r)
		return values.obj_val(values.Objid(n)), nerr
	case .Err:
		n, nerr := read_num(r)
		return values.err_val(values.Error(n)), nerr
	case .Int:
		n, nerr := read_num(r)
		return values.int_val(i32(n)), nerr
	case .Catch:
		n, nerr := read_num(r)
		return values.catch_val(i32(n)), nerr
	case .Finally:
		n, nerr := read_num(r)
		return values.finally_val(i32(n)), nerr
	case .Float:
		f, ferr := read_float(r)
		return values.float_val(f), ferr
	case .List:
		n, nerr := read_num(r)
		if nerr != .None {
			return values.none_val(), nerr
		}
		items := make([]values.Var, n)
		for i in 0 ..< n {
			item, ierr := read_var(r, version, intern)
			if ierr != .None {
				return values.none_val(), ierr
			}
			items[i] = item
		}
		return values.list_val(items), .None
	}
	return values.none_val(), .Bad_Format
}

// read_program_text ports dbio_read_program()'s framing: source lines up to (but not
// including) a line consisting of a single "." -- the MOO verb-program end marker. Returns
// an owned copy since program text always outlives the reader.
read_program_text :: proc(r: ^Reader) -> (text: string, err: Read_Error) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for {
		line, lerr := read_line(r)
		if lerr != .None {
			return "", lerr
		}
		if line == "." {
			return strings.clone(strings.to_string(b)), .None
		}
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
}
