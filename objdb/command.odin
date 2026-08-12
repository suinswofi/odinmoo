package objdb

// The real MOO command loop: parsing a typed line into verb/dobj/prep/iobj (parse_cmd.c's
// parse_command()), matching object-name text against a player's surroundings (match.c's
// match_object()), and finding the verb a command should dispatch to (tasks.c's
// find_verb_on()/db_find_command_verb()). Ported closely (not just "in spirit" like
// regex.odin) since these algorithms are short, precisely specified, and exactly what makes
// typed commands like `look`/`news`/`help`/`get sword from chest` actually work against the
// real database instead of only raw MOO-expression evaluation.

import "../dbfile"
import "../values"
import "core:strconv"
import "core:strings"

// AMBIGUOUS/FAILED_MATCH mirror structures.h's sentinel Objids (NOTHING is values.NOTHING,
// already -1) -- match_object()'s three special return values alongside a real object id.
AMBIGUOUS :: values.Objid(-2)
FAILED_MATCH :: values.Objid(-3)

// PREP_NONE mirrors db.h's db_prep_spec: no preposition found in the command line.
PREP_NONE :: -1
// PREP_ANY is a verb-arg-spec wildcard (matches any preposition, including none) -- never a
// value Parsed_Command.prep itself takes.
PREP_ANY :: -2

Parsed_Command :: struct {
	verb:    string, // owned
	argstr:  string, // owned -- raw text after the verb, unparsed
	args:    []string, // owned (each element owned) -- parse_into_words() of everything after the verb
	dobjstr: string, // owned
	dobj:    values.Objid,
	prep:    int, // PREP_NONE or a 0-based index into prep_table's prep field
	prepstr: string, // owned
	iobjstr: string, // owned
	iobj:    values.Objid,
	ok:      bool, // false if the line was empty (nothing to parse)
}

parsed_command_destroy :: proc(pc: ^Parsed_Command) {
	delete(pc.verb)
	delete(pc.argstr)
	for a in pc.args {
		delete(a)
	}
	delete(pc.args)
	delete(pc.dobjstr)
	delete(pc.prepstr)
	delete(pc.iobjstr)
}

// parse_words ports parse_into_words(): leading/trailing spaces trimmed, words split on
// unquoted spaces, `"` toggles a quoted region (consumed, not included in the output), `\`
// escapes the next character literally. A near-duplicate of netio/login.odin's
// split_command_words (same original C function, ported independently for two different
// layers -- login-line parsing predates command parsing and there's no lower-level shared
// package both already depend on); if the two ever drift, this one is the one to trust for
// anything touching Parsed_Command.
@(private = "file")
parse_words :: proc(s: string) -> []string {
	words: [dynamic]string
	i := 0
	n := len(s)
	for i < n && s[i] == ' ' {
		i += 1
	}
	for i < n {
		b := strings.builder_make()
		in_quotes := false
		for i < n && (in_quotes || s[i] != ' ') {
			c := s[i]
			switch c {
			case '"':
				in_quotes = !in_quotes
				i += 1
			case '\\':
				i += 1
				if i < n {
					strings.write_byte(&b, s[i])
					i += 1
				}
			case:
				strings.write_byte(&b, c)
				i += 1
			}
		}
		append(&words, strings.to_string(b))
		for i < n && s[i] == ' ' {
			i += 1
		}
	}
	return words[:]
}

@(private = "file")
join_words :: proc(words: []string) -> string {
	if len(words) == 0 {
		return strings.clone("")
	}
	b := strings.builder_make()
	for w, i in words {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, w)
	}
	return strings.to_string(b)
}

// Prep_Entry rows are grouped by prep index (0..14, ascending) with each prep's own
// alternates in the order they appear in db_verbs.c's prep_list -- both orderings matter:
// find_prep must find the LEFTMOST word position where ANY alternate matches, and at a given
// position must prefer an earlier-listed (often longer, e.g. "on top of" before "on")
// alternate of a lower-numbered prep before a later one, exactly matching db_find_prep's
// nested loop order (word position outer, then prep index, then that prep's own alternates).
@(private = "file")
Prep_Entry :: struct {
	prep:  int,
	words: []string,
}

@(private = "file")
prep_table := []Prep_Entry{
	{0, {"with"}}, {0, {"using"}},
	{1, {"at"}}, {1, {"to"}},
	{2, {"in", "front", "of"}},
	{3, {"in"}}, {3, {"inside"}}, {3, {"into"}},
	{4, {"on", "top", "of"}}, {4, {"on"}}, {4, {"onto"}}, {4, {"upon"}},
	{5, {"out", "of"}}, {5, {"from", "inside"}}, {5, {"from"}},
	{6, {"over"}},
	{7, {"through"}},
	{8, {"under"}}, {8, {"underneath"}}, {8, {"beneath"}},
	{9, {"behind"}},
	{10, {"beside"}},
	{11, {"for"}}, {11, {"about"}},
	{12, {"is"}},
	{13, {"as"}},
	{14, {"off"}}, {14, {"off", "of"}},
}

// find_prep ports db_find_prep() (the first/last-provided, non-exact-match variant
// parse_command always uses): the leftmost word position where any preposition's alternate
// word sequence matches, scanning prepositions in table order at each position. Not
// file-private: verb_crud.odin's match_prep_spec (set_verb_args' free-text preposition
// argument) reuses it too.
find_prep :: proc(words: []string) -> (prep: int, first: int, last: int, found: bool) {
	for i in 0 ..< len(words) {
		for entry in prep_table {
			n := len(entry.words)
			if i + n > len(words) {
				continue
			}
			matched := true
			for k in 0 ..< n {
				if !strings.equal_fold(words[i + k], entry.words[k]) {
					matched = false
					break
				}
			}
			if matched {
				return entry.prep, i, i + n - 1, true
			}
		}
	}
	return 0, 0, 0, false
}

// parse_command ports parse_cmd.c's parse_command(): splits a raw typed line into a verb
// name plus dobj/prep/iobj structure, resolving dobj/iobj text against `user`'s surroundings
// via match_object. The `"`/`:`/`;` first-character shorthands (say/emote/eval) are a real
// server-level feature, not a database convention -- ported here to match exactly.
parse_command :: proc(db: ^dbfile.Database, command: string, user: values.Objid) -> Parsed_Command {
	cmd := strings.trim_left(command, " ")

	argstr: string
	buf: string
	if len(cmd) > 0 && (cmd[0] == '"' || cmd[0] == ':' || cmd[0] == ';') {
		verb_word: string
		switch cmd[0] {
		case '"':
			verb_word = "say"
		case ':':
			verb_word = "emote"
		case:
			verb_word = "eval"
		}
		argstr = strings.clone(cmd[1:])
		buf = strings.concatenate({verb_word, " ", cmd[1:]})
	} else {
		i := 0
		in_quotes := false
		for i < len(cmd) && (in_quotes || cmd[i] != ' ') {
			c := cmd[i]
			if c == '"' {
				in_quotes = !in_quotes
				i += 1
			} else if c == '\\' && i + 1 < len(cmd) {
				i += 2
			} else {
				i += 1
			}
		}
		rest := strings.trim_left(cmd[i:], " ")
		argstr = strings.clone(rest)
		buf = strings.clone(cmd)
	}
	defer delete(buf)

	argv := parse_words(buf)
	defer {
		for w in argv {
			delete(w)
		}
		delete(argv)
	}

	if len(argv) == 0 {
		delete(argstr)
		return Parsed_Command{ok = false}
	}

	pc: Parsed_Command
	pc.ok = true
	pc.verb = strings.clone(argv[0])
	pc.argstr = argstr

	rest_words := argv[1:]
	pc.args = make([]string, len(rest_words))
	for w, i in rest_words {
		pc.args[i] = strings.clone(w)
	}

	prep, pstart, pend, found := find_prep(rest_words)
	if !found {
		pstart = len(rest_words)
		pend = len(rest_words)
		pc.prep = PREP_NONE
	} else {
		pc.prep = prep
	}

	if found {
		pc.prepstr = join_words(rest_words[pstart:pend + 1])
		pc.iobjstr = join_words(rest_words[pend + 1:])
		pc.iobj = match_object(db, user, pc.iobjstr)
	} else {
		pc.prepstr = strings.clone("")
		pc.iobjstr = strings.clone("")
		pc.iobj = values.NOTHING
	}

	dobj_words := rest_words[:pstart]
	if len(dobj_words) == 0 {
		pc.dobjstr = strings.clone("")
		pc.dobj = values.NOTHING
	} else {
		pc.dobjstr = join_words(dobj_words)
		pc.dobj = match_object(db, user, pc.dobjstr)
	}

	return pc
}

// match_object ports match.c's match_object(): "" -> NOTHING, "#123" -> that object (or
// FAILED_MATCH if invalid), "me"/"here" -> the player/their location, anything else ->
// match_contents (name/alias search over the player's inventory then their location's
// contents).
match_object :: proc(db: ^dbfile.Database, player: values.Objid, name: string) -> values.Objid {
	if len(name) == 0 {
		return values.NOTHING
	}
	if name[0] == '#' {
		n, ok := strconv.parse_int(name[1:])
		if !ok || !valid(db, values.Objid(n)) {
			return FAILED_MATCH
		}
		return values.Objid(n)
	}
	if !valid(db, player) {
		return FAILED_MATCH
	}
	if strings.equal_fold(name, "me") {
		return player
	}
	if strings.equal_fold(name, "here") {
		return db.objects[player].location
	}
	return match_contents(db, player, name)
}

@(private = "file")
Match_State :: struct {
	lname:           int,
	name:            string,
	exact:           values.Objid,
	exact_ambiguous: bool,
	partial:         values.Objid,
}

@(private = "file")
check_name_match :: proc(name: string, d: ^Match_State, oid: values.Objid) {
	if len(name) < d.lname || !strings.equal_fold(name[:d.lname], d.name) {
		return
	}
	if len(name) == d.lname {
		if d.exact == values.NOTHING || d.exact == oid {
			d.exact = oid
		} else {
			d.exact_ambiguous = true
		}
	} else {
		if d.partial == FAILED_MATCH || d.partial == oid {
			d.partial = oid
		} else {
			d.partial = AMBIGUOUS
		}
	}
}

// match_contents ports match.c's match_contents()/match_proc(): scans `player`'s own
// contents (inventory) then their location's contents, comparing each candidate's `.name`
// and (if it has one) `.aliases` list against `name` case-insensitively by PREFIX. A second,
// different EXACT match aborts the whole search early and returns AMBIGUOUS (matching
// db_for_all_contents's early-exit-on-1 signal from match_proc); a second, different partial
// match just downgrades `partial` to AMBIGUOUS without aborting the scan. Exact matches beat
// partial ones.
@(private = "file")
match_contents :: proc(db: ^dbfile.Database, player: values.Objid, name: string) -> values.Objid {
	if !valid(db, player) {
		return FAILED_MATCH
	}
	d := Match_State{lname = len(name), name = name, exact = values.NOTHING, partial = FAILED_MATCH}
	loc := db.objects[player].location

	for step in 0 ..< 2 {
		oid := player if step == 0 else loc
		if !valid(db, oid) {
			continue
		}
		c := db.objects[oid].contents
		for c != values.NOTHING {
			cobj, ok := db.objects[c]
			if !ok {
				break
			}
			check_name_match(cobj.name, &d, c)
			if d.exact_ambiguous {
				return AMBIGUOUS
			}
			h := find_property(db, c, "aliases")
			if h.found && h.builtin == .None {
				v := property_value(db, c, h)
				if v.type == .List {
					n := values.list_len(v)
					for i in 1 ..= n {
						item := values.list_get(v, i)
						if item.type == .Str {
							check_name_match(item.data.str.s, &d, c)
							if d.exact_ambiguous {
								values.free_var(v)
								return AMBIGUOUS
							}
						}
					}
				}
				values.free_var(v)
			}
			c = cobj.next
		}
	}

	if d.exact != values.NOTHING {
		return d.exact
	}
	return d.partial
}

// find_command_verb ports db_find_command_verb(): like find_callable_verb, but matches
// against the parsed command's dobj/prep/iobj arg-spec instead of requiring VF_EXEC --
// that's intentional (not a permission gap this port introduced): the original really does
// skip the exec-flag check here too, relying on arg-spec matching alone to keep non-command
// utility verbs (typically "this none this") from ever matching typed input.
find_command_verb :: proc(db: ^dbfile.Database, oid: values.Objid, verb: string, dobj_spec, prep, iobj_spec: int) -> Verb_Handle {
	cur := oid
	for {
		obj, ok := db.objects[cur]
		if !ok {
			return Verb_Handle{}
		}
		for vd, i in obj.verbdefs {
			if !verb_name_matches(vd.name, verb) {
				continue
			}
			vdobj := (vd.perms >> 4) & 0x3
			viobj := (vd.perms >> 6) & 0x3
			if (vdobj == 1 || int(vdobj) == dobj_spec) &&
			   (vd.prep == PREP_ANY || vd.prep == prep) &&
			   (viobj == 1 || int(viobj) == iobj_spec) {
				return Verb_Handle{definer = cur, index = i, found = true}
			}
		}
		if obj.parent == values.NOTHING {
			return Verb_Handle{}
		}
		cur = obj.parent
	}
}

// find_verb_on ports tasks.c's find_verb_on(): computes oid's own arg-spec view of
// pc.dobj/pc.iobj (ASPEC_THIS if oid itself is the matched object, ASPEC_NONE if nothing
// matched, ASPEC_ANY otherwise -- including for AMBIGUOUS/FAILED_MATCH, which still count as
// "something was there" for arg-spec purposes even though the verb will see the sentinel
// value itself) before searching.
find_verb_on :: proc(db: ^dbfile.Database, oid: values.Objid, pc: ^Parsed_Command) -> Verb_Handle {
	if !valid(db, oid) {
		return Verb_Handle{}
	}
	dobj_spec := 1
	if pc.dobj == oid {
		dobj_spec = 2
	} else if pc.dobj == values.NOTHING {
		dobj_spec = 0
	}
	iobj_spec := 1
	if pc.iobj == oid {
		iobj_spec = 2
	} else if pc.iobj == values.NOTHING {
		iobj_spec = 0
	}
	return find_command_verb(db, oid, pc.verb, dobj_spec, pc.prep, iobj_spec)
}
