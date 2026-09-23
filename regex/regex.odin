package regex

// MOO pattern matching, ported in spirit (not line-for-line) from src/regexpr.c +
// src/pattern.c. The original is a 1673-line general GNU-regex-derived NFA compiler; this is
// a from-scratch backtracking VM (Pike/Cox-style: compile to a small bytecode with
// Split/Jmp/Save instructions, run via a recursive backtracking interpreter) sized for the
// actual MOO pattern dialect, not general regex compatibility. Semantics were derived
// directly from pattern.c's translate_pattern() table (which chars need `%` to become
// special) and regexpr.c's regexp_plain_ops/regexp_quoted_ops init (which of those are
// special unescaped vs. literal-when-escaped) -- both read in full rather than guessed from
// memory, since the two engines disagree in places a person would not expect (`*`/`+`/`?`
// are quantifiers UNESCAPED and literal when %-escaped; `(`/`)`/`|` are the opposite: literal
// unescaped, special when %-escaped).
//
// Supported: literal chars, `.` (any), `^`/`$` (anchors, always special per
// RE_CONTEXT_INDEP_OPS -- not just at pattern start/end), `[...]`/`[^...]` classes with `a-z`
// ranges, `%(...%)` capturing groups (up to 9, MOO's fixed cap), `%|` alternation, `%X`
// literal-escapes, `%b`/`%B` word-boundary/non-boundary, `%w`/`%W` word/non-word char.
// NOT supported (scope cut -- rare in practice, and each would meaningfully grow this file):
// in-pattern backreferences (`%1`-`%9` used inside the pattern itself, as opposed to
// substitute()'s template use of the same syntax, which IS supported), `%<`/`%>` word
// start/end, ANSI hex escapes. An unsupported escape falls back to matching the literal
// character rather than raising, the same graceful-degradation choice made elsewhere in this
// port (e.g. ansi.odin's handling of unrecognized %-codes).

import "core:strings"

// Op is a u8 and Instr is packed to 16 bytes because a pattern is an ordinary MOO string of up
// to values.MAX_STR_LEN, compiled on every match() call: at the old 56-byte Instr, plus a
// separately heap-allocated 256-byte table per `[...]`/`%w`/`%W`, plus two per-instruction
// int arrays in the Runner, compiling cost about 170x the pattern's size -- one match() with an
// 8MB pattern of "%w" allocated 1.35GB. Character classes now live once each in
// Program.classes (32-byte bit sets, identical ones shared), and the loop guard is sized by the
// number of loops rather than the number of instructions.
Op :: enum u8 {
	Char,
	Any,
	Class,
	Bol,
	Eol,
	Wordb,
	NWordb,
	Jmp,
	Split,
	Save,
	Match,
}

// Char_Set is a 256-bit membership set, one bit per byte value (Odin's bit_set stops at 128).
Char_Set :: [4]u64

@(private = "file")
set_add :: proc(s: ^Char_Set, b: int) {
	s[b >> 6] |= 1 << uint(b & 63)
}

@(private = "file")
set_has :: proc(s: Char_Set, b: byte) -> bool {
	return s[b >> 6] & (1 << uint(b & 63)) != 0
}

Instr :: struct {
	op:      Op,
	c:       byte, // Char
	negate:  bool, // Class
	is_loop: bool, // Split only: true for */+'s loop-back split (wrap_star/wrap_plus) --
	// tells run() to guard against infinite recursion when the loop body matches zero
	// width (e.g. `%(a*%)*`): without this, a body that matches empty re-enters the same
	// Split at the same position forever, which is unbounded RECURSION DEPTH (not just
	// unbounded work) and crashes the process with a stack overflow before MAX_STEPS is
	// ever reached. Not set for compile_alt's alternation split or wrap_opt's `?` split,
	// neither of which loop back to themselves.
	x, y:    i32, // Jmp target (x); Split targets (x, y); Save slot (x); Class: index into Program.classes (x)
	loop:    i32, // loop-Split only: its slot in the Runner's loop guard, 0..<Program.n_loops
}

Program :: struct {
	instrs:  []Instr,
	classes: []Char_Set,
	n_loops: int,
}

program_destroy :: proc(p: ^Program) {
	delete(p.instrs)
	delete(p.classes)
}

@(private = "file")
Parser :: struct {
	pat:   string,
	pos:   int,
	instrs: [dynamic]Instr,
	classes: [dynamic]Char_Set,
	class_index: map[Char_Set]i32, // dedup: one table entry per distinct set
	n_loops: int,
	ngroup: int,
	depth:  int, // compile_alt recursion depth -- see MAX_ALT_DEPTH
	ok:     bool,
}

// MAX_ALT_DEPTH caps how many `%|` branches one alternation may have, because compile_alt
// recurses once per branch (its rewrite re-enters itself for the rest of the alternation) and
// so turns an alternation's BRANCH COUNT into native-stack recursion depth. A pattern is an
// ordinary MOO string arriving from any match()/rmatch()/substitute() call, bounded only by
// values.MAX_STR_LEN, so without this `"a%|" * 100000` segfaulted the process outright -- no
// error, no task abort, the whole server gone.
//
// This belongs to the same family as compiler.MAX_PARSE_DEPTH, objdb.MAX_VERB_DEPTH and
// values.MAX_VALUE_DEPTH, and is chosen the same way. Measured on a worker thread (where MOO
// tasks actually compile patterns, and whose stack is what matters): 20000 branches compile
// fine, 40000 segfault. 1000 is ~30x below that and far above anything real -- patterns in
// both bundled cores have single-digit branch counts, and even a pattern generated by joining
// a word list with `%|` has room for hundreds of words.
//
// Group nesting needs no separate ceiling: `%(` is already capped at 9 by MOO's group limit,
// so compile_atom can only add 9 levels on top of this.
@(private = "file")
MAX_ALT_DEPTH :: 1000

@(private = "file")
is_word_byte :: proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

@(private = "file")
emit :: proc(p: ^Parser, instr: Instr) -> int {
	append(&p.instrs, instr)
	return len(p.instrs) - 1
}

// emit_class emits a Class instruction for `set`, sharing its table entry with any identical
// set already in the pattern.
@(private = "file")
emit_class :: proc(p: ^Parser, set: Char_Set, negate: bool) {
	idx, seen := p.class_index[set]
	if !seen {
		idx = i32(len(p.classes))
		append(&p.classes, set)
		p.class_index[set] = idx
	}
	emit(p, Instr{op = .Class, x = idx, negate = negate})
}

// emit_loop_split emits a */+ loop-back Split and gives it the next loop-guard slot.
@(private = "file")
emit_loop_split :: proc(p: ^Parser) -> int {
	i := emit(p, Instr{op = .Split, is_loop = true, loop = i32(p.n_loops)})
	p.n_loops += 1
	return i
}

@(private = "file")
word_set :: proc() -> Char_Set {
	set: Char_Set
	for b in 0 ..< 256 {
		if is_word_byte(byte(b)) {
			set_add(&set, b)
		}
	}
	return set
}

// escape_needs_backslash mirrors pattern.c's translate_pattern() strchr set: these are the
// characters that become "special" (in our engine: their own opcode) when %-escaped.
// Everything else %-escaped just becomes that literal character (translate_pattern's
// no-backslash-added branch).
@(private = "file")
escape_needs_backslash :: proc(c: byte) -> bool {
	return strings.index_byte(".*+?[^$|()123456789bB<>wW", c) >= 0
}

// compile_alt/compile_concat/compile_quant/compile_atom implement the grammar (lowest to
// highest precedence): Alt := Concat ('%|' Concat)* ; Concat := Quant* ;
// Quant := Atom ('*'|'+'|'?')? ; Atom := '.' | '^' | '$' | class | '%(' Alt '%)' | char.
@(private = "file")
compile_alt :: proc(p: ^Parser) {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > MAX_ALT_DEPTH {
		p.ok = false // reported to the caller as an invalid pattern (E_INVARG), not a crash
		return
	}
	branch_start := len(p.instrs)
	compile_concat(p)
	if !p.ok || p.pos + 1 >= len(p.pat) || p.pat[p.pos] != '%' || p.pat[p.pos + 1] != '|' {
		return
	}
	// Rewrite as: split branch_start, L2; <branch1>; jmp End; L2: <rest-of-alt>; End:
	branch1 := p.instrs[branch_start:]
	saved := make([]Instr, len(branch1))
	copy(saved, branch1)
	resize(&p.instrs, branch_start)
	split_idx := emit(p, Instr{op = .Split})
	l1 := len(p.instrs)
	shift_body_targets(saved, i32(l1 - branch_start))
	append(&p.instrs, ..saved[:])
	delete(saved)
	jmp_idx := emit(p, Instr{op = .Jmp})
	l2 := len(p.instrs)
	p.pos += 2 // consume '%|'
	compile_alt(p)
	end := len(p.instrs)
	p.instrs[split_idx].x = i32(l1)
	p.instrs[split_idx].y = i32(l2)
	p.instrs[jmp_idx].x = i32(end)
}

@(private = "file")
compile_concat :: proc(p: ^Parser) {
	for p.ok && p.pos < len(p.pat) {
		if p.pat[p.pos] == '%' && p.pos + 1 < len(p.pat) && p.pat[p.pos + 1] == '|' {
			return // let compile_alt handle it
		}
		if p.pat[p.pos] == '%' && p.pos + 1 < len(p.pat) && p.pat[p.pos + 1] == ')' {
			return // end of an enclosing group, let its caller consume '%)'
		}
		compile_quant(p)
	}
}

@(private = "file")
compile_quant :: proc(p: ^Parser) {
	start := len(p.instrs)
	compile_atom(p)
	if !p.ok || p.pos >= len(p.pat) {
		return
	}
	switch p.pat[p.pos] {
	case '*':
		p.pos += 1
		wrap_star(p, start)
	case '+':
		p.pos += 1
		wrap_plus(p, start)
	case '?':
		p.pos += 1
		wrap_opt(p, start)
	}
}

// shift_body_targets fixes up a just-relocated instruction chunk's own internal Jmp/Split
// targets after it's been cut out and is about to be re-appended `delta` positions later than
// where it originally lived. Needed by every wrap_*/compile_alt call below that does this
// "copy a body out, emit a new control instruction in its old spot, re-append the body"
// splice: the body's own Jmp/Split targets are absolute PC indices computed relative to its
// ORIGINAL position, and inserting anything before it shifts everything after by `delta`.
// Without this, a body that itself already contains a compiled quantifier/group/alternation
// (i.e. any NESTED `*`/`+`/`?`/`%|`/`%(...%)` -- e.g. `%(a*%)*`) gets silently corrupted:
// its inner Split/Jmp instructions keep pointing at their pre-shift target indices, which
// after the shift may now be arbitrary OTHER instructions -- observed in practice as a Split
// whose target became itself, an infinite loop that crashed the process with a stack
// overflow (see Instr.is_loop's comment for the other half of that same bug report; that
// fix alone wasn't sufficient, since the real root cause was this corruption, not just
// unguarded recursion). `.Save`'s `x` is a capture-group SLOT number, not a PC, and must
// never be shifted; `.Char`/`.Class`/anchors don't have PC-valued fields at all.
@(private = "file")
shift_body_targets :: proc(body: []Instr, delta: i32) {
	for i in 0 ..< len(body) {
		#partial switch body[i].op {
		case .Jmp:
			body[i].x += delta
		case .Split:
			body[i].x += delta
			body[i].y += delta
		}
	}
}

// wrap_star/plus/opt splice quantifier control flow around an already-emitted atom's
// instructions (start..end). Greedy: Split always tries "consume" before "skip"/"stop".
@(private = "file")
wrap_star :: proc(p: ^Parser, start: int) {
	body := make([]Instr, len(p.instrs) - start)
	copy(body, p.instrs[start:])
	resize(&p.instrs, start)
	split_idx := emit_loop_split(p)
	body_start := len(p.instrs)
	shift_body_targets(body, i32(body_start - start))
	append(&p.instrs, ..body)
	delete(body)
	jmp_idx := emit(p, Instr{op = .Jmp, x = i32(split_idx)})
	after := len(p.instrs)
	p.instrs[split_idx].x = i32(body_start)
	p.instrs[split_idx].y = i32(after)
	_ = jmp_idx
}

@(private = "file")
wrap_plus :: proc(p: ^Parser, start: int) {
	// body; split body_start, after
	split_idx := emit_loop_split(p)
	after := len(p.instrs)
	p.instrs[split_idx].x = i32(start)
	p.instrs[split_idx].y = i32(after)
}

@(private = "file")
wrap_opt :: proc(p: ^Parser, start: int) {
	body := make([]Instr, len(p.instrs) - start)
	copy(body, p.instrs[start:])
	resize(&p.instrs, start)
	split_idx := emit(p, Instr{op = .Split})
	body_start := len(p.instrs)
	shift_body_targets(body, i32(body_start - start))
	append(&p.instrs, ..body)
	delete(body)
	after := len(p.instrs)
	p.instrs[split_idx].x = i32(body_start)
	p.instrs[split_idx].y = i32(after)
}

@(private = "file")
compile_class :: proc(p: ^Parser) {
	set: Char_Set
	negate := false
	p.pos += 1 // consume '['
	if p.pos < len(p.pat) && p.pat[p.pos] == '^' {
		negate = true
		p.pos += 1
	}
	first := true
	for p.pos < len(p.pat) && (p.pat[p.pos] != ']' || first) {
		first = false
		c := p.pat[p.pos]
		if p.pos + 2 < len(p.pat) && p.pat[p.pos + 1] == '-' && p.pat[p.pos + 2] != ']' {
			lo, hi := c, p.pat[p.pos + 2]
			for b := int(lo); b <= int(hi); b += 1 {
				set_add(&set, b)
			}
			p.pos += 3
		} else {
			set_add(&set, int(c))
			p.pos += 1
		}
	}
	if p.pos >= len(p.pat) {
		p.ok = false
		return
	}
	p.pos += 1 // consume ']'
	emit_class(p, set, negate)
}

@(private = "file")
compile_atom :: proc(p: ^Parser) {
	c := p.pat[p.pos]
	switch c {
	case '.':
		p.pos += 1
		emit(p, Instr{op = .Any})
	case '^':
		p.pos += 1
		emit(p, Instr{op = .Bol})
	case '$':
		p.pos += 1
		emit(p, Instr{op = .Eol})
	case '[':
		compile_class(p)
	case '%':
		p.pos += 1
		if p.pos >= len(p.pat) {
			p.ok = false
			return
		}
		e := p.pat[p.pos]
		p.pos += 1
		switch e {
		case '%':
			emit(p, Instr{op = .Char, c = '%'})
		case '(':
			p.ngroup += 1
			if p.ngroup > 9 {
				p.ok = false
				return
			}
			slot := p.ngroup
			emit(p, Instr{op = .Save, x = i32(2 * slot)})
			compile_alt(p)
			if !p.ok || p.pos + 1 >= len(p.pat) || p.pat[p.pos] != '%' || p.pat[p.pos + 1] != ')' {
				p.ok = false
				return
			}
			p.pos += 2
			emit(p, Instr{op = .Save, x = i32(2 * slot + 1)})
		case 'b':
			emit(p, Instr{op = .Wordb})
		case 'B':
			emit(p, Instr{op = .NWordb})
		case 'w':
			emit_class(p, word_set(), false)
		case 'W':
			emit_class(p, word_set(), true) // shares %w's table entry
		case:
			// Falls back to a literal (covers %.%*%+%?%[%^%$%)  and any unsupported escape
			// like in-pattern backreferences %1-%9, %<, %>, matching translate_pattern's own
			// no-backslash-needed fallback for anything outside its special-char set).
			emit(p, Instr{op = .Char, c = e})
		}
	case:
		p.pos += 1
		emit(p, Instr{op = .Char, c = c})
	}
}

// compile builds a Program from a MOO pattern; ok=false on a malformed pattern (unterminated
// group/class, more than 9 groups, trailing '%').
compile :: proc(pattern: string) -> (prog: Program, ok: bool) {
	p := Parser{pat = pattern, ok = true}
	defer delete(p.class_index)
	emit(&p, Instr{op = .Save, x = 0})
	compile_alt(&p)
	if p.ok && p.pos != len(pattern) {
		p.ok = false // e.g. a stray unmatched '%)' left unconsumed
	}
	if !p.ok {
		delete(p.instrs)
		delete(p.classes)
		return Program{}, false
	}
	emit(&p, Instr{op = .Save, x = 1})
	emit(&p, Instr{op = .Match})
	// Exact-length slices: shrink() drops the growth slack, which at these sizes is real memory.
	shrink(&p.instrs)
	shrink(&p.classes)
	return Program{instrs = p.instrs[:], classes = p.classes[:], n_loops = p.n_loops}, true
}

Match_Result :: struct {
	found:  bool,
	start:  int, // 0-based, inclusive
	end:    int, // 0-based, EXCLUSIVE (i.e. [start, end))
	groups: [9][2]int, // 0-based [start, end) per group; {-1, -1} if that group didn't participate
}

// Runner holds everything one match needs, including scratch that is reused across start
// positions rather than reallocated per attempt (match_pattern tries up to len(subject)+1 of
// them, so per-attempt allocation showed up as real work on long subjects).
@(private = "file")
Runner :: struct {
	prog:       ^Program,
	subject:    string,
	case_fold:  bool,
	steps:      int,
	max_steps:  int, // this call's step budget -- see match_pattern
	loop_entry: []int, // per loop-Split (Instr.loop): "pos we last entered it at" (see Instr.is_loop)
	// loop_stamp[pc] records WHICH attempt loop_entry[pc] was written during, so a new attempt
	// invalidates every entry by bumping one counter instead of rewriting the whole array.
	// That is not a micro-optimisation: runner_reset runs once per start position, so an O(len
	// (program)) clear there costs O(len(subject) x len(pattern)) per match() call and is
	// charged to NOTHING -- `steps` never sees it, so MAX_STEPS did not bound it. Measured
	// before this change: a 20KB pattern against a 200KB subject took 5.6 seconds inside one
	// built-in, one tick, big_lock held; 200KB x 1MB extrapolates to ~9 minutes. Same
	// server-wedge MAX_STEPS exists to prevent, just moved out of the step loop and into the
	// per-attempt setup. 0 means "never written" -- attempt numbering starts at 1.
	loop_stamp: []int,
	attempt:    int,
	choices:    [dynamic]Choice,
	undos:      [dynamic]Undo,
	saves:      [20]int,
}

@(private = "file")
runner_make :: proc(prog: ^Program, subject: string, case_fold: bool) -> Runner {
	return Runner {
		prog       = prog,
		subject    = subject,
		case_fold  = case_fold,
		max_steps  = MAX_STEPS,
		loop_entry = make([]int, prog.n_loops),
		loop_stamp = make([]int, prog.n_loops), // zeroed: no attempt has stamped anything yet
		choices    = make([dynamic]Choice, 0, 32),
		undos      = make([dynamic]Undo, 0, 16),
	}
}

@(private = "file")
runner_destroy :: proc(r: ^Runner) {
	delete(r.loop_entry)
	delete(r.loop_stamp)
	delete(r.choices)
	delete(r.undos)
}

// runner_reset clears the per-attempt state before trying a new start position.
//
// It deliberately does NOT reset `steps`. MAX_STEPS is a budget for one whole match() call, not
// for one start position: match_pattern tries every start position in the subject, so zeroing
// the counter here made the real ceiling len(subject) x MAX_STEPS. That is not a tighter-than-
// necessary limit, it is no limit at all -- a 2000-byte subject against `%(a*%)*b` took 52
// SECONDS, and an 8000-byte one had not finished after two minutes. The task budget cannot
// catch it either: budget_charge (vm/budget.odin) only runs between statements, so the whole
// call is one tick with big_lock held the entire time. Carrying the count across attempts puts
// the worst case back at MAX_STEPS total, which is milliseconds.
@(private = "file")
runner_reset :: proc(r: ^Runner) {
	// O(1), not O(len(program)) -- bumping the stamp invalidates every loop_entry at once.
	// See Runner.loop_stamp for the measured cost of clearing the array here instead.
	r.attempt += 1
	clear(&r.choices)
	clear(&r.undos)
	for i in 0 ..< len(r.saves) {
		r.saves[i] = -1
	}
}

// MAX_STEPS is the backtracking budget for one entire match()/rmatch()/substitute() call --
// see runner_reset for why "one call" rather than "one start position" is the load-bearing part.
@(private = "file")
MAX_STEPS :: 2_000_000

// MAX_BACKTRACK bounds how many pending alternatives run() will hold at once. Like MAX_STEPS
// it's a give-up-and-report-no-match valve for pathological inputs, bounding memory rather than
// time. MAX_STEPS already caps pushes implicitly (at most one per step); this is the explicit
// memory ceiling, ~24 MB of Choice entries at the limit.
@(private = "file")
MAX_BACKTRACK :: 1_000_000

@(private = "file")
byte_eq :: proc(r: ^Runner, a, b: byte) -> bool {
	if !r.case_fold {
		return a == b
	}
	fa, fb := a, b
	if fa >= 'A' && fa <= 'Z' {
		fa += 32
	}
	if fb >= 'A' && fb <= 'Z' {
		fb += 32
	}
	return fa == fb
}

// Choice is one pending alternative: the branch of a Split that run() didn't take, to be
// resumed if the branch it did take fails. `undo_top` records how tall the Save-undo journal
// was at the time, so backtracking knows exactly which capture writes to roll back.
@(private = "file")
Choice :: struct {
	pc:       int,
	pos:      int,
	undo_top: int,
}

// Undo is one entry in the capture-write journal: the slot a Save overwrote and what was in it
// before. Journalling individual writes (rather than snapshotting all 20 save slots per choice
// point) keeps a Choice down to a handful of words, which matters because a greedy quantifier
// pushes one per character it consumes.
@(private = "file")
Undo :: struct {
	slot: int,
	old:  int,
}

// run executes the compiled program from (pc, pos), backtracking through Split alternatives
// until something reaches Match or the alternatives run out. Capture positions land in
// r.saves.
//
// This is an explicit loop over an explicit stack of alternatives, NOT the recursive tree-walk
// it reads most naturally as. That matters: a recursive matcher recurses once per character
// consumed, so matching something as ordinary as `a*b` against a few thousand characters
// overflowed the native stack and took the whole server down with it (measured: ~7000
// characters was enough). MOO code runs match() against mail bodies, note text and help
// entries, so "a few thousand characters" is an ordinary input, not an attack. Moving that
// growth onto the heap makes it bounded (MAX_BACKTRACK) and recoverable -- a pathological
// pattern reports no-match instead of killing the process.
@(private = "file")
run :: proc(r: ^Runner, start_pc: int, start_pos: int) -> (end: int, ok: bool) {
	pc, pos := start_pc, start_pos
	for {
		r.steps += 1
		if r.steps > r.max_steps {
			return 0, false
		}
		instr := r.prog.instrs[pc]

		// Each case either advances (pc/pos) and `continue`s, or falls through to the single
		// backtrack step at the bottom of the loop.
		switch instr.op {
		case .Char:
			if pos < len(r.subject) && byte_eq(r, r.subject[pos], instr.c) {
				pc += 1
				pos += 1
				continue
			}
		case .Any:
			if pos < len(r.subject) {
				pc += 1
				pos += 1
				continue
			}
		case .Class:
			if pos < len(r.subject) {
				c := r.subject[pos]
				set := r.prog.classes[instr.x]
				member := set_has(set, c)
				if !member && r.case_fold {
					alt := c
					if alt >= 'a' && alt <= 'z' {
						alt -= 32
					} else if alt >= 'A' && alt <= 'Z' {
						alt += 32
					}
					member = set_has(set, alt)
				}
				if member != instr.negate {
					pc += 1
					pos += 1
					continue
				}
			}
		case .Bol:
			if pos == 0 {
				pc += 1
				continue
			}
		case .Eol:
			if pos == len(r.subject) {
				pc += 1
				continue
			}
		case .Wordb, .NWordb:
			before := pos > 0 && is_word_byte(r.subject[pos - 1])
			after := pos < len(r.subject) && is_word_byte(r.subject[pos])
			boundary := before != after
			if boundary == (instr.op == .Wordb) {
				pc += 1
				continue
			}
		case .Jmp:
			pc = int(instr.x)
			continue
		case .Split:
			if instr.is_loop {
				// Refuse to re-enter this loop's body at the exact position we last entered it
				// at -- a body that matches zero-width would otherwise spin here forever (see
				// Instr.is_loop). Entering at a NEW position is genuine progress, always allowed.
				if r.loop_stamp[instr.loop] == r.attempt && r.loop_entry[instr.loop] == pos {
					pc = int(instr.y)
					continue
				}
				r.loop_stamp[instr.loop] = r.attempt
				r.loop_entry[instr.loop] = pos
			}
			if len(r.choices) >= MAX_BACKTRACK {
				return 0, false
			}
			append(&r.choices, Choice{pc = int(instr.y), pos = pos, undo_top = len(r.undos)})
			pc = int(instr.x)
			continue
		case .Save:
			append(&r.undos, Undo{slot = int(instr.x), old = r.saves[instr.x]})
			r.saves[instr.x] = pos
			pc += 1
			continue
		case .Match:
			return pos, true
		}

		// This path failed -- roll back to the most recent untried alternative, undoing any
		// capture writes made since it was recorded, or give up if there are none left.
		if len(r.choices) == 0 {
			return 0, false
		}
		choice := pop(&r.choices)
		for len(r.undos) > choice.undo_top {
			u := pop(&r.undos)
			r.saves[u.slot] = u.old
		}
		pc, pos = choice.pc, choice.pos
	}
}

// match_attempt tries to match starting EXACTLY at `start` (no scanning) -- the primitive both
// forward and reverse scanning share. Reuses `r`'s scratch buffers; resets per-attempt state.
@(private = "file")
match_attempt :: proc(r: ^Runner, start: int) -> (Match_Result, bool) {
	runner_reset(r)
	_, ok := run(r, 0, start)
	if !ok {
		return Match_Result{}, false
	}
	res := Match_Result{found = true, start = r.saves[0], end = r.saves[1]}
	for g in 1 ..= 9 {
		res.groups[g - 1] = [2]int{r.saves[2 * g], r.saves[2 * g + 1]}
	}
	return res, true
}

// ATTEMPT_STEPS is how many steps each start position adds to a call's budget.
//
// MAX_STEPS alone bounds a call's total work, which is right for backtracking but wrong for
// scanning: every start position costs at least a step or two even when it fails at once, so a
// long enough subject used up the whole budget just LOOKING, and a match far enough in was
// reported as no match -- `match("a" * 1100000 + "b", "b")` found nothing, where 900000 worked.
// Adding a few steps per position makes the scan itself free while keeping the total bounded
// by the input -- MAX_STEPS + ATTEMPT_STEPS x len(subject), linear, which is the requirement a
// built-in has to meet. Patterns that begin with a literal skip non-starting positions outright
// (first_byte), so they don't spend even that.
@(private = "file")
ATTEMPT_STEPS :: 8

// first_byte reports the byte every match must start with, when the pattern begins with a
// literal (after its leading group Saves) -- the common case, and one that lets the scan skip
// positions without running the program at all.
@(private = "file")
first_byte :: proc(prog: ^Program) -> (c: byte, ok: bool) {
	for instr in prog.instrs {
		#partial switch instr.op {
		case .Save:
			continue
		case .Char:
			return instr.c, true
		}
		return 0, false
	}
	return 0, false
}

// match_pattern searches for the first (reverse=false) or last (reverse=true) match
// anywhere in `subject`, ported from pattern.c's match_pattern()/re_search() driving loop
// (which tries every start position since this VM, like the original, isn't anchored by
// default -- MOO patterns opt into anchoring themselves via `^`/`$`).
match_pattern :: proc(prog: ^Program, subject: string, reverse: bool, case_fold: bool) -> Match_Result {
	r := runner_make(prog, subject, case_fold)
	defer runner_destroy(&r)
	r.max_steps = MAX_STEPS + ATTEMPT_STEPS * (len(subject) + 1)
	lead, has_lead := first_byte(prog)
	can_start :: proc(r: ^Runner, start: int, lead: byte) -> bool {
		return start < len(r.subject) && byte_eq(r, r.subject[start], lead)
	}
	// Once the step budget is gone every remaining attempt can only report "no match", so stop
	// scanning rather than paying for len(subject) more of them.
	if !reverse {
		for start := 0; start <= len(subject) && r.steps <= r.max_steps; start += 1 {
			if has_lead && !can_start(&r, start, lead) {
				continue
			}
			if res, ok := match_attempt(&r, start); ok {
				return res
			}
		}
	} else {
		for start := len(subject); start >= 0 && r.steps <= r.max_steps; start -= 1 {
			if has_lead && !can_start(&r, start, lead) {
				continue
			}
			if res, ok := match_attempt(&r, start); ok {
				return res
			}
		}
	}
	return Match_Result{}
}
