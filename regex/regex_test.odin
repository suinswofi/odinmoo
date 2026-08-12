package regex

import "core:strings"
import "core:testing"

@(test)
test_literal_match :: proc(t: ^testing.T) {
	prog, ok := compile("hello")
	defer program_destroy(&prog)
	testing.expect(t, ok)
	res := match_pattern(&prog, "say hello world", false, true)
	testing.expect(t, res.found)
	testing.expect(t, res.start == 4 && res.end == 9)
}

@(test)
test_star_plus_opt :: proc(t: ^testing.T) {
	prog, ok := compile("ab*c")
	defer program_destroy(&prog)
	testing.expect(t, ok)
	res := match_pattern(&prog, "xxacyy", false, true)
	testing.expect(t, res.found && res.start == 2 && res.end == 4)

	prog2, ok2 := compile("ab+c")
	defer program_destroy(&prog2)
	testing.expect(t, ok2)
	res2 := match_pattern(&prog2, "xxacyy", false, true)
	testing.expect(t, !res2.found) // b+ requires at least one b

	prog3, ok3 := compile("ab?c")
	defer program_destroy(&prog3)
	testing.expect(t, ok3)
	res3 := match_pattern(&prog3, "xxabbcyy", false, true)
	testing.expect(t, !res3.found) // two b's, ab?c doesn't match "abbc"
	res3b := match_pattern(&prog3, "xxabcyy", false, true)
	testing.expect(t, res3b.found)
}

@(test)
test_class :: proc(t: ^testing.T) {
	prog, ok := compile("[a-z]+")
	defer program_destroy(&prog)
	testing.expect(t, ok)
	// case_fold=false here: with case-insensitive matching (MOO's match() default), the
	// greedy `+` would also consume "XYZ" (folds to lowercase, still in [a-z]) -- that's
	// correct behavior, just not what this particular assertion wants to isolate.
	res := match_pattern(&prog, "123abcXYZ", false, false)
	testing.expect(t, res.found && res.start == 3 && res.end == 6)

	prog2, ok2 := compile("[^, ]+")
	defer program_destroy(&prog2)
	testing.expect(t, ok2)
	res2 := match_pattern(&prog2, ", hello, world", false, true)
	testing.expect(t, res2.found && res2.start == 2 && res2.end == 7) // "hello"
}

@(test)
test_group_capture_values :: proc(t: ^testing.T) {
	prog, ok := compile("^.* %(from%|to%) %([^, ]+%)")
	defer program_destroy(&prog)
	testing.expect(t, ok)

	subject := "127.0.0.1 port 12345 to 5.6.7.8"
	res := match_pattern(&prog, subject, false, true)
	testing.expect(t, res.found)
	g1 := res.groups[0]
	g2 := res.groups[1]
	testing.expectf(t, g1[0] >= 0 && subject[g1[0]:g1[1]] == "to", "group1=%q", g1[0] >= 0 ? subject[g1[0]:g1[1]] : "<unset>")
	testing.expectf(t, g2[0] >= 0 && subject[g2[0]:g2[1]] == "5.6.7.8", "group2=%q", g2[0] >= 0 ? subject[g2[0]:g2[1]] : "<unset>")
}

@(test)
test_no_match_returns_not_found :: proc(t: ^testing.T) {
	prog, ok := compile("xyz")
	defer program_destroy(&prog)
	testing.expect(t, ok)
	res := match_pattern(&prog, "abcdef", false, true)
	testing.expect(t, !res.found)
}

@(test)
test_reverse_match :: proc(t: ^testing.T) {
	prog, ok := compile("[0-9]+")
	defer program_destroy(&prog)
	testing.expect(t, ok)
	subject := "a1 b22 c333"
	fwd := match_pattern(&prog, subject, false, true)
	testing.expect(t, fwd.found && subject[fwd.start:fwd.end] == "1")
	// Reverse search tries successive START positions from the end backward and returns the
	// first (rightmost) one that matches -- ports pattern.c's is_reverse re_search call
	// exactly (start=len(subject), range=-len(subject)). For an unanchored `+`, the
	// rightmost start position that can match at all is the last digit itself (nothing
	// after it to extend into), so this is "3", not the whole trailing run "333".
	rev := match_pattern(&prog, subject, true, true)
	testing.expect(t, rev.found && subject[rev.start:rev.end] == "3" && rev.start == len(subject) - 1)
}

@(test)
test_case_fold :: proc(t: ^testing.T) {
	prog, ok := compile("hello")
	defer program_destroy(&prog)
	testing.expect(t, ok)
	res := match_pattern(&prog, "HELLO world", false, true)
	testing.expect(t, res.found)
	res2 := match_pattern(&prog, "HELLO world", false, false)
	testing.expect(t, !res2.found)
}

@(test)
test_anchors :: proc(t: ^testing.T) {
	prog, ok := compile("^abc$")
	defer program_destroy(&prog)
	testing.expect(t, ok)
	testing.expect(t, match_pattern(&prog, "abc", false, true).found)
	testing.expect(t, !match_pattern(&prog, "xabc", false, true).found)
	testing.expect(t, !match_pattern(&prog, "abcx", false, true).found)
}

// test_nested_star_zero_width_does_not_crash regression-tests a real crash found while
// exercising a real LambdaCore.db command (@create's own argument-parsing verb code): a
// pattern like `%(a*%)*` -- a star wrapped around a group that can itself match zero-width --
// used to recurse into the same loop Split forever (each empty iteration re-entering the
// Split at the same position, never returning), overflowing the stack. See Instr.is_loop's
// comment for the fix (a per-pc "did we already enter this loop at this exact position"
// guard in run()'s .Split case).
@(test)
test_nested_star_zero_width_does_not_crash :: proc(t: ^testing.T) {
	prog, ok := compile("%(a*%)*b")
	defer program_destroy(&prog)
	testing.expect(t, ok)
	res := match_pattern(&prog, "aaab", false, true)
	testing.expect(t, res.found)
	testing.expect(t, res.start == 0 && res.end == 4)

	// Also exercise it against a string with NO 'a's at all -- the star's body matches
	// empty on the very first attempt, which is exactly the pathological case.
	res2 := match_pattern(&prog, "b", false, true)
	testing.expect(t, res2.found)
	testing.expect(t, res2.start == 0 && res2.end == 1)

	// A doubly-nested version, for good measure.
	prog2, ok2 := compile("%(%(a*%)*%)*b")
	defer program_destroy(&prog2)
	testing.expect(t, ok2)
	res3 := match_pattern(&prog2, "aaab", false, true)
	testing.expect(t, res3.found)
}

@(test)
test_malformed_pattern_fails_to_compile :: proc(t: ^testing.T) {
	_, ok := compile("%(unterminated")
	testing.expect(t, !ok)

	_, ok2 := compile("[unterminated")
	testing.expect(t, !ok2)
}

// test_long_subject_does_not_overflow_the_stack is a crash regression test. run() used to
// recurse once per character consumed, so an entirely ordinary pattern over a few thousand
// characters overflowed the native stack -- measured at roughly 7000 characters for `a*b`,
// which is smaller than a typical mail message or help entry, i.e. reachable by accident
// rather than only by attack. Sizes here are well past that threshold in both the
// matches-eventually and never-matches directions.
@(test)
test_long_subject_does_not_overflow_the_stack :: proc(t: ^testing.T) {
	prog, ok := compile("a*b")
	defer program_destroy(&prog)
	testing.expect(t, ok)

	// 100k a's followed by a b: the greedy star has to consume the whole run and match.
	run_of_as := strings.repeat("a", 100_000)
	defer delete(run_of_as)
	matching := strings.concatenate({run_of_as, "b"})
	defer delete(matching)
	res := match_pattern(&prog, matching, false, true)
	testing.expect(t, res.found)
	testing.expect(t, res.start == 0 && res.end == 100_001)

	// a's and no b: every start position fails, which is what drove the deepest recursion
	// before. Kept well past the ~7000 crash threshold but modest, since this case costs one
	// full scan per start position. The budget valves (MAX_STEPS/MAX_BACKTRACK) may report
	// no-match rather than exhaustively proving it; either way it must return, not die.
	non_matching := strings.repeat("a", 12_000)
	defer delete(non_matching)
	res2 := match_pattern(&prog, non_matching, false, true)
	testing.expect(t, !res2.found)
}

// test_long_subject_with_groups_reports_correct_offsets checks that the explicit backtrack
// stack restores capture-group state correctly when it unwinds -- the recursive version undid
// each Save individually on the way out, the loop restores a snapshot at each choice point, and
// those have to agree.
@(test)
test_long_subject_with_groups_reports_correct_offsets :: proc(t: ^testing.T) {
	prog, ok := compile("%(a*%)%(b+%)c")
	defer program_destroy(&prog)
	testing.expect(t, ok)

	as := strings.repeat("a", 5_000)
	defer delete(as)
	subject := strings.concatenate({as, "bbb", "c"})
	defer delete(subject)
	res := match_pattern(&prog, subject, false, true)
	testing.expect(t, res.found)
	testing.expect(t, res.start == 0 && res.end == 5_004)
	testing.expect(t, res.groups[0] == [2]int{0, 5_000})
	testing.expect(t, res.groups[1] == [2]int{5_000, 5_003})
}
