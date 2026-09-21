package values

// String helpers for MOO's case-insensitive-by-default string semantics.
//
// The `*_fold` procedures here fold only ASCII A-Z, and deliberately so, for two reasons.
// First, fidelity: MOO's own comparisons are byte-oriented (utils.c's mystrcasecmp and
// friends), so Unicode-aware case folding would make this port disagree with the original on
// non-ASCII text. Second, and the reason they exist as their own procedures rather than calls
// into core:strings: folding via strings.to_lower() means allocating a lowercased copy of both
// operands on every comparison, and these run on genuinely hot paths -- every `<`/`>` between
// strings, every index()/rindex()/strsub() call, all of which real verb code does inside loops.
// Those copies used to go to context.temp_allocator, which is a growing arena that is only
// reclaimed by an explicit free_all: in a server that stays up for months, "allocate two copies
// per string comparison and never reclaim them" is unbounded growth. Folding in place costs
// nothing and removes the question entirely.

import "core:strings"

clone_string :: proc(s: string) -> string {
	return strings.clone(s)
}

// strings_equal_fold is the ASCII-only case-insensitive comparison the header above promises.
// It used to delegate to core:strings.equal_fold, which quietly broke both halves of that
// promise: that routine decodes RUNES and applies Unicode simple folding, so "K" (U+212A,
// KELVIN SIGN) compared equal to "k" -- and, far worse, every byte that is not valid UTF-8
// decodes to U+FFFD, so any two distinct invalid bytes compared EQUAL. Measured before this
// change: "\xc3" == "\xc4" was true, and so was "\xff\xfe" == "\xfe\xff".
//
// MOO strings are byte strings, and the original compares them with utils.c's mystrcasecmp,
// which folds ASCII A-Z and nothing else. This is not a theoretical difference: this proc
// backs the `==`/`!=` operators, `in`, and case-insensitive is_member, so two genuinely
// different strings tested equal, and it backs object-name and alias matching in
// objdb/command.odin, where the strings come straight from player input.
strings_equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if ascii_lower(a[i]) != ascii_lower(b[i]) {
			return false
		}
	}
	return true
}

ascii_lower :: proc(b: byte) -> byte {
	return b + 32 if b >= 'A' && b <= 'Z' else b
}

// ascii_compare_fold returns <0, 0 or >0 like strings.compare, comparing ASCII-folded bytes;
// on a common prefix the shorter string sorts first.
ascii_compare_fold :: proc(a, b: string) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		ca, cb := ascii_lower(a[i]), ascii_lower(b[i])
		if ca != cb {
			return -1 if ca < cb else 1
		}
	}
	if len(a) == len(b) {
		return 0
	}
	return -1 if len(a) < len(b) else 1
}

ascii_has_prefix_fold :: proc(s, prefix: string) -> bool {
	if len(prefix) > len(s) {
		return false
	}
	for i in 0 ..< len(prefix) {
		if ascii_lower(s[i]) != ascii_lower(prefix[i]) {
			return false
		}
	}
	return true
}

// ascii_index_fold returns the 0-based index of the first ASCII-case-insensitive occurrence of
// `needle` in `haystack`, or -1. An empty needle matches at 0, and ascii_last_index_fold's
// empty needle matches at len(haystack) -- the same answers core:strings gives, which MOO code
// genuinely depends on (LambdaCore's $site_db trie insert relies on index(s, "") == 1).
//
// Both of these used to be a plain scan: try the needle at every start position, skipping the
// ones whose first byte disagrees. That is O(len(haystack) * len(needle)), and both inputs are
// capped only by values.MAX_STR_LEN, so it is the "bounded by its inputs is not the same as
// small" trap CLAUDE.md describes -- a product of two capped inputs. index() is case-folding by
// DEFAULT in MOO, so this was the ordinary path, not a corner: measured on `index(h, n)` with a
// haystack of 'a'*n and a needle of 'a'*(m-1)+'b', which defeats the first-byte skip,
//
//	haystack   needle    time
//	  100000    50000    1.8s
//	  400000   200000     29s
//	 1000000   500000    179s
//
// and at MAX_STR_LEN that extrapolates to about twelve HOURS. All of it inside one built-in,
// holding big_lock, charging two ticks -- a tick is charged between statements (vm/budget.odin)
// so neither the tick count nor the wall-clock deadline is reachable while one built-in runs,
// and kill_task() only reaches suspended tasks. That is a dead server from one `index()` call
// any player who can run MOO code can make, which is exactly what the regex engine's per-call
// step budget exists to stop happening there.
//
// The answer here is not a ceiling like regex.MAX_STEPS, though: substring search has a
// genuinely linear algorithm, so the cost can be removed instead of rejected, and every call
// that works today keeps working. Long needles go through Knuth-Morris-Pratt, which is
// worst-case O(len(haystack) + len(needle)) with no input that degrades it. Deliberately NOT
// Rabin-Karp, which is what core:strings.index uses: its linearity is only EXPECTED, and the
// rolling hash is a linear function of the bytes over a 32-bit modulus, so a caller who picks
// the needle and the haystack -- which is precisely the caller this is being hardened against
// -- can solve for a needle that collides with every window and force the verification step to
// run at all n positions, putting the quadratic right back.
//
// Short needles keep the straightforward path -- the scan below for the folding pair,
// core:strings for the case-sensitive one. KMP needs a table proportional to the needle, and
// the hot-path callers in real verb code (index(line, " "), $string_utils in loops) pass
// needles of a few bytes, where one allocation per call would cost more than the search does;
// the header at the top of this file explains why this file avoids per-call allocation. Below
// this threshold the worst case either way is bounded by SHORT_NEEDLE * len(haystack), which is
// linear in the haystack and about 0.2s at MAX_STR_LEN -- a bound, not a cliff.
@(private = "file")
SHORT_NEEDLE :: 16

// fold_byte applies ASCII folding or doesn't, so one KMP implementation serves both the
// case-folding built-ins and the case-sensitive ones.
@(private = "file")
fold_byte :: proc(b: byte, fold: bool) -> byte {
	return ascii_lower(b) if fold else b
}

// kmp_table builds the KMP failure function: table[i] is the length of the longest proper
// prefix of needle[:i+1] that is also a suffix of it.
@(private = "file")
kmp_table :: proc(needle: string, fold: bool) -> []i32 {
	table := make([]i32, len(needle))
	k: int = 0
	for i in 1 ..< len(needle) {
		c := fold_byte(needle[i], fold)
		for k > 0 && fold_byte(needle[k], fold) != c {
			k = int(table[k - 1])
		}
		if fold_byte(needle[k], fold) == c {
			k += 1
		}
		table[i] = i32(k)
	}
	return table
}

// kmp_scan walks the haystack once, never backing up. With want_last it keeps going after a
// match and reports the last start position rather than the first -- which is how the
// last_index variants are served without a second, mirror-image implementation. Resuming from
// table[k-1] rather than from zero is what lets overlapping occurrences still be found, so the
// answer matches the straightforward scan's on every input.
@(private = "file")
kmp_scan :: proc(haystack, needle: string, fold: bool, want_last: bool) -> int {
	table := kmp_table(needle, fold)
	defer delete(table)
	m := len(needle)
	best := -1
	k := 0
	for i in 0 ..< len(haystack) {
		c := fold_byte(haystack[i], fold)
		for k > 0 && fold_byte(needle[k], fold) != c {
			k = int(table[k - 1])
		}
		if fold_byte(needle[k], fold) == c {
			k += 1
		}
		if k == m {
			start := i - m + 1
			if !want_last {
				return start
			}
			best = start
			k = int(table[k - 1])
		}
	}
	return best
}

// ascii_index / ascii_last_index are the case-SENSITIVE pair, and they exist for the same
// reason the folding ones were rewritten. core:strings.index and last_index are Rabin-Karp,
// which is only EXPECTED linear: the rolling hash is a linear function of the bytes over a
// 32-bit modulus, so a caller who chooses both strings can solve for a needle that collides
// with every window and force the O(len(needle)) verification at all n positions. `index(s, t,
// 1)` hands a MOO player exactly that choice, so the case-sensitive path would have kept the
// worst case the folding path just lost. Short needles still go to core:strings, where the
// verification a collision costs is bounded by the same small constant the scan below is.
ascii_index :: proc(haystack, needle: string) -> int {
	if len(needle) > SHORT_NEEDLE && len(needle) <= len(haystack) {
		return kmp_scan(haystack, needle, false, false)
	}
	return strings.index(haystack, needle)
}

ascii_last_index :: proc(haystack, needle: string) -> int {
	if len(needle) > SHORT_NEEDLE && len(needle) <= len(haystack) {
		return kmp_scan(haystack, needle, false, true)
	}
	return strings.last_index(haystack, needle)
}

ascii_index_fold :: proc(haystack, needle: string) -> int {
	if len(needle) == 0 {
		return 0
	}
	if len(needle) > len(haystack) {
		return -1
	}
	if len(needle) > SHORT_NEEDLE {
		return kmp_scan(haystack, needle, true, false)
	}
	first := ascii_lower(needle[0])
	for start in 0 ..= len(haystack) - len(needle) {
		if ascii_lower(haystack[start]) != first {
			continue
		}
		if ascii_has_prefix_fold(haystack[start:], needle) {
			return start
		}
	}
	return -1
}

ascii_last_index_fold :: proc(haystack, needle: string) -> int {
	if len(needle) == 0 {
		return len(haystack)
	}
	if len(needle) > len(haystack) {
		return -1
	}
	if len(needle) > SHORT_NEEDLE {
		return kmp_scan(haystack, needle, true, true)
	}
	first := ascii_lower(needle[0])
	for start := len(haystack) - len(needle); start >= 0; start -= 1 {
		if ascii_lower(haystack[start]) != first {
			continue
		}
		if ascii_has_prefix_fold(haystack[start:], needle) {
			return start
		}
	}
	return -1
}
