package server

// Checkpoint writer. The original (db_file.c's dump_database()) fork()s a child that gets a
// copy-on-write snapshot of the address space and writes the DB file while the parent keeps
// serving -- the right call for a single-threaded 1990s process with multi-second disk
// writes. This port did the same at first, but fork() in a MULTI-threaded process has a
// hazard the original never faced: only the calling thread survives into the child, and any
// lock some vanished thread held at the fork instant stays locked there forever -- including
// the C allocator's own internal lock, which netio's connection threads (which do NOT hold
// big_lock) take on every line they process. save_database allocates while serializing, so
// the child could deadlock on its first allocation, silently leaving a checkpoint that never
// finishes.
//
// Re-engineered to get the same "don't stall the MOO for the disk" property without fork():
// serialize the whole DB to an in-memory buffer while holding big_lock (memory-speed -- this
// is milliseconds for a LambdaCore-sized core, and no task can be mid-mutation), then hand
// the buffer to a background thread that does the slow filesystem write with no locks held
// and no shared state beyond the immutable buffer it owns. The buffer IS the snapshot, so
// nothing copy-on-write was buying us remains needed.

import "../dbfile"
import "../tasks"
import "core:fmt"
import "core:os"
import "core:sync"

@(private = "file")
Checkpoint_Job :: struct {
	data: []byte,
	path: string, // owned clone; the caller's string may not outlive the thread
}

// checkpoint_pending lets shutdown wait for an in-flight background write, so a final "kill
// the server right after SIGUSR2" can't lose the checkpoint that was still being written.
checkpoint_pending: sync.Wait_Group

// checkpoint serializes db (under the scheduler's big lock) and writes it to path on a
// background thread. Returns true if the snapshot was taken; the write itself is
// asynchronous, matching the original's fire-and-forget dump_database() -- write failures
// are logged by the writer thread, not reported back.
checkpoint :: proc(db: ^dbfile.Database, scheduler: ^tasks.Scheduler, path: string, connections: []dbfile.Connection_Record) -> bool {
	sync.mutex_lock(&scheduler.big_lock)
	// write_active_connections records the connections open NOW, not the ones the database
	// was loaded with.
	clear(&db.connections)
	append(&db.connections, ..connections)
	data := dbfile.save_database_bytes(db)
	clear(&db.connections)
	sync.mutex_unlock(&scheduler.big_lock)

	job := new(Checkpoint_Job)
	job.data = data
	job.path = strings_clone(path)
	sync.wait_group_add(&checkpoint_pending, 1)
	fmt.printfln("CHECKPOINT: snapshot taken (%d bytes), writing %s in background", len(data), path)
	if !tasks.spawn_worker(job, checkpoint_writer_proc) {
		// No writer thread available: write it here instead rather than drop the checkpoint or
		// leave checkpoint_pending raised forever (checkpoint_wait, and therefore shutdown,
		// blocks on it). Synchronous is the wrong trade-off in general -- it stalls the MOO for
		// the length of a disk write -- but it is strictly better than losing the snapshot.
		fmt.eprintln("CHECKPOINT: no thread available, writing synchronously")
		checkpoint_writer_proc(job)
	}
	return true
}

@(private = "file")
checkpoint_generation: int

// write_db_file writes a serialized database the way dump_database() does: to
// "<path>.#<generation>#" first, renamed over <path> only once complete, so a crash mid-write
// can't leave a truncated file where the last good one was.
write_db_file :: proc(path: string, data: []byte) -> os.Error {
	gen := sync.atomic_add(&checkpoint_generation, 1) + 1
	temp := fmt.aprintf("%s.#%d#", path, gen)
	defer delete(temp)
	if err := os.write_entire_file(temp, data); err != nil {
		os.remove(temp)
		return err
	}
	if err := os.rename(temp, path); err != nil {
		os.remove(temp)
		return err
	}
	return nil
}

// The outcome of the most recent background write, for the main loop to pass on to
// #0:checkpoint_finished: 0 = nothing new, 1 = failed, 2 = succeeded (server.c's
// checkpoint_finished).
@(private = "file")
checkpoint_outcome: int

@(private = "file")
checkpoint_report :: proc(ok: bool) {
	sync.atomic_store(&checkpoint_outcome, ok ? 2 : 1)
}

// checkpoint_take_result reports (and clears) a finished background write.
checkpoint_take_result :: proc() -> (ok: bool, finished: bool) {
	r := sync.atomic_exchange(&checkpoint_outcome, 0)
	return r == 2, r != 0
}

// checkpoint_wait blocks until every background checkpoint write has finished -- called by
// the shutdown path before the final synchronous save.
checkpoint_wait :: proc() {
	sync.wait_group_wait(&checkpoint_pending)
}

@(private = "file")
checkpoint_writer_proc :: proc(data: rawptr) {
	job := (^Checkpoint_Job)(data)
	// checkpoint_pending is released LAST, after this thread's own frees -- defers are LIFO, so
	// it is registered FIRST. checkpoint_wait() is the shutdown path's signal that the writer
	// is finished with everything, and main() goes on to dump the database and exit; releasing
	// it while frees are still pending means those frees race the process tearing down.
	defer sync.wait_group_done(&checkpoint_pending)
	defer free(job)
	defer delete(job.data)
	defer delete(job.path)

	// dump_database(): write "<name>.#<generation>#", and only once that has fully succeeded
	// rename it over <name> -- so a crash mid-write never leaves a truncated checkpoint where
	// the last good one was.
	werr := write_db_file(job.path, job.data)
	if werr != nil {
		fmt.eprintfln("CHECKPOINT: writing %s FAILED: %v", job.path, werr)
		checkpoint_report(false)
	} else {
		checkpoint_report(true)
		fmt.printfln("CHECKPOINT: finished writing %s", job.path)
		// Only now does the checkpoint become the database's on-disk representation, which is
		// what db_disk_size() reports on (main.odin's g_db_disk_size). The byte count is just
		// the buffer we wrote -- no stat needed, and none wanted: db_disk_size() is called from
		// MOO tasks holding big_lock.
		note_db_written(i64(len(job.data)))
	}
}

@(private = "file")
strings_clone :: proc(s: string) -> string {
	buf := make([]byte, len(s))
	copy(buf, s)
	return string(buf)
}
