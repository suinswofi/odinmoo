package dbfile

// Forked/suspended task-queue trailer, ported from tasks.c's write_task_queue()/
// read_task_queue() and execute.c's write_activ_as_pi()/read_activ_as_pi()/read_rt_env().
//
// Forked (queued) tasks are parsed fully -- their shape (an activation snapshot + a runtime
// environment + a verb program) needs no VM machinery to represent structurally, just to
// resume. Suspended tasks additionally embed a full VM/activation-stack snapshot
// (write_vm()/read_vm() in execute.c), which doesn't exist yet until Phase 3's VM package
// lands; a checkpoint with suspended tasks will surface that clearly (.Unsupported) rather
// than silently truncating or corrupting the read.

import "../values"
import "core:strconv"
import "core:strings"

// read_count_line parses "<n> <suffix>\n" (e.g. "0 clocks", "1 queued tasks").
read_count_line :: proc(r: ^Reader, suffix: string) -> (n: int, err: Read_Error) {
	line, lerr := read_line(r)
	if lerr != .None {
		return 0, lerr
	}
	sp := strings.index_byte(line, ' ')
	if sp < 0 || line[sp + 1:] != suffix {
		return 0, .Bad_Format
	}
	v, ok := strconv.parse_int(line[:sp], 10)
	if !ok {
		return 0, .Bad_Format
	}
	return v, .None
}

read_task_queue :: proc(r: ^Reader, version: int, db: ^Database) -> Read_Error {
	nclocks, cerr := read_count_line(r, "clocks")
	if cerr != .None {
		return cerr
	}
	for _ in 0 ..< nclocks {
		// Obsolete per-clock-queue record, kept only "for compatibility's sake"
		// (tasks.c's own comment) -- always 3 numbers on one line.
		if _, lerr := read_line(r); lerr != .None {
			return lerr
		}
	}

	nqueued, qerr := read_count_line(r, "queued tasks")
	if qerr != .None {
		return qerr
	}
	for _ in 0 ..< nqueued {
		ft, ferr := read_forked_task(r, version, db)
		if ferr != .None {
			return ferr
		}
		append(&db.forked_tasks, ft)
	}

	nsuspended, serr := read_count_line(r, "suspended tasks")
	if serr == .Unexpected_EOF {
		return .None // older DB format without this trailer at all
	}
	if serr != .None {
		return serr
	}
	db.suspended_task_count = nsuspended
	if nsuspended > 0 {
		// Needs execute.c's write_vm()/read_vm() equivalent -- Phase 3 (VM package).
		return .Bad_Format
	}
	return .None
}

read_forked_task :: proc(r: ^Reader, version: int, db: ^Database) -> (ft: Forked_Task_Record, err: Read_Error) {
	line, lerr := read_line(r)
	if lerr != .None {
		return ft, lerr
	}
	fields := strings.split(line, " ")
	defer delete(fields)
	if len(fields) != 4 {
		return ft, .Bad_Format
	}
	// fields[0] is a dummy/reserved slot in the original (always written as "0").
	first_lineno, ok1 := strconv.parse_int(fields[1], 10)
	start_time, ok2 := strconv.parse_int(fields[2], 10)
	task_id, ok3 := strconv.parse_int(fields[3], 10)
	if !ok1 || !ok2 || !ok3 {
		return ft, .Bad_Format
	}
	ft.first_lineno = first_lineno
	ft.start_time = start_time
	ft.task_id = task_id

	if aerr := read_activ_as_pi(r, db, &ft); aerr != .None {
		return ft, aerr
	}

	names, values_, rerr := read_rt_env(r, version, db)
	if rerr != .None {
		return ft, rerr
	}
	ft.var_names = names
	ft.var_values = values_

	src, serr := read_program_text(r)
	if serr != .None {
		return ft, serr
	}
	ft.program_source = src

	return ft, .None
}

// read_activ_as_pi ports execute.c's read_activ_as_pi(): a leading sentinel Var (always
// written as the constant -111, ignored on read -- ported verbatim, not reinterpreted),
// then 9 numbers (only this/player/progr/vloc/debug are meaningful; the rest are `-7 -8 -9
// -10`-style placeholders left over from a removed field, per the original's own `dummy`
// variable), then 4 discarded strings and 2 kept ones (verb, verbname).
read_activ_as_pi :: proc(r: ^Reader, db: ^Database, ft: ^Forked_Task_Record) -> Read_Error {
	if _, verr := read_var(r, db.version, &db.str_intern); verr != .None {
		return verr
	}

	line, lerr := read_line(r)
	if lerr != .None {
		return lerr
	}
	fields := strings.split(line, " ")
	defer delete(fields)
	if len(fields) != 9 {
		return .Bad_Format
	}
	this_n, ok1 := strconv.parse_int(fields[0], 10)
	player_n, ok2 := strconv.parse_int(fields[3], 10)
	progr_n, ok3 := strconv.parse_int(fields[5], 10)
	vloc_n, ok4 := strconv.parse_int(fields[6], 10)
	debug_n, ok5 := strconv.parse_int(fields[8], 10)
	if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 {
		return .Bad_Format
	}
	ft.this = values.Objid(this_n)
	ft.player = values.Objid(player_n)
	ft.progr = values.Objid(progr_n)
	ft.vloc = values.Objid(vloc_n)
	ft.debug = debug_n

	// argstr, dobjstr, iobjstr, prepstr -- all discarded, matching the original.
	for _ in 0 ..< 4 {
		if _, serr := read_string(r); serr != .None {
			return serr
		}
	}
	verb, verr := read_string(r)
	if verr != .None {
		return verr
	}
	ft.verb = intern_name(&db.name_intern, verb)
	verbname, vnerr := read_string(r)
	if vnerr != .None {
		return vnerr
	}
	ft.verbname = intern_name(&db.name_intern, verbname)
	return .None
}

// read_rt_env ports execute.c's read_rt_env(): a runtime environment snapshot as
// (variable-name, value) pairs, in whatever order the writer's variable slots happened to
// be in (reorder_rt_env() re-aligns this against a freshly-compiled program's own slot
// order at resume time -- a Phase 6 concern, once verb programs are actually compiled).
read_rt_env :: proc(r: ^Reader, version: int, db: ^Database) -> (names: []string, vals: []values.Var, err: Read_Error) {
	count, cerr := read_count_line(r, "variables")
	if cerr != .None {
		return nil, nil, cerr
	}
	names = make([]string, count)
	vals = make([]values.Var, count)
	for i in 0 ..< count {
		n, nerr := read_string(r)
		if nerr != .None {
			return names, vals, nerr
		}
		names[i] = intern_name(&db.name_intern, n)
		v, verr := read_var(r, version, &db.str_intern)
		if verr != .None {
			return names, vals, verr
		}
		vals[i] = v
	}
	return names, vals, .None
}
