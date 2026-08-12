package dbfile

// DB file writing, ported from db_file.c's write_db_file() and friends -- the write side
// Phase 1 didn't need yet (structural load/validation only), needed now for Phase 8's
// checkpoint support. Mirrors read.odin's format exactly, field for field, so a written
// file reads back identically (round-trip is the actual validation in db_test.odin).

import "../values"
import "core:fmt"
import "core:os"
import "core:strings"

Writer :: struct {
	b: strings.Builder,
}

writer_make :: proc() -> Writer {
	return Writer{b = strings.builder_make()}
}

writer_destroy :: proc(w: ^Writer) {
	strings.builder_destroy(&w.b)
}

write_num :: proc(w: ^Writer, n: int) {
	fmt.sbprintfln(&w.b, "%d", n)
}

write_objid :: proc(w: ^Writer, o: values.Objid) {
	fmt.sbprintfln(&w.b, "%d", o)
}

write_float :: proc(w: ^Writer, f: f64) {
	fmt.sbprintfln(&w.b, "%v", f)
}

// write_string ports dbio_write_string(): one line of text, as-is (embedded newlines would
// corrupt the format -- same assumption the original makes about MOO strings never
// containing a raw newline in practice, since the lexer/string literals can't produce one).
write_string :: proc(w: ^Writer, s: string) {
	strings.write_string(&w.b, s)
	strings.write_byte(&w.b, '\n')
}

write_var :: proc(w: ^Writer, v: values.Var) {
	write_num(w, int(v.type))
	#partial switch v.type {
	case .Clear, .None:
	// no payload
	case .Str:
		write_string(w, v.data.str.s)
	case .Obj:
		write_num(w, int(v.data.obj))
	case .Err:
		write_num(w, int(v.data.err))
	case .Int:
		write_num(w, int(v.data.num))
	case .Catch, .Finally:
		write_num(w, int(v.data.num))
	case .Float:
		write_float(w, v.data.fnum)
	case .List:
		items := v.data.list.items
		write_num(w, len(items))
		for item in items {
			write_var(w, item)
		}
	}
}

write_program_text :: proc(w: ^Writer, src: string) {
	strings.write_string(&w.b, src)
	if len(src) > 0 && src[len(src) - 1] != '\n' {
		strings.write_byte(&w.b, '\n')
	}
	strings.write_string(&w.b, ".\n")
}

write_verbdef :: proc(w: ^Writer, v: Verbdef) {
	write_string(w, v.name)
	write_objid(w, v.owner)
	write_num(w, v.perms)
	write_num(w, v.prep)
}

write_propdef :: proc(w: ^Writer, p: Propdef) {
	write_string(w, p.name)
}

write_propval :: proc(w: ^Writer, p: Propval) {
	write_var(w, p.value)
	write_objid(w, p.owner)
	write_num(w, p.perms)
}

write_object :: proc(w: ^Writer, obj: ^Object) {
	if obj.recycled {
		fmt.sbprintfln(&w.b, "#%d recycled", obj.id)
		return
	}
	fmt.sbprintfln(&w.b, "#%d", obj.id)
	write_string(w, obj.name)
	write_string(w, "") // placeholder for the old handles string, matches the original
	write_num(w, obj.flags)
	write_objid(w, obj.owner)
	write_objid(w, obj.location)
	write_objid(w, obj.contents)
	write_objid(w, obj.next)
	write_objid(w, obj.parent)
	write_objid(w, obj.child)
	write_objid(w, obj.sibling)

	write_num(w, len(obj.verbdefs))
	for vd in obj.verbdefs {
		write_verbdef(w, vd)
	}

	write_num(w, len(obj.propdefs))
	for pd in obj.propdefs {
		write_propdef(w, pd)
	}

	write_num(w, len(obj.propvals))
	for pv in obj.propvals {
		write_propval(w, pv)
	}
}

// save_database writes a full checkpoint, in the same section order read_database expects:
// header, counts, users, objects (with recycled holes), verb programs (as a second pass, so
// object records don't have to interleave with variable-length source text), task queue
// trailer, active connections trailer.
save_database :: proc(db: ^Database, path: string) -> bool {
	w := writer_make()
	defer writer_destroy(&w)

	fmt.sbprintfln(&w.b, "** LambdaMOO Database, Format Version %d **", db.version)

	nprogs := 0
	max_oid := values.Objid(-1)
	for oid, obj in db.objects {
		if oid > max_oid {
			max_oid = oid
		}
		for vd in obj.verbdefs {
			if vd.has_program {
				nprogs += 1
			}
		}
	}

	write_num(&w, int(max_oid) + 1)
	write_num(&w, nprogs)
	write_num(&w, 0) // historical "dummy" field, matches the original
	write_num(&w, len(db.users))
	for u in db.users {
		write_objid(&w, u)
	}

	for i in values.Objid(0) ..= max_oid {
		obj, ok := db.objects[i]
		if !ok {
			fmt.sbprintfln(&w.b, "#%d recycled", i)
			continue
		}
		write_object(&w, obj)
	}

	for i in values.Objid(0) ..= max_oid {
		obj, ok := db.objects[i]
		if !ok {
			continue
		}
		for vd, vnum in obj.verbdefs {
			if !vd.has_program {
				continue
			}
			fmt.sbprintfln(&w.b, "#%d:%d", i, vnum)
			write_program_text(&w, vd.program_source)
		}
	}

	// Task queue trailer: this port's forked-task records are read-only snapshots from
	// load time (Phase 6's scheduler creates its own live tasks independently, not backed
	// by these records) -- re-emit what was loaded, matching the original's own behavior
	// of writing back whatever's currently queued.
	write_string(&w, "0 clocks")
	fmt.sbprintfln(&w.b, "%d queued tasks", len(db.forked_tasks))
	for ft in db.forked_tasks {
		fmt.sbprintfln(&w.b, "0 %d %d %d", ft.first_lineno, ft.start_time, ft.task_id)
		dummy := values.int_val(-111)
		write_var(&w, dummy)
		fmt.sbprintfln(&w.b, "%d -7 -8 %d -9 %d %d -10 %d", ft.this, ft.player, ft.progr, ft.vloc, ft.debug)
		write_string(&w, "") // argstr
		write_string(&w, "") // dobjstr
		write_string(&w, "") // iobjstr
		write_string(&w, "") // prepstr
		write_string(&w, ft.verb)
		write_string(&w, ft.verbname)
		fmt.sbprintfln(&w.b, "%d variables", len(ft.var_names))
		for name, i in ft.var_names {
			write_string(&w, name)
			write_var(&w, ft.var_values[i])
		}
		write_program_text(&w, ft.program_source)
	}
	fmt.sbprintfln(&w.b, "%d suspended tasks", db.suspended_task_count)

	if len(db.connections) > 0 {
		fmt.sbprintfln(&w.b, "%d active connections with listeners", len(db.connections))
		for c in db.connections {
			fmt.sbprintfln(&w.b, "%d %d", c.who, c.listener)
		}
	} else {
		write_string(&w, "0 active connections with listeners")
	}

	data := strings.to_string(w.b)
	werr := os.write_entire_file(path, transmute([]byte)data)
	return werr == nil
}
