package moo_ansi

// ANSI color support -- a feature the original LambdaMOO server never had at all (plain
// text only). Uses a %-code markup mini-language, the convention long established by other
// enhanced MU* cores (PennMUSH, TinyMUX, and others): %r/%g/%y/%b/%m/%c/%w for foreground
// colors, %R/%G/%Y/%B/%M/%C/%W for background, %h for bold/high-intensity (a modifier that
// applies to the NEXT color code, not standalone), %n for normal/reset, %% for a literal
// percent sign. Verb authors (and the server's own system messages) write these directly in
// ordinary strings; translate() turns them into real ANSI SGR escape sequences, or strips
// them to plain text for a connection that doesn't want color.
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
