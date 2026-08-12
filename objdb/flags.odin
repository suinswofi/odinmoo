package objdb

// Object/property/verb flag bits and the shared permission-check pattern, ported from
// db.h's db_object_flag/db_prop_flag/db_verb_flag enums and db_properties.c's
// db_property_allows()/db_verbs.c's db_verb_allows() (both the same rule: the flag is set,
// or the programmer owns the item, or the programmer is a wizard).

import "../dbfile"
import "../values"

// Object_Flag bit positions match db.h's db_object_flag exactly -- they're stored as a raw
// int on disk (Object.flags from dbfile), so the ordering is DB-accessible knowledge.
Object_Flag :: enum {
	User       = 0,
	Programmer = 1,
	Wizard     = 2,
	// Obsolete_1 = 3
	Read    = 4,
	Write   = 5,
	// Obsolete_2 = 6
	Fertile = 7,
}

Prop_Flag :: enum {
	Read  = 0, // PF_READ  = 01
	Write = 1, // PF_WRITE = 02
	Chown = 2, // PF_CHOWN = 04
}

Verb_Flag :: enum {
	Read  = 0, // VF_READ  = 01
	Write = 1, // VF_WRITE = 02
	Exec  = 2, // VF_EXEC  = 04
	Debug = 3, // VF_DEBUG = 010
}

object_has_flag :: proc(db: ^dbfile.Database, oid: values.Objid, flag: Object_Flag) -> bool {
	obj, ok := db.objects[oid]
	if !ok {
		return false
	}
	return (obj.flags & (1 << uint(flag))) != 0
}

is_wizard :: proc(db: ^dbfile.Database, oid: values.Objid) -> bool {
	return object_has_flag(db, oid, .Wizard)
}

is_programmer :: proc(db: ^dbfile.Database, oid: values.Objid) -> bool {
	return object_has_flag(db, oid, .Programmer)
}

is_user :: proc(db: ^dbfile.Database, oid: values.Objid) -> bool {
	return object_has_flag(db, oid, .User)
}

// object_allows ports db_object_allows(): PROGR's authority is sufficient for OID's FLAG
// iff OID has the flag itself, or PROGR owns OID, or PROGR is a wizard.
object_allows :: proc(db: ^dbfile.Database, oid: values.Objid, progr: values.Objid, flag: Object_Flag) -> bool {
	if object_has_flag(db, oid, flag) {
		return true
	}
	obj, ok := db.objects[oid]
	if ok && obj.owner == progr {
		return true
	}
	return is_wizard(db, progr)
}

// prop_allows ports db_property_allows().
prop_allows :: proc(db: ^dbfile.Database, perms: int, owner: values.Objid, progr: values.Objid, flag: Prop_Flag) -> bool {
	if (perms & (1 << uint(flag))) != 0 {
		return true
	}
	if owner == progr {
		return true
	}
	return is_wizard(db, progr)
}

// verb_allows ports db_verb_allows().
verb_allows :: proc(db: ^dbfile.Database, perms: int, owner: values.Objid, progr: values.Objid, flag: Verb_Flag) -> bool {
	if (perms & (1 << uint(flag))) != 0 {
		return true
	}
	if owner == progr {
		return true
	}
	return is_wizard(db, progr)
}

// valid ports valid()/db.h's notion of a live object reference: a non-negative, currently
// non-recycled object number.
valid :: proc(db: ^dbfile.Database, oid: values.Objid) -> bool {
	_, ok := db.objects[oid]
	return ok
}
