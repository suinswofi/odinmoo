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

Op :: enum {
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

Instr :: struct {
	op:      Op,
	c:       byte, // Char
	set:     ^[256]bool, // Class; owned
	negate:  bool, // Class
	x, y:    int, // Jmp target (x); Split targets (x, y); Save slot (x)
	is_loop: bool, // Split only: true for */+'s loop-back split (wrap_star/wrap_plus) --
	// tells run() to guard against infinite recursion when the loop body matches zero
	// width (e.g. `%(a*%)*`): without this, a body that matches empty re-enters the same
	// Split at the same position forever, which is unbounded RECURSION DEPTH (not just
	// unbounded work) and crashes the process with a stack overflow before MAX_STEPS is
	// ever reached. Not set for compile_alt's alternation split or wrap_opt's `?` split,
	// neither of which loop back to themselves.
}

Program :: struct {
	instrs: []Instr,
}

program_destroy :: proc(p: ^Program) {
	for instr in p.instrs {
		if instr.set != nil {
			free(instr.set)
		}
	}
	delete(p.instrs)
}

@(private = "file")
Parser :: struct {
	pat:   string,
	pos:   int,
	instrs: [dynamic]Instr,
	ngroup: int,
	ok:    bool,
}

@(private = "file")
is_word_byte :: proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

@(private = "file")
emit :: proc(p: ^Parser, instr: Instr) -> int {
	append(&p.instrs, instr)
	return len(p.instrs) - 1
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
	shift_body_targets(saved, l1 - branch_start)
	append(&p.instrs, ..saved[:])
	delete(saved)
	jmp_idx := emit(p, Instr{op = .Jmp})
	l2 := len(p.instrs)
	p.pos += 2 // consume '%|'
	compile_alt(p)
	end := len(p.instrs)
	p.instrs[split_idx].x = l1
	p.instrs[split_idx].y = l2
	p.instrs[jmp_idx].x = end
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
shift_body_targets :: proc(body: []Instr, delta: int) {
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
	split_idx := emit(p, Instr{op = .Split, is_loop = true})
	body_start := len(p.instrs)
	shift_body_targets(body, body_start - start)
	append(&p.instrs, ..body)
	delete(body)
	jmp_idx := emit(p, Instr{op = .Jmp, x = split_idx})
	after := len(p.instrs)
	p.instrs[split_idx].x = body_start
	p.instrs[split_idx].y = after
	_ = jmp_idx
}

@(private = "file")
wrap_plus :: proc(p: ^Parser, start: int) {
	// body; split body_start, after
	split_idx := emit(p, Instr{op = .Split, is_loop = true})
	after := len(p.instrs)
	p.instrs[split_idx].x = start
	p.instrs[split_idx].y = after
}

@(private = "file")
wrap_opt :: proc(p: ^Parser, start: int) {
	body := make([]Instr, len(p.instrs) - start)
	copy(body, p.instrs[start:])
	resize(&p.instrs, start)
	split_idx := emit(p, Instr{op = .Split})
	body_start := len(p.instrs)
	shift_body_targets(body, body_start - start)
	append(&p.instrs, ..body)
	delete(body)
	after := len(p.instrs)
	p.instrs[split_idx].x = body_start
	p.instrs[split_idx].y = after
}

@(private = "file")
compile_class :: proc(p: ^Parser) {
	set := new([256]bool)
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
				set[b] = true
			}
			p.pos += 3
		} else {
			set[c] = true
			p.pos += 1
		}
	}
	if p.pos >= len(p.pat) {
		p.ok = false
		free(set)
		return
	}
	p.pos += 1 // consume ']'
	emit(p, Instr{op = .Class, set = set, negate = negate})
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
			emit(p, Instr{op = .Save, x = 2 * slot})
			compile_alt(p)
			if !p.ok || p.pos + 1 >= len(p.pat) || p.pat[p.pos] != '%' || p.pat[p.pos + 1] != ')' {
				p.ok = false
				return
			}
			p.pos += 2
			emit(p, Instr{op = .Save, x = 2 * slot + 1})
		case 'b':
			emit(p, Instr{op = .Wordb})
		case 'B':
			emit(p, Instr{op = .NWordb})
		case 'w':
			set := new([256]bool)
			for b in 0 ..< 256 {
				set[b] = is_word_byte(byte(b))
			}
			emit(p, Instr{op = .Class, set = set})
		case 'W':
			set := new([256]bool)
			for b in 0 ..< 256 {
				set[b] = is_word_byte(byte(b))
			}
			emit(p, Instr{op = .Class, set = set, negate = true})
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
	emit(&p, Instr{op = .Save, x = 0})
	compile_alt(&p)
	if p.ok && p.pos != len(pattern) {
		p.ok = false // e.g. a stray unmatched '%)' left unconsumed
	}
	if !p.ok {
		for instr in p.instrs {
			if instr.set != nil {
				free(instr.set)
			}
		}
		delete(p.instrs)
		return Program{}, false
	}
	emit(&p, Instr{op = .Save, x = 1})
	emit(&p, Instr{op = .Match})
	return Program{instrs = p.instrs[:]}, true
}

Match_Result :: struct {
	found:  bool,
	start:  int, // 0-based, inclusive
	end:    int, // 0-based, EXCLUSIVE (i.e. [start, end))
	groups: [9][2]int, // 0-based [start, end) per group; {-1, -1} if that group didn't participate
}

@(private = "file")
Runner :: struct {
	prog:       ^Program,
	subject:    string,
	case_fold:  bool,
	steps:      int,
	loop_entry: []int, // per-pc "pos we last entered this loop-Split at" (see Instr.is_loop); -1 = never
}

@(private = "file")
MAX_STEPS :: 2_000_000 // backtracking budget: bounds pathological patterns instead of hanging

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

@(private = "file")
run :: proc(r: ^Runner, pc: int, pos: int, saves: ^[20]int) -> (end: int, ok: bool) {
	r.steps += 1
	if r.steps > MAX_STEPS {
		return 0, false
	}
	instr := r.prog.instrs[pc]
	switch instr.op {
	case .Char:
		if pos < len(r.subject) && byte_eq(r, r.subject[pos], instr.c) {
			return run(r, pc + 1, pos + 1, saves)
		}
		return 0, false
	case .Any:
		if pos < len(r.subject) {
			return run(r, pc + 1, pos + 1, saves)
		}
		return 0, false
	case .Class:
		if pos < len(r.subject) {
			c := r.subject[pos]
			member := instr.set[c]
			if !member && r.case_fold {
				alt := c
				if alt >= 'a' && alt <= 'z' {
					alt -= 32
				} else if alt >= 'A' && alt <= 'Z' {
					alt += 32
				}
				member = instr.set[alt]
			}
			if member != instr.negate {
				return run(r, pc + 1, pos + 1, saves)
			}
		}
		return 0, false
	case .Bol:
		if pos == 0 {
			return run(r, pc + 1, pos, saves)
		}
		return 0, false
	case .Eol:
		if pos == len(r.subject) {
			return run(r, pc + 1, pos, saves)
		}
		return 0, false
	case .Wordb, .NWordb:
		before := pos > 0 && is_word_byte(r.subject[pos - 1])
		after := pos < len(r.subject) && is_word_byte(r.subject[pos])
		boundary := before != after
		if boundary == (instr.op == .Wordb) {
			return run(r, pc + 1, pos, saves)
		}
		return 0, false
	case .Jmp:
		return run(r, instr.x, pos, saves)
	case .Split:
		if instr.is_loop {
			// Refuse to re-enter this loop's body at the exact position we last entered it
			// at -- a body that matches zero-width would otherwise recurse into this same
			// Split forever (see Instr.is_loop's comment). Entering at a NEW (necessarily
			// larger, since matching only ever consumes forward) position is genuine
			// progress and is always allowed.
			if r.loop_entry[pc] == pos {
				return run(r, instr.y, pos, saves)
			}
			r.loop_entry[pc] = pos
		}
		if end, ok := run(r, instr.x, pos, saves); ok {
			return end, ok
		}
		return run(r, instr.y, pos, saves)
	case .Save:
		old := saves[instr.x]
		saves[instr.x] = pos
		end, ok := run(r, pc + 1, pos, saves)
		if !ok {
			saves[instr.x] = old
		}
		return end, ok
	case .Match:
		return pos, true
	}
	return 0, false
}

// match_at tries to match starting EXACTLY at `start` (no scanning) -- the primitive both
// match_pattern (which scans start forward) and rmatch (which scans start backward) share.
@(private = "file")
match_at :: proc(prog: ^Program, subject: string, start: int, case_fold: bool) -> (Match_Result, bool) {
	loop_entry := make([]int, len(prog.instrs))
	defer delete(loop_entry)
	for i in 0 ..< len(loop_entry) {
		loop_entry[i] = -1
	}
	r := Runner{prog = prog, subject = subject, case_fold = case_fold, loop_entry = loop_entry}
	saves: [20]int
	for i in 0 ..< 20 {
		saves[i] = -1
	}
	end, ok := run(&r, 0, start, &saves)
	if !ok {
		return Match_Result{}, false
	}
	res := Match_Result{found = true, start = saves[0], end = saves[1]}
	for g in 1 ..= 9 {
		res.groups[g - 1] = [2]int{saves[2 * g], saves[2 * g + 1]}
	}
	return res, true
}

// match_pattern searches for the first (reverse=false) or last (reverse=true) match
// anywhere in `subject`, ported from pattern.c's match_pattern()/re_search() driving loop
// (which tries every start position since this VM, like the original, isn't anchored by
// default -- MOO patterns opt into anchoring themselves via `^`/`$`).
match_pattern :: proc(prog: ^Program, subject: string, reverse: bool, case_fold: bool) -> Match_Result {
	if !reverse {
		for start := 0; start <= len(subject); start += 1 {
			if res, ok := match_at(prog, subject, start, case_fold); ok {
				return res
			}
		}
	} else {
		for start := len(subject); start >= 0; start -= 1 {
			if res, ok := match_at(prog, subject, start, case_fold); ok {
				return res
			}
		}
	}
	return Match_Result{}
}
