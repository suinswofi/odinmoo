package compiler

// Lexer, ported from parser.y's yylex(). The original reads from a callback (`lex_getc`)
// because its source can be either an in-memory Stream or a live DB-file stream (see
// db_io.c's my_getc, which turns a lone "." line into EOF); here the whole verb source is
// already an owned string by the time it reaches the compiler (dbfile handed us
// Verbdef.program_source), so the lexer just scans a string directly -- same token stream,
// simpler plumbing.

import "../values"
import "core:fmt"
import "core:strconv"
import "core:strings"

Lexer :: struct {
	src:     string,
	pos:     int,
	line:    int,
	version: int,
	errors:  [dynamic]string, // ported from yyerror()'s accumulation via the client callback
}

lexer_make :: proc(src: string, version: int) -> Lexer {
	return Lexer{src = src, pos = 0, line = 1, version = version}
}

lexer_destroy :: proc(l: ^Lexer) {
	delete(l.errors)
}

@(private = "file")
peek_byte :: proc(l: ^Lexer, offset: int = 0) -> (b: byte, ok: bool) {
	p := l.pos + offset
	if p >= len(l.src) {
		return 0, false
	}
	return l.src[p], true
}

@(private = "file")
advance :: proc(l: ^Lexer) -> (b: byte, ok: bool) {
	b, ok = peek_byte(l)
	if !ok {
		return 0, false
	}
	l.pos += 1
	if b == '\n' {
		l.line += 1
	}
	return b, true
}

@(private = "file")
is_digit :: proc(b: byte) -> bool {return b >= '0' && b <= '9'}
@(private = "file")
is_alpha :: proc(b: byte) -> bool {return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_'}
@(private = "file")
is_alnum :: proc(b: byte) -> bool {return is_alpha(b) || is_digit(b)}
@(private = "file")
is_space :: proc(b: byte) -> bool {return b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\v' || b == '\f'}
@(private = "file")
lower :: proc(b: byte) -> byte {return b >= 'A' && b <= 'Z' ? b + 32 : b}

@(private = "file")
lex_error :: proc(l: ^Lexer, msg: string) {
	append(&l.errors, fmt.aprintfln("Line %d:  %s", l.line, msg))
}

// next_token ports yylex() body-for-body: skip whitespace/comments, then dispatch on the
// first significant character.
next_token :: proc(l: ^Lexer) -> Token {
	for {
		b, ok := peek_byte(l)
		if !ok {
			return Token{kind = .EOF, line = l.line}
		}
		if is_space(b) {
			advance(l)
			continue
		}
		if b == '/' {
			if b2, ok2 := peek_byte(l, 1); ok2 && b2 == '*' {
				advance(l)
				advance(l)
				skip_block_comment(l)
				continue
			}
		}
		break
	}

	start_line := l.line
	b, _ := peek_byte(l)

	if b == '#' {
		return lex_object(l, start_line)
	}
	if is_digit(b) || (b == '.' && l.version >= DBV_Float) {
		if tok, is_num := try_lex_number(l, start_line); is_num {
			return tok
		}
		// Fell through: lone '.' with no digits before or after -- not a number.
	}
	if is_alpha(b) {
		return lex_identifier_or_keyword(l, start_line)
	}
	if b == '"' {
		return lex_string(l, start_line)
	}

	advance(l)
	switch b {
	case '>':
		return follow(l, '=', Token{kind = .Ge, line = start_line}, Token{kind = .Gt, line = start_line})
	case '<':
		return follow(l, '=', Token{kind = .Le, line = start_line}, Token{kind = .Lt, line = start_line})
	case '=':
		if nb, nok := peek_byte(l); nok && nb == '=' {
			advance(l)
			return Token{kind = .Eq, line = start_line}
		}
		if nb, nok := peek_byte(l); nok && nb == '>' {
			advance(l)
			return Token{kind = .Arrow, line = start_line}
		}
		return Token{kind = .Assign, line = start_line}
	case '!':
		return follow(l, '=', Token{kind = .Ne, line = start_line}, Token{kind = .Bang, line = start_line})
	case '|':
		return follow(l, '|', Token{kind = .Or, line = start_line}, Token{kind = .Pipe, line = start_line})
	case '&':
		return follow(l, '&', Token{kind = .And, line = start_line}, Token{kind = .EOF, line = start_line}) // bare '&' is a syntax error, same as the original (no grammar rule consumes it)
	case '.':
		return follow(l, '.', Token{kind = .To, line = start_line}, Token{kind = .Dot, line = start_line})
	case '+':
		return Token{kind = .Plus, line = start_line}
	case '-':
		return Token{kind = .Minus, line = start_line}
	case '*':
		return Token{kind = .Star, line = start_line}
	case '/':
		return Token{kind = .Slash, line = start_line}
	case '%':
		return Token{kind = .Percent, line = start_line}
	case '^':
		return Token{kind = .Caret, line = start_line}
	case '?':
		return Token{kind = .Question, line = start_line}
	case '[':
		return Token{kind = .LBracket, line = start_line}
	case ']':
		return Token{kind = .RBracket, line = start_line}
	case '{':
		return Token{kind = .LBrace, line = start_line}
	case '}':
		return Token{kind = .RBrace, line = start_line}
	case '(':
		return Token{kind = .LParen, line = start_line}
	case ')':
		return Token{kind = .RParen, line = start_line}
	case ',':
		return Token{kind = .Comma, line = start_line}
	case ';':
		return Token{kind = .Semi, line = start_line}
	case ':':
		return Token{kind = .Colon, line = start_line}
	case '$':
		return Token{kind = .Dollar, line = start_line}
	case '@':
		return Token{kind = .At, line = start_line}
	case '`':
		return Token{kind = .Backtick, line = start_line}
	case '\'':
		return Token{kind = .Quote, line = start_line}
	}
	lex_error(l, "Unexpected character")
	return next_token(l)
}

@(private = "file")
follow :: proc(l: ^Lexer, expect: byte, if_yes, if_no: Token) -> Token {
	if b, ok := peek_byte(l); ok && b == expect {
		advance(l)
		return if_yes
	}
	return if_no
}

@(private = "file")
skip_block_comment :: proc(l: ^Lexer) {
	for {
		b, ok := advance(l)
		if !ok {
			lex_error(l, "End of program while in a comment")
			return
		}
		if b == '*' {
			b2, ok2 := peek_byte(l)
			if ok2 && b2 == '/' {
				advance(l)
				return
			}
		}
	}
}

@(private = "file")
lex_object :: proc(l: ^Lexer, line: int) -> Token {
	advance(l) // '#'
	negative := false
	if b, ok := peek_byte(l); ok && b == '-' {
		negative = true
		advance(l)
	}
	b, ok := peek_byte(l)
	if !ok || !is_digit(b) {
		lex_error(l, "Malformed object number")
		return Token{kind = .EOF, line = line}
	}
	start := l.pos
	for {
		bb, bok := peek_byte(l)
		if !bok || !is_digit(bb) {
			break
		}
		advance(l)
	}
	n, _ := strconv.parse_int(l.src[start:l.pos], 10)
	if negative {
		n = -n
	}
	return Token{kind = .Object, line = line, obj_val = values.Objid(n)}
}

// try_lex_number ports the digit-or-dot branch of yylex(), including its float/`..`
// disambiguation: after consuming leading digits, a `.` is only part of a float literal if
// followed by another digit (otherwise it might be the `..` range operator or a bare `.`
// property-access dot, so we back off and let the caller re-lex it as punctuation).
try_lex_number :: proc(l: ^Lexer, line: int) -> (tok: Token, ok: bool) {
	start := l.pos
	saw_digit := false
	for {
		b, bok := peek_byte(l)
		if !bok || !is_digit(b) {
			break
		}
		advance(l)
		saw_digit = true
	}

	is_float := false
	if l.version >= DBV_Float {
		if b, bok := peek_byte(l); bok && b == '.' {
			if b2, b2ok := peek_byte(l, 1); b2ok && is_digit(b2) {
				is_float = true
				advance(l) // '.'
				for {
					bb, bbok := peek_byte(l)
					if !bbok || !is_digit(bb) {
						break
					}
					advance(l)
				}
			} else if !saw_digit {
				// No digits before or after '.': not a number at all (e.g. bare "..").
				l.pos = start
				return Token{}, false
			}
			// else: digits before the dot but not after and next isn't another '.' --
			// original still treats a trailing lone '.' after digits as a float ("5.");
			// mirrored by falling through without consuming the dot here, then handled
			// by the exponent check below only applying to what we've consumed so far.
		}
		if !saw_digit {
			return Token{}, false
		}
		if b, bok := peek_byte(l); bok && (b == 'e' || b == 'E') {
			save := l.pos
			advance(l)
			if sb, sok := peek_byte(l); sok && (sb == '+' || sb == '-') {
				advance(l)
			}
			if eb, eok := peek_byte(l); eok && is_digit(eb) {
				is_float = true
				for {
					bb, bbok := peek_byte(l)
					if !bbok || !is_digit(bb) {
						break
					}
					advance(l)
				}
			} else {
				lex_error(l, "Malformed floating-point literal")
				l.pos = save
			}
		}
	} else if !saw_digit {
		return Token{}, false
	}

	text := l.src[start:l.pos]
	if is_float {
		f, fok := strconv.parse_f64(text)
		if !fok || !values_is_real(f) {
			lex_error(l, "Floating-point literal out of range")
			f = 0
		}
		return Token{kind = .Float, line = line, float_val = f}, true
	}
	n, _ := strconv.parse_int(text, 10)
	return Token{kind = .Int, line = line, int_val = i32(n)}, true
}

@(private = "file")
values_is_real :: proc(f: f64) -> bool {
	// Ports my-math.h's IS_REAL(x): (-DBL_MAX <= x && x <= DBL_MAX). NaN compares false
	// against everything, so this rejects NaN too without a separate check.
	return f >= -max(f64) && f <= max(f64)
}

@(private = "file")
lex_identifier_or_keyword :: proc(l: ^Lexer, line: int) -> Token {
	start := l.pos
	for {
		b, ok := peek_byte(l)
		if !ok || !is_alnum(b) {
			break
		}
		advance(l)
	}
	text := l.src[start:l.pos]

	// Keyword lookup is CASE-INSENSITIVE, matching the original exactly: keywords.c's
	// gperf-generated hash and comparison both tolower() every character, so `If`, `WHILE`,
	// `e_perm`, and lowercase `any` are all keywords in real MOO source. (A previous version
	// used a case-sensitive map lookup here, silently turning any non-canonically-cased
	// keyword into an identifier.)
	lower_buf: [16]byte // longest keyword is "endwhile"/"E_RECMOVE" (9 chars)
	if len(text) <= len(lower_buf) {
		for i in 0 ..< len(text) {
			lower_buf[i] = lower(text[i])
		}
		if kw, found := keywords[string(lower_buf[:len(text)])]; found && kw.version <= l.version {
			if kw.kind == .Error {
				return Token{kind = .Error, line = line, err_val = kw.err}
			}
			return Token{kind = kw.kind, line = line}
		}
	}
	return Token{kind = .Id, line = line, str_val = strings.clone(text)}
}

// lex_string ports the '"'-delimited branch: backslash escapes the *next character
// literally* (not C-style escape codes -- `\n` is a literal `n`, not a newline; only
// `\"` and `\\` behave as most authors expect, incidentally).
@(private = "file")
lex_string :: proc(l: ^Lexer, line: int) -> Token {
	advance(l) // opening quote
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for {
		c, ok := advance(l)
		if !ok || c == '\n' {
			lex_error(l, "Missing quote")
			break
		}
		if c == '"' {
			break
		}
		if c == '\\' {
			c2, ok2 := advance(l)
			if !ok2 || c2 == '\n' {
				lex_error(l, "Missing quote")
				break
			}
			c = c2
		}
		strings.write_byte(&b, c)
	}
	return Token{kind = .String, line = line, str_val = strings.clone(strings.to_string(b))}
}
