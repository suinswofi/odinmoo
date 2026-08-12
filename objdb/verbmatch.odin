package objdb

// Verb-name matching, ported from utils.c's verbcasecmp(). A Verbdef's `name` field can
// hold several space-separated aliases, each optionally containing one `*` marking the
// minimum-abbreviation point: "l*ook" matches "l", "lo", "loo", or "look"; a trailing bare
// "*" (e.g. "foo*") allows any length suffix from that point on; no `*` requires an exact
// (case-insensitive) match. This is a direct port, not a reimplementation from the
// documented behavior -- the original's char-by-char state machine has edge cases (a `*`
// not at the end of an alias, e.g. "fo*obar") that are easy to get subtly wrong by
// reasoning from the spec alone.

@(private = "file")
Star_State :: enum {
	None,
	Inner,
	End,
}

@(private = "file")
lower :: proc(b: byte) -> byte {
	if b >= 'A' && b <= 'Z' {
		return b + 32
	}
	return b
}

verb_name_matches :: proc(verb_names: string, query: string) -> bool {
	v := verb_names
	vi := 0
	for vi < len(v) {
		wi := 0
		star := Star_State.None
		for {
			for vi < len(v) && v[vi] == '*' {
				vi += 1
				star = (vi >= len(v) || v[vi] == ' ') ? .End : .Inner
			}
			v_end := vi >= len(v) || v[vi] == ' '
			w_end := wi >= len(query)
			if v_end || w_end || lower(query[wi]) != lower(v[vi]) {
				break
			}
			wi += 1
			vi += 1
		}

		w_end := wi >= len(query)
		matched: bool
		if w_end {
			matched = star != .None || vi >= len(v) || v[vi] == ' '
		} else {
			matched = star == .End
		}
		if matched {
			return true
		}

		for vi < len(v) && v[vi] != ' ' {
			vi += 1
		}
		for vi < len(v) && v[vi] == ' ' {
			vi += 1
		}
	}
	return false
}
