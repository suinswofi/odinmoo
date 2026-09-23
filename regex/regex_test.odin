package regex

import "core:strings"
import "core:testing"
import "core:time"

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

// MAX_STEPS is a budget for one whole match() call, not for one start position. When
// runner_reset zeroed it per attempt, the real ceiling was len(subject) x MAX_STEPS and a
// catastrophically-backtracking pattern took 52 SECONDS on a 2000-byte subject -- one tick, with
// big_lock held. A length-scaling timing test would be flaky, so this pins the property that
// makes the timing impossible instead: work must not scale with the subject once the budget is
// spent. Both subjects below exhaust it; if the counter is reset per attempt, the second takes
// ~8x the first and the assertion on their ratio fails.
@(test)
test_step_budget_is_per_call_not_per_start_position :: proc(t: ^testing.T) {
	pattern :: "%(a*%)*b"
	elapsed :: proc(subject_len: int) -> time.Duration {
		prog, ok := compile(pattern)
		defer program_destroy(&prog)
		if !ok {
			return 0
		}
		subject := strings.repeat("a", subject_len)
		defer delete(subject)
		start := time.tick_now()
		res := match_pattern(&prog, subject, false, true)
		_ = res
		return time.tick_since(start)
	}
	// Deliberately small. Both lengths exhaust the budget, so with the fix both cost the same
	// (~one MAX_STEPS run); without it the longer one pays that cost once per start position.
	// Kept small so a regression FAILS in seconds rather than hanging the suite.
	short := elapsed(25)
	long := elapsed(200)
	// 8x the subject must not mean ~8x the work. Generous factor so this can't flake on a
	// loaded machine while still failing loudly on a per-attempt reset.
	testing.expectf(
		t,
		long < short * 4 + 50 * time.Millisecond,
		"work scaled with subject length: 25 bytes took %v, 200 bytes took %v -- MAX_STEPS is being reset per start position rather than per call",
		short,
		long,
	)
}

// ---- Regression: pattern compilation must not recurse without a ceiling ----
//
// compile_alt recurses once per `%|` branch, so an alternation's branch count was a native
// stack depth chosen by whoever supplied the pattern -- and a pattern is an ordinary MOO string
// reaching here from any match()/rmatch()/substitute() call. Measured before MAX_ALT_DEPTH, on
// a worker thread (which is where MOO tasks compile patterns): 20000 branches fine, 40000
// segfault, taking the whole server with them.
@(test)
test_alternation_depth_is_bounded :: proc(t: ^testing.T) {
	// Comfortably inside MAX_ALT_DEPTH: must still compile.
	ok_pat := strings.repeat("a%|", 900)
	defer delete(ok_pat)
	p1, ok1 := compile(ok_pat)
	testing.expect(t, ok1)
	if ok1 {
		program_destroy(&p1)
	}

	// Far past it: must be REJECTED as an invalid pattern (E_INVARG at the built-in), not
	// crash. This call is the regression -- it used to be a segfault, not a false return.
	big := strings.repeat("a%|", 50_000)
	defer delete(big)
	p2, ok2 := compile(big)
	testing.expect(t, !ok2)
	if ok2 {
		program_destroy(&p2)
	}
}

// ---- Regression: the per-call step budget must actually bound a whole match() ----
//
// runner_reset used to clear an O(len(program)) array once per start position, and `steps`
// never counted that work -- so one match() cost O(len(subject) x len(pattern)) with nothing
// bounding it. Measured before the stamp-based reset: a 20KB pattern against a 200KB subject
// took 5.6 seconds inside a single built-in, charged one tick, holding big_lock throughout;
// the sizes below took ~1.1s. Afterwards this is milliseconds. The threshold is loose on
// purpose -- this asks "does it still scale", not "how fast is it".
@(test)
test_large_pattern_scan_stays_bounded :: proc(t: ^testing.T) {
	pat := strings.repeat("a", 20_000)
	defer delete(pat)
	subject := strings.repeat("b", 20_000)
	defer delete(subject)
	prog, ok := compile(pat)
	testing.expect(t, ok)
	defer program_destroy(&prog)

	start := time.tick_now()
	res := match_pattern(&prog, subject, false, true)
	elapsed := time.duration_seconds(time.tick_since(start))
	testing.expect(t, !res.found)
	testing.expectf(t, elapsed < 0.5, "scan took %.3fs -- the per-attempt reset is O(program) again", elapsed)
}

// The zero-width-loop guard is now keyed by (attempt, position) rather than cleared between
// attempts, so check a stale stamp from an earlier start position can neither hang the next
// attempt nor make it miss a real match.
@(test)
test_zero_width_loop_guard_spans_attempts :: proc(t: ^testing.T) {
	prog, ok := compile("%(a*%)*b")
	testing.expect(t, ok)
	defer program_destroy(&prog)

	miss := match_pattern(&prog, "aaaa", false, true)
	testing.expect(t, !miss.found)

	hit := match_pattern(&prog, "aaab", false, true)
	testing.expectf(t, hit.found && hit.end == 4, "got %v", hit)

	// A match that can only be found at a LATER start position is the case a stale stamp
	// would break.
	late := match_pattern(&prog, "xxxaaab", false, true)
	testing.expectf(t, late.found && late.start == 3 && late.end == 7, "got %v", late)
}

// ---- Regression: a long subject no longer exhausts the step budget just by scanning ----
//
// MAX_STEPS was the whole call's budget, and every start position costs a step or two even when
// it fails at once, so a match more than about a million bytes in was reported as no match.
// Each position now adds ATTEMPT_STEPS to the budget, and literal-first patterns skip
// positions without running at all. Both paths are covered: "b" (literal first) and "[b]"
// (a class, so every position really is attempted), forwards and in reverse.
@(test)
test_match_far_into_a_long_subject :: proc(t: ^testing.T) {
	subject := strings.concatenate({strings.repeat("a", 3_000_000, context.temp_allocator), "b"}, context.temp_allocator)
	for pat in ([]string{"b", "[b]", "%(b%)", "[^a]"}) {
		prog, ok := compile(pat)
		defer program_destroy(&prog)
		testing.expect(t, ok)
		fwd := match_pattern(&prog, subject, false, true)
		testing.expectf(t, fwd.found && fwd.start == 3_000_000, "%s forward: %v", pat, fwd.found)
		rev := match_pattern(&prog, subject, true, true)
		testing.expectf(t, rev.found && rev.start == 3_000_000, "%s reverse: %v", pat, rev.found)
	}
	// Case folding still applies to the literal-first skip.
	prog, _ := compile("B")
	defer program_destroy(&prog)
	testing.expect(t, match_pattern(&prog, subject, false, true).found)
	testing.expect(t, !match_pattern(&prog, subject, false, false).found)
}

// ---- Regression: character classes are shared, and %w/%W still mean opposite things ----
@(test)
test_class_table_is_shared :: proc(t: ^testing.T) {
	prog, ok := compile("%w%W[a-z][a-z]%w")
	defer program_destroy(&prog)
	testing.expect(t, ok)
	testing.expect_value(t, len(prog.classes), 2) // one word set, one [a-z]
	res := match_pattern(&prog, "!! x.ab9 ", false, false)
	testing.expect(t, res.found && res.start == 3 && res.end == 8)
	testing.expect_value(t, size_of(Instr), 16)
}
