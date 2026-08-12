package server

// Checkpoint writer, ported from db_file.c's dump_database(): fork() a child process that
// gets a copy-on-write snapshot of the whole address space as of the instant of the fork
// syscall, and let it write the DB file while the parent keeps serving connections. This is
// the exact strategy flagged back in vm/activation.odin's Phase 3 note -- Odin exposes raw
// POSIX fork() directly, so there's no reason to build a stop-the-world snapshot or an MVCC
// layer from scratch when the original's approach still works and is simpler.
//
// The one hazard specific to a multi-threaded process (which this server is, unlike the
// original's single process): fork() only clones the calling thread into the child -- every
// other thread just vanishes there, mid-whatever-it-was-doing, including any locks it held.
// The child below touches nothing but its own copy of `db` and the filesystem, then calls
// _exit() immediately -- it never reaches back into the scheduler, netio, or any lock a
// vanished thread might have been holding. The big_lock acquisition in checkpoint() itself
// (held across the fork() call, released immediately after in the parent) exists only to
// make sure the DB snapshot itself isn't torn mid-mutation by a concurrently-running task.

import "../dbfile"
import "../tasks"
import "core:fmt"
import "core:sync"
import "core:sys/posix"

// checkpoint writes db to path via a forked child process. Returns true if the fork
// succeeded (the write itself happens asynchronously in the child; failures there are
// logged by the child but not reported back to the caller, matching the original's
// fire-and-forget dump_database()).
checkpoint :: proc(db: ^dbfile.Database, scheduler: ^tasks.Scheduler, path: string) -> bool {
	sync.mutex_lock(&scheduler.big_lock)
	pid := posix.fork()
	if pid == 0 {
		// Child: own copy-on-write view of `db` as of just now. Do file I/O only, then
		// exit without ever unwinding back through the parent's call stack (which would
		// try to release locks/threads that don't meaningfully exist in this process).
		ok := dbfile.save_database(db, path)
		posix._exit(ok ? 0 : 1)
	}
	sync.mutex_unlock(&scheduler.big_lock)

	if pid < 0 {
		fmt.eprintln("CHECKPOINT: fork() failed")
		return false
	}
	fmt.printfln("CHECKPOINT: writing %s in child process %d", path, pid)
	return true
}
