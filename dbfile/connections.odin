package dbfile

// Active-connections trailer, ported from server.c's read_active_connections(). Present
// only in a live checkpoint (a client-visible list of who was connected when the snapshot
// was taken, so they can be reconnected to the same object on restart); absent entirely in
// an older-format or freshly-authored DB, which the original tolerates by treating EOF here
// as "no connections" rather than an error -- ported the same way below.

import "../values"
import "core:strconv"
import "core:strings"

read_active_connections :: proc(r: ^Reader, db: ^Database) -> Read_Error {
	if reader_at_eof(r) {
		return .None
	}
	line, lerr := read_line(r)
	if lerr != .None {
		return .None // EOF here means "older database format", per the original
	}

	sp := strings.index_byte(line, ' ')
	if sp < 0 {
		return .Bad_Format
	}
	n, ok := strconv.parse_int(line[:sp], 10)
	if !ok {
		return .Bad_Format
	}

	have_listeners: bool
	switch line[sp + 1:] {
	case "active connections with listeners":
		have_listeners = true
	case "active connections":
		have_listeners = false
	case:
		return .Bad_Format
	}

	for _ in 0 ..< n {
		if have_listeners {
			pair_line, plerr := read_line(r)
			if plerr != .None {
				return plerr
			}
			fields := strings.split(pair_line, " ")
			defer delete(fields)
			if len(fields) != 2 {
				return .Bad_Format
			}
			who_n, ok1 := strconv.parse_int(fields[0], 10)
			listener_n, ok2 := strconv.parse_int(fields[1], 10)
			if !ok1 || !ok2 {
				return .Bad_Format
			}
			append(&db.connections, Connection_Record{who = values.Objid(who_n), listener = values.Objid(listener_n)})
		} else {
			who, werr := read_num(r)
			if werr != .None {
				return werr
			}
			append(&db.connections, Connection_Record{who = values.Objid(who), listener = values.SYSTEM_OBJECT})
		}
	}
	return .None
}
