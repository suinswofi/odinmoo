package moo_ansi

// ANSI color support -- a feature the original LambdaMOO server never had at all (plain
// text only). Two markup mini-languages are supported side by side:
//
//   - `%`-codes: %r/%g/%y/%b/%m/%c/%w for foreground, %R/%G/%Y/%B/%M/%C/%W for background,
//     %h for bold/high-intensity (a modifier that applies to the NEXT color code, not
//     standalone), %n for normal/reset, %% for a literal percent sign. The convention long
//     established by other enhanced MU* cores (PennMUSH, TinyMUX, and others).
//   - `|NN`-codes: classic BBS-door/pipe-code markup (PCBoard/Renegade/Synchronet
//     convention), `|` followed by exactly two digits: `|00`-`|15` set the foreground to one
//     of the 16 standard colors (dark 00-07, bright 08-15, same hue pairs -- e.g. |00/|08 are
//     both "black-family", the bright one is dark grey), `|16`-`|23` set the background to
//     one of the 8 non-bright colors, `|24`-`|31` set the background to the bright version of
//     those same 8 hues (this MOO's own extension -- the classic convention stops at |23,
//     since real BBS-door displays never had bright backgrounds). Unlike %h, there's no
//     separate bright modifier -- brightness is baked into which code you pick.
//   - `|DF`/`|DB` (case-insensitive): reset the foreground/background to the connecting
//     terminal's own default color -- NOT a specific color like white or black, genuinely
//     "whatever this user's terminal is configured to show," so it looks right regardless of
//     whether they're on a light or dark theme. This is also this MOO's own extension: SGR 39
//     (default fg) and SGR 49 (default bg) exist in real ANSI but the classic pipe-code set
//     has no code for them. Deliberately separate from `%n` (full reset -- also clears bold
//     and whichever OTHER color you didn't just set): `|15Hi |DFthere` resets only the
//     foreground, leaving any background color from an earlier `|1X`/`|2X`/`|DB` alone.
//
//     None of these markup styles auto-reset: a color set by any of them stays in effect
//     (both across the string and, once sent to a real terminal, across subsequent lines)
//     until an explicit reset (`%n`/`|DF`/`|DB`) or another color code changes it -- exactly
//     matching how real ANSI SGR state behaves, so this needs no extra bookkeeping here.
//
// Verb authors (and the server's own system messages) write these directly in ordinary
// strings; translate() turns them into real ANSI SGR escape sequences, or strips them to
// plain text for a connection that doesn't want color.
//
// This package has no dependency on values/vm/dbfile -- pure string transforms only -- so
// both netio (the output choke point) and builtins (ansi_strip/ansi_len/ansify, for verb
// code to use directly) can depend on it without any risk of a cycle.

import "core:fmt"
import "core:strings"

ESC :: "\x1b["

@(private = "file")
fg_codes := [?]struct {
	code:  byte,
	param: string,
}{
	{'x', "30"}, {'r', "31"}, {'g', "32"}, {'y', "33"},
	{'b', "34"}, {'m', "35"}, {'c', "36"}, {'w', "37"},
}

@(private = "file")
bg_codes := [?]struct {
	code:  byte,
	param: string,
}{
	{'X', "40"}, {'R', "41"}, {'G', "42"}, {'Y', "43"},
	{'B', "44"}, {'M', "45"}, {'C', "46"}, {'W', "47"},
}

@(private = "file")
find_fg :: proc(c: byte) -> (param: string, ok: bool) {
	for e in fg_codes {
		if e.code == c {
			return e.param, true
		}
	}
	return "", false
}

@(private = "file")
find_bg :: proc(c: byte) -> (param: string, ok: bool) {
	for e in bg_codes {
		if e.code == c {
			return e.param, true
		}
	}
	return "", false
}

// pipe_fg_sgr: |00-|15 -> SGR param. Indices 0-7 are the standard (dark) colors (30-37);
// 8-15 are the same 8 hues again but bright, via the aixterm high-intensity range (90-97)
// rather than the "1;3Xm" bold-plus-color form %h uses -- aixterm codes are just as widely
// supported and don't carry %h's side effect of also making the glyph itself heavier-weight
// in some terminal emulators, which would be a mismatch for a code whose only stated meaning
// is "this specific one of 16 colors."
@(private = "file")
pipe_fg_sgr := [16]string{
	"30", "34", "32", "36", "31", "35", "33", "37", // 00-07: black,blue,green,cyan,red,magenta,brown,grey
	"90", "94", "92", "96", "91", "95", "93", "97", // 08-15: bright versions of the same 8
}

// pipe_bg_sgr: |16-|23 -> SGR param (40-47), the 8 standard-intensity backgrounds.
@(private = "file")
pipe_bg_sgr := [8]string{
	"40", "44", "42", "46", "41", "45", "43", "47", // 16-23: black,blue,green,cyan,red,magenta,brown,grey
}

// pipe_bg_bright_sgr: |24-|31 -> SGR param, the bright version of the same 8 background
// hues, via the aixterm high-intensity background range (100-107) -- this MOO's own
// extension to the classic pipe-code set, same hue order as pipe_bg_sgr.
@(private = "file")
pipe_bg_bright_sgr := [8]string{
	"100", "104", "102", "106", "101", "105", "103", "107", // 24-31: black,blue,green,cyan,red,magenta,brown(yellow),grey(white)
}

// Sentinel values parse_pipe_code returns for `|DF`/`|DB` -- outside the 0-31 real-color
// range, so emit_pipe_code can tell them apart from an actual table index.
@(private = "file")
PIPE_DEFAULT_FG :: -1
@(private = "file")
PIPE_DEFAULT_BG :: -2

// parse_pipe_code recognizes a pipe-code sequence at the start of s: either `|NN` (NN = two
// decimal digits, 00-31) or `|DF`/`|DB` (case-insensitive, default-foreground/background
// reset). Returns the parsed value (a 0-31 table index, or a PIPE_DEFAULT_* sentinel), how
// many bytes it occupies (always 3: `|` + 2 more), and ok. Anything else -- `|` at end of
// string, `|` followed by fewer than two characters, digits outside 00-31, or two letters
// that aren't "DF"/"DB" -- is NOT a pipe code and falls through to being treated as a literal
// `|`, the same graceful-degradation policy the %-code handler already uses for an
// unrecognized `%X`.
@(private = "file")
parse_pipe_code :: proc(s: string) -> (n: int, consumed: int, ok: bool) {
	if len(s) < 3 {
		return 0, 0, false
	}
	c1, c2 := s[1], s[2]
	if c1 == 'D' || c1 == 'd' {
		switch c2 {
		case 'F', 'f':
			return PIPE_DEFAULT_FG, 3, true
		case 'B', 'b':
			return PIPE_DEFAULT_BG, 3, true
		}
		return 0, 0, false
	}
	if c1 < '0' || c1 > '9' || c2 < '0' || c2 > '9' {
		return 0, 0, false
	}
	n = int(c1-'0')*10 + int(c2-'0')
	if n > 31 {
		return 0, 0, false
	}
	return n, 3, true
}

@(private = "file")
emit_pipe_code :: proc(b: ^strings.Builder, n: int, enable: bool) {
	if !enable {
		return
	}
	switch {
	case n == PIPE_DEFAULT_FG:
		strings.write_string(b, ESC + "39m")
	case n == PIPE_DEFAULT_BG:
		strings.write_string(b, ESC + "49m")
	case n < 16:
		fmt.sbprintf(b, "%s%sm", ESC, pipe_fg_sgr[n])
	case n < 24:
		fmt.sbprintf(b, "%s%sm", ESC, pipe_bg_sgr[n - 16])
	case:
		fmt.sbprintf(b, "%s%sm", ESC, pipe_bg_bright_sgr[n - 24])
	}
}

// translate ports the %-code mini-language into real ANSI SGR escapes when enable is true,
// or strips the codes to plain text when false (for a connection/context that doesn't want
// color -- degrades gracefully rather than sending raw escape sequences to a dumb client).
// An unrecognized `%X` is passed through literally rather than silently eaten, so ordinary
// text containing a stray `%` followed by punctuation isn't mangled.
translate :: proc(s: string, enable: bool) -> string {
	b := strings.builder_make()
	bright := false
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '|' {
			if n, consumed, ok := parse_pipe_code(s[i:]); ok {
				emit_pipe_code(&b, n, enable)
				i += consumed
				continue
			}
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		if c != '%' || i + 1 >= len(s) {
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		code := s[i + 1]
		i += 2
		switch code {
		case '%':
			strings.write_byte(&b, '%')
		case 'n':
			bright = false
			if enable {
				strings.write_string(&b, ESC + "0m")
			}
		case 'h':
			bright = true // modifies the next color code only; nothing emitted here
		case:
			if fg, fg_ok := find_fg(code); fg_ok {
				if enable {
					if bright {
						fmt.sbprintf(&b, "%s1;%sm", ESC, fg)
					} else {
						fmt.sbprintf(&b, "%s%sm", ESC, fg)
					}
				}
				bright = false
			} else if bg, bg_ok := find_bg(code); bg_ok {
				if enable {
					fmt.sbprintf(&b, "%s%sm", ESC, bg)
				}
			} else {
				strings.write_byte(&b, '%')
				strings.write_byte(&b, code)
			}
		}
	}
	return strings.to_string(b)
}

// strip removes %-codes (source markup form), returning plain text -- equivalent to
// translate(s, false), named separately since it's the common direct use (the ansi_strip()
// builtin), not "translate with color disabled".
strip :: proc(s: string) -> string {
	return translate(s, false)
}

// strip_escapes removes real "\x1b[...m" ANSI escape sequences (the already-translated
// form), as opposed to strip()'s %-code markup form.
strip_escapes :: proc(s: string) -> string {
	b := strings.builder_make()
	i := 0
	for i < len(s) {
		if s[i] == 0x1b && i + 1 < len(s) && s[i + 1] == '[' {
			j := i + 2
			for j < len(s) && s[j] != 'm' {
				j += 1
			}
			i = j + 1
			continue
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

// visible_len returns the display width of s, ignoring both %-code markup and real ANSI
// escapes -- whichever form the caller has -- useful for column alignment/padding.
visible_len :: proc(s: string) -> int {
	no_codes := strip(s)
	defer delete(no_codes)
	no_escapes := strip_escapes(no_codes)
	defer delete(no_escapes)
	return len(no_escapes)
}
