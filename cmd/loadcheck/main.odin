package main

// Phase 1 milestone tool: load a LambdaMOO .db file and report structural stats, so its
// output can be diffed against the reference C `moo` binary's own load of the same file.

import "../../dbfile"
import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: loadcheck <path-to-db-file>")
		os.exit(1)
	}

	db, lerr := dbfile.load_database(os.args[1])
	if lerr.stage != "" {
		fmt.eprintfln("LOAD FAILED at stage %q: %v", lerr.stage, lerr.err)
		os.exit(1)
	}
	defer dbfile.database_destroy(&db)

	nverbs := 0
	nverbs_with_program := 0
	npropdefs := 0
	npropvals := 0
	for _, obj in db.objects {
		nverbs += len(obj.verbdefs)
		npropdefs += len(obj.propdefs)
		npropvals += len(obj.propvals)
		for v in obj.verbdefs {
			if v.has_program {
				nverbs_with_program += 1
			}
		}
	}

	fmt.println("LOAD OK")
	fmt.printfln("db version:          %d", db.version)
	fmt.printfln("objects:             %d  (max oid #%d)", len(db.objects), db.max_oid)
	fmt.printfln("users:               %d", len(db.users))
	fmt.printfln("verbdefs:            %d", nverbs)
	fmt.printfln("verbs with program:  %d", nverbs_with_program)
	fmt.printfln("propdefs:            %d", npropdefs)
	fmt.printfln("propvals:            %d", npropvals)
	fmt.printfln("forked tasks:        %d", len(db.forked_tasks))
	fmt.printfln("suspended tasks:     %d", db.suspended_task_count)
	fmt.printfln("active connections:  %d", len(db.connections))
}
