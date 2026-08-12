package dbfile

// Object/verbdef/propdef/propval record parsing, ported from db_file.c's read_object()
// (and its read_verbdef/read_propdef/read_propval helpers).

import "../values"

read_verbdef :: proc(r: ^Reader, names: ^Name_Intern) -> (v: Verbdef, err: Read_Error) {
	name, nerr := read_string(r)
	if nerr != .None {
		return v, nerr
	}
	v.name = intern_name(names, name)
	owner, oerr := read_objid(r)
	if oerr != .None {
		return v, oerr
	}
	v.owner = owner
	perms, perr := read_num(r)
	if perr != .None {
		return v, perr
	}
	v.perms = perms
	prep, preerr := read_num(r)
	if preerr != .None {
		return v, preerr
	}
	v.prep = prep
	return v, .None
}

read_propdef :: proc(r: ^Reader, names: ^Name_Intern) -> (p: Propdef, err: Read_Error) {
	name, nerr := read_string(r)
	if nerr != .None {
		return p, nerr
	}
	p.name = intern_name(names, name)
	return p, .None
}

read_propval :: proc(r: ^Reader, version: int, str_intern: ^values.Intern_Table) -> (p: Propval, err: Read_Error) {
	val, verr := read_var(r, version, str_intern)
	if verr != .None {
		return p, verr
	}
	p.value = val
	owner, oerr := read_objid(r)
	if oerr != .None {
		values.free_var(val)
		return p, oerr
	}
	p.owner = owner
	perms, perr := read_num(r)
	if perr != .None {
		values.free_var(val)
		return p, perr
	}
	p.perms = perms
	return p, .None
}

// read_object ports read_object(): expects "#<oid>\n" (or "#<oid> recycled\n" for a hole
// left by a destroyed object) as the next record, where <oid> must equal next_oid (the
// original enforces strictly sequential object numbering via `oid != db_last_used_objid()+1`).
read_object :: proc(r: ^Reader, version: int, names: ^Name_Intern, str_intern: ^values.Intern_Table, next_oid: values.Objid) -> (obj: ^Object, err: Read_Error) {
	line, lerr := read_line(r)
	if lerr != .None {
		return nil, lerr
	}
	if len(line) < 1 || line[0] != '#' {
		return nil, .Bad_Format
	}
	oid, oerr := parse_objid_prefix(line[1:])
	if oerr != .None || oid != next_oid {
		return nil, .Bad_Format
	}

	obj = new(Object)
	obj.id = oid

	if len(line) > 1 && strip_prefix_num(line[1:]) == " recycled" {
		obj.recycled = true
		return obj, .None
	}

	name, nerr := read_string(r)
	if nerr != .None {
		free(obj)
		return nil, nerr
	}
	obj.name = intern_name(names, name)

	_, _ = read_string(r) // discarded "old handles string", matches read_object()

	flags, ferr := read_num(r)
	if ferr != .None {
		free(obj)
		return nil, ferr
	}
	obj.flags = flags

	fields := [7]^values.Objid{&obj.owner, &obj.location, &obj.contents, &obj.next, &obj.parent, &obj.child, &obj.sibling}
	for f in fields {
		v, verr := read_objid(r)
		if verr != .None {
			free(obj)
			return nil, verr
		}
		f^ = v
	}

	nverbs, nverr := read_num(r)
	if nverr != .None {
		free(obj)
		return nil, nverr
	}
	for _ in 0 ..< nverbs {
		v, verr := read_verbdef(r, names)
		if verr != .None {
			free(obj)
			return nil, verr
		}
		append(&obj.verbdefs, v)
	}

	nprops, perr2 := read_num(r)
	if perr2 != .None {
		free(obj)
		return nil, perr2
	}
	for _ in 0 ..< nprops {
		p, perr := read_propdef(r, names)
		if perr != .None {
			free(obj)
			return nil, perr
		}
		append(&obj.propdefs, p)
	}

	npropvals, pverr := read_num(r)
	if pverr != .None {
		free(obj)
		return nil, pverr
	}
	for _ in 0 ..< npropvals {
		pv, pverr2 := read_propval(r, version, str_intern)
		if pverr2 != .None {
			free(obj)
			return nil, pverr2
		}
		append(&obj.propvals, pv)
	}

	return obj, .None
}

// parse_objid_prefix reads a decimal integer from the start of s (used for "#<oid>..."
// lines where the oid isn't alone on the line -- it may be followed by " recycled").
parse_objid_prefix :: proc(s: string) -> (oid: values.Objid, err: Read_Error) {
	i := 0
	for i < len(s) && (s[i] == '-' || (s[i] >= '0' && s[i] <= '9')) {
		i += 1
	}
	if i == 0 {
		return 0, .Bad_Format
	}
	n := 0
	neg := false
	j := 0
	if s[0] == '-' {
		neg = true
		j = 1
	}
	for ; j < i; j += 1 {
		n = n * 10 + int(s[j] - '0')
	}
	if neg {
		n = -n
	}
	return values.Objid(n), .None
}

strip_prefix_num :: proc(s: string) -> string {
	i := 0
	for i < len(s) && (s[i] == '-' || (s[i] >= '0' && s[i] <= '9')) {
		i += 1
	}
	return s[i:]
}
