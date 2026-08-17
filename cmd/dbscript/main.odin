package main

// dbscript: apply a scripted set of edits to a .db and write the result to a NEW file.
// Loads <in.db>, runs each <script> against it with the permissions of the lowest-numbered
// wizard (same choice as `moo -e` emergency mode), then saves to <out.db>. Nothing is
// written if any step fails, and the input file is never touched -- so it's safe to run
// against the bundled cores to produce derived variants (see themes/).
//
// Usage: odin run cmd/dbscript -extra-linker-flags:"-lcrypt" -- <in.db> <out.db> <script>...
//
// Script format (line-oriented; a line's first non-blank characters decide what it is):
//
//   // comment                         ignored, as are blank lines (outside @program blocks)
//   ;<moo statements>                  evaluated immediately, e.g. `;add_property(#0, "x", 1, {#2, "r"});`
//                                      (a `return` value is printed; a raised error aborts)
//   @verb <obj>:<names> <dobj> <prep> <iobj> [perms]
//                                      add_verb() -- quote multi-word names ("title heading");
//                                      perms default to "rxd"; a no-op if <obj> already defines it
//   @program <obj>:<name>              the following lines up to a lone `.` become the verb's
//     ...code...                       code (set_verb_code); if <obj> doesn't define the verb yet,
//   .                                  it's created first as `this none this` with perms "rxd"
//
// <obj> is any MOO expression yielding an object (`#3`, `$room`, `$string_utils`), so scripts
// stay portable across cores that number things differently.

import "../../builtins"
import "../../compiler"
import "../../dbfile"
import "../../objdb"
import "../../tasks"
import "../../values"
import "../../vm"
import "core:fmt"
import "core:os"
import "core:strings"

Env :: struct {
	db:      ^dbfile.Database,
	world:   ^vm.World,
	wizard:  values.Objid,
	task_id: int,
	// per-script bookkeeping for error messages
	file:    string,
	line:    int,
	// tallies for the summary
	stmts:   int,
	verbs:   int,
}

main :: proc() {
	args := os.args[1:]
	if len(args) < 3 {
		fmt.eprintln("usage: dbscript <in.db> <out.db> <script> [<script>...]")
		os.exit(2)
	}
	in_path, out_path := args[0], args[1]
	if in_path == out_path {
		fmt.eprintln("dbscript: refusing to overwrite the input database in place")
		os.exit(2)
	}

	fmt.printfln("dbscript: loading %s", in_path)
	db, lerr := dbfile.load_database(in_path)
	if lerr.stage != "" {
		fmt.eprintfln("dbscript: load failed at %s: %v", lerr.stage, lerr.err)
		os.exit(1)
	}
	defer dbfile.database_destroy(&db)

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := objdb.object_world_init(&db, &sched)
	defer objdb.object_world_destroy(&ow)
	world := objdb.make_world(&ow)

	env := Env{db = &db, world = &world, wizard = find_any_wizard(&db)}
	for script in args[2:] {
		if !run_script(&env, script) {
			fmt.eprintfln("dbscript: aborted at %s:%d -- nothing written", env.file, env.line)
			os.exit(1)
		}
	}

	if !dbfile.save_database(&db, out_path) {
		fmt.eprintfln("dbscript: failed to write %s", out_path)
		os.exit(1)
	}
	fmt.printfln("dbscript: %d statements, %d verb programs -> %s (%d objects)", env.stmts, env.verbs, out_path, len(db.objects))
}

find_any_wizard :: proc(db: ^dbfile.Database) -> values.Objid {
	for oid := values.Objid(0); oid <= db.max_oid; oid += 1 {
		if objdb.valid(db, oid) && objdb.is_wizard(db, oid) {
			return oid
		}
	}
	return values.SYSTEM_OBJECT
}

run_script :: proc(env: ^Env, path: string) -> bool {
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("dbscript: cannot read %s", path)
		return false
	}
	defer delete(data)
	env.file = path
	lines := strings.split_lines(string(data))
	defer delete(lines)

	i := 0
	for i < len(lines) {
		env.line = i + 1
		raw := lines[i]
		line := strings.trim_space(raw)
		i += 1
		switch {
		case len(line) == 0 || strings.has_prefix(line, "//"):
			continue
		case line[0] == ';':
			if !eval_stmts(env, line[1:], print_result = true) {
				return false
			}
			env.stmts += 1
		case strings.has_prefix(line, "@verb "):
			if !do_add_verb(env, strings.trim_space(line[len("@verb "):])) {
				return false
			}
		case strings.has_prefix(line, "@program "):
			ref := strings.trim_space(line[len("@program "):])
			start := i
			for i < len(lines) && strings.trim_space(lines[i]) != "." {
				i += 1
			}
			if i >= len(lines) {
				fmt.eprintfln("%s:%d: @program block never closed with `.`", path, start)
				return false
			}
			body := lines[start:i]
			i += 1 // skip the `.`
			env.line = start
			if !do_program(env, ref, body) {
				return false
			}
			env.verbs += 1
		case:
			fmt.eprintfln("%s:%d: unrecognized line: %s", path, env.line, line)
			return false
		}
	}
	return true
}

// split_ref splits "<objexpr>:<verbname>" at the LAST colon (object expressions like
// `$foo:bar()` could contain one, verb names never do).
split_ref :: proc(ref: string) -> (obj: string, verb: string, ok: bool) {
	idx := strings.last_index_byte(ref, ':')
	if idx <= 0 || idx == len(ref) - 1 {
		return "", "", false
	}
	return strings.trim_space(ref[:idx]), strings.trim_space(ref[idx + 1:]), true
}

// lookup_name is what verb_info() needs to find an existing verb: the first of its
// space-separated names with any `*` abbreviation marker removed ("l*ook" -> "look").
lookup_name :: proc(names: string) -> string {
	first := names
	if sp := strings.index_byte(names, ' '); sp >= 0 {
		first = names[:sp]
	}
	return strings.trim_suffix(first, "*") // only a trailing `*` (very common); "l*ook" is handled by verbcasecmp when it's not trailing
}

moo_quote :: proc(s: string, b: ^strings.Builder) {
	strings.write_byte(b, '"')
	for c in transmute([]byte)s {
		if c == '"' || c == '\\' {
			strings.write_byte(b, '\\')
		}
		strings.write_byte(b, c)
	}
	strings.write_byte(b, '"')
}

// write_verb_guard emits `o = (<obj>); if (<obj doesn't define the verb>) add_verb(o, {#wiz, `
// -- the shared prefix of both verb-creating statements; the caller finishes the add_verb().
// (Built with write_string rather than sbprintf: MOO's list braces would be read as fmt's
// own `{}` verbs.)
write_verb_guard :: proc(b: ^strings.Builder, obj, names: string, wizard: values.Objid) {
	strings.write_string(b, "o = (")
	strings.write_string(b, obj)
	strings.write_string(b, "); if (typeof(`verb_info(o, ")
	moo_quote(lookup_name(names), b)
	strings.write_string(b, ") ! E_VERBNF') == ERR) add_verb(o, {#")
	strings.write_int(b, int(wizard))
	strings.write_string(b, ", ")
}

do_add_verb :: proc(env: ^Env, spec: string) -> bool {
	fields := split_quoted(spec)
	defer delete(fields)
	if len(fields) < 4 {
		fmt.eprintfln("%s:%d: @verb needs <obj>:<names> <dobj> <prep> <iobj> [perms]", env.file, env.line)
		return false
	}
	obj, names, ok := split_ref(fields[0])
	if !ok {
		fmt.eprintfln("%s:%d: bad verb reference %q", env.file, env.line, fields[0])
		return false
	}
	perms := len(fields) >= 5 ? fields[4] : "rxd"
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_verb_guard(&b, obj, names, env.wizard)
	moo_quote(perms, &b)
	strings.write_string(&b, ", ")
	moo_quote(names, &b)
	strings.write_string(&b, "}, {")
	moo_quote(fields[1], &b)
	strings.write_string(&b, ", ")
	moo_quote(fields[2], &b)
	strings.write_string(&b, ", ")
	moo_quote(fields[3], &b)
	strings.write_string(&b, "}); endif")
	return eval_stmts(env, strings.to_string(b), print_result = false)
}

do_program :: proc(env: ^Env, ref: string, body: []string) -> bool {
	obj, names, ok := split_ref(ref)
	if !ok {
		fmt.eprintfln("%s:%d: bad verb reference %q", env.file, env.line, ref)
		return false
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	// Create the verb if <obj> doesn't define it, then install the code; the parse-error
	// list set_verb_code returns is the statement's value, checked below.
	write_verb_guard(&b, obj, names, env.wizard)
	strings.write_string(&b, "\"rxd\", ")
	moo_quote(names, &b)
	strings.write_string(&b, "}, {\"this\", \"none\", \"this\"}); endif; return set_verb_code(o, ")
	moo_quote(lookup_name(names), &b)
	strings.write_string(&b, ", {")
	for l, i in body {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		moo_quote(l, &b)
	}
	strings.write_string(&b, "});")

	result, ran := eval_capture(env, strings.to_string(b))
	if !ran {
		return false
	}
	defer values.free_var(result)
	if result.type == .List && values.list_len(result) > 0 {
		fmt.eprintfln("%s:%d: %s does not compile:", env.file, env.line, ref)
		for j in 1 ..= values.list_len(result) {
			e := values.list_get(result, j)
			if e.type == .Str {
				fmt.eprintfln("    %s", e.data.str.s)
			}
		}
		return false
	}
	fmt.printfln("  programmed %s (%d lines)", ref, len(body))
	return true
}

// split_quoted splits on whitespace; a "double-quoted" run (which may start mid-token, as in
// `$ansi:"title heading"`) is kept together with its quotes removed.
split_quoted :: proc(s: string) -> [dynamic]string {
	out: [dynamic]string
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	in_quote, in_token := false, false
	for c in transmute([]byte)s {
		switch {
		case c == '"':
			in_quote = !in_quote
			in_token = true
		case (c == ' ' || c == '\t') && !in_quote:
			if in_token {
				append(&out, strings.clone(strings.to_string(b)))
				strings.builder_reset(&b)
				in_token = false
			}
		case:
			strings.write_byte(&b, c)
			in_token = true
		}
	}
	if in_token {
		append(&out, strings.clone(strings.to_string(b)))
	}
	return out
}

eval_stmts :: proc(env: ^Env, src: string, print_result: bool) -> bool {
	result, ran := eval_capture(env, src)
	if !ran {
		return false
	}
	defer values.free_var(result)
	if print_result && result.type != .None && strings.contains(src, "return") {
		lit_args := make([]values.Var, 1)
		lit_args[0] = values.var_ref(result)
		lit, _ := builtins.call("toliteral", values.list_val(lit_args))
		defer values.free_var(lit.value)
		fmt.printfln("  %s:%d => %s", env.file, env.line, lit.value.data.str.s)
	}
	return true
}

// eval_capture runs src as a MOO program with wizard permissions and returns its `return`
// value (type .None if it fell off the end). ran=false means a parse error or a raised
// error, already reported.
eval_capture :: proc(env: ^Env, src: string) -> (result: values.Var, ran: bool) {
	r := compiler.parse_program(src, env.db.version)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		for e in r.errors {
			delete(e)
		}
		delete(r.errors)
	}
	if len(r.errors) > 0 {
		fmt.eprintfln("%s:%d: parse error: %s", env.file, env.line, r.errors[0])
		fmt.eprintfln("    in: %s", src)
		return {}, false
	}
	act := vm.activation_make(len(r.names.names), &r.names)
	defer vm.activation_destroy(&act)
	env.task_id += 1
	act.task_id = env.task_id
	act.debug = true
	act.programmer = env.wizard
	act.player = env.wizard
	act.this = values.NOTHING
	act.caller = env.wizard
	// Bind the builtin variables scripts are likely to lean on (`player` in particular, as
	// the natural owner for created objects), the way call_verb_from does for a real verb.
	if slot := compiler.find(&r.names, "player"); slot >= 0 {
		act.locals[slot] = values.obj_val(env.wizard)
	}
	if slot := compiler.find(&r.names, "caller"); slot >= 0 {
		act.locals[slot] = values.obj_val(env.wizard)
	}
	if slot := compiler.find(&r.names, "this"); slot >= 0 {
		act.locals[slot] = values.obj_val(values.NOTHING)
	}

	res := vm.run(r.body, &r.names, env.world, &act)
	switch res.signal {
	case .Return:
		return res.value, true
	case .Raised:
		fmt.eprintfln("%s:%d: ** %s (%s)", env.file, env.line, compiler.error_name(res.err.code), res.err.msg)
		delete(res.err.msg)
		values.free_var(res.err.value)
		return {}, false
	case .Normal, .Break, .Continue:
		return values.Var{}, true
	}
	return values.Var{}, true
}
