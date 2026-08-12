package main

import "../../dbfile"
import "../../values"
import "core:fmt"
import "core:os"
import "core:strconv"

main :: proc() {
	db, lerr := dbfile.load_database("/home/consty/LambdaMOO/LambdaCore.db")
	defer dbfile.database_destroy(&db)
	if lerr.stage != "" {
		fmt.eprintln("load failed:", lerr)
		os.exit(1)
	}
	oid, _ := strconv.parse_int(os.args[1], 10)
	name := os.args[2]
	obj := db.objects[values.Objid(oid)]
	for v in obj.verbdefs {
		if v.name == name {
			fmt.println(v.program_source)
			return
		}
	}
	fmt.eprintln("verb not found")
}
