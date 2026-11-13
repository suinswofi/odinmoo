package vm

// Stack lists and tracebacks, ported from execute.c's make_stack_list() and
// print_error_backtrace().
//
// The original builds both from its activation array at the moment an error is raised
// (raise_error): the 4-element value an `except` arm binds is {code, message, value, stack}
// where stack lists the frames from the handler's activation up to the one that raised, and an
// error nobody catches is handed to #0:handle_uncaught_error with the whole stack plus the
// formatted traceback lines -- or, failing that, the traceback is printed to the player.
//
// This port unwinds through native stack frames, and an activation is gone by the time its
// error reaches whoever handles it. So the frames are captured where the error is CREATED, into
// the task's budget (one record per task, overwritten by the next error), tagged with a serial
// number that the Error_Info carries along. Whoever handles the error asks for the record by
// that serial; if a later error overwrote it (a `finally` handler raising and catching its own
// error while the first one is still unwinding), the handler falls back to the frames it can
// still see, which is the right answer for every frame that still exists.

import "../values"
import "core:fmt"
import "core:strings"

// Frame is one entry of a stack list as of the moment an error was raised.
Frame :: struct {
	this:       values.Objid,
	verb:       string, // owned; the name the verb was called by (callers()' second element)
	verb_names: string, // owned; the verbdef's full names (what a traceback prints)
	programmer: values.Objid,
	verb_loc:   values.Objid,
	player:     values.Objid,
	line:       int,
	depth:      int, // the activation's depth, used to cut the list at a handler's frame
	builtin:    bool, // the synthetic {#-1, "move", #-1, #-1, player} frame make_stack_list adds
}

frames_clear :: proc(frames: ^[dynamic]Frame) {
	for f in frames {
		delete(f.verb)
		delete(f.verb_names)
	}
	clear(frames)
}

// append_activation_frames appends the frames for `a` and every activation that called it,
// innermost first, in make_stack_list's order: each activation, then -- if a built-in invoked
// it -- that built-in's synthetic frame. Server scaffolding (depth < 0) is not a MOO frame.
append_activation_frames :: proc(frames: ^[dynamic]Frame, a: ^Activation) {
	for f := a; f != nil && f.depth >= 0; f = f.parent {
		append(frames, Frame{
			this       = f.this,
			verb       = strings.clone(f.verb_name),
			verb_names = strings.clone(f.verb_names != "" ? f.verb_names : f.verb_name),
			programmer = f.programmer,
			verb_loc   = f.verb_loc,
			player     = f.player,
			line       = f.line,
			depth      = f.depth,
		})
		if f.bi_func_name != "" {
			append(frames, Frame{
				this       = values.NOTHING,
				verb       = strings.clone(f.bi_func_name),
				verb_names = strings.clone(f.bi_func_name),
				programmer = values.NOTHING,
				verb_loc   = values.NOTHING,
				player     = f.player,
				line       = f.bi_func_pc,
				depth      = f.depth,
				builtin    = true,
			})
		}
	}
}

// record_error stamps `err` as freshly raised in ctx's activation: the frames as they stand
// now go into the task's record, and err carries the serial that names them.
record_error :: proc(ctx: ^Eval_Context, err: ^Error_Info) {
	b := ctx.activation.budget
	if b == nil {
		return
	}
	b.err_serial += 1
	frames_clear(&b.err_frames)
	append_activation_frames(&b.err_frames, ctx.activation)
	err.serial = b.err_serial
}

// error_frames returns the frames recorded for the error with this serial, or -- when the
// record has been overwritten -- freshly captured frames from `a` outward. Release with
// release_frames, passing back the `owned` flag.
error_frames :: proc(a: ^Activation, serial: int) -> (frames: [dynamic]Frame, owned: bool) {
	b := a.budget
	if b != nil && serial != 0 && serial == b.err_serial {
		return b.err_frames, false
	}
	append_activation_frames(&frames, a)
	return frames, true
}

release_frames :: proc(frames: ^[dynamic]Frame, owned: bool) {
	if !owned {
		return
	}
	frames_clear(frames)
	delete(frames^)
}

// stack_list builds make_stack_list's MOO value from frames whose depth is >= min_depth
// (the handler's activation; 0 for the whole task). Each entry is {this, verb, programmer,
// verb-loc, player, line}; the synthetic built-in frame belonging to the handler's own
// activation is left out, as make_stack_list's `i != start` test leaves it out.
stack_list :: proc(frames: [dynamic]Frame, min_depth: int, line_numbers := true) -> values.Var {
	items: [dynamic]values.Var
	for f in frames {
		if f.depth < min_depth || (f.builtin && f.depth == min_depth) {
			continue
		}
		entry := make([]values.Var, line_numbers ? 6 : 5)
		entry[0] = values.obj_val(f.this)
		entry[1] = values.str_val(strings.clone(f.verb))
		entry[2] = values.obj_val(f.programmer)
		entry[3] = values.obj_val(f.verb_loc)
		entry[4] = values.obj_val(f.player)
		if line_numbers {
			entry[5] = values.int_val(i32(f.line))
		}
		append(&items, values.list_val(entry))
	}
	shrink(&items)
	return values.list_val(items[:])
}

// traceback_lines formats print_error_backtrace()'s output for frames (innermost first),
// returning owned strings:
//
//	#6:look_self (this == #2), line 4:  Type mismatch
//	... called from built-in function move()
//	... called from #3:enterfunc, line 2
//	(End of traceback)
traceback_lines :: proc(frames: [dynamic]Frame, msg: string) -> [dynamic]string {
	out: [dynamic]string
	first := true
	for f in frames {
		if f.builtin {
			append(&out, fmt.aprintf("... called from built-in function %s()", f.verb))
			continue
		}
		b := strings.builder_make()
		if !first {
			strings.write_string(&b, "... called from ")
		}
		fmt.sbprintf(&b, "#%d:%s", f.verb_loc, f.verb_names)
		if f.verb_loc != f.this {
			fmt.sbprintf(&b, " (this == #%d)", f.this)
		}
		fmt.sbprintf(&b, ", line %d", f.line)
		if first {
			fmt.sbprintf(&b, ":  %s", msg)
		}
		append(&out, strings.to_string(b))
		first = false
	}
	append(&out, strings.clone("(End of traceback)"))
	return out
}

// strings_list turns owned lines into a MOO list of strings, consuming them.
strings_list :: proc(lines: [dynamic]string) -> values.Var {
	items := make([]values.Var, len(lines))
	for l, i in lines {
		items[i] = values.str_val(l)
	}
	delete(lines)
	return values.list_val(items)
}
