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

strings_equal_fold :: proc(a, b: string) -> bool {
	return strings.equal_fold(a, b)
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
ascii_index_fold :: proc(haystack, needle: string) -> int {
	if len(needle) == 0 {
		return 0
	}
	if len(needle) > len(haystack) {
		return -1
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
