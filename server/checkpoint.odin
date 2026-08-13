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
import "core:thread"

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
checkpoint :: proc(db: ^dbfile.Database, scheduler: ^tasks.Scheduler, path: string) -> bool {
	sync.mutex_lock(&scheduler.big_lock)
	data := dbfile.save_database_bytes(db)
	sync.mutex_unlock(&scheduler.big_lock)

	job := new(Checkpoint_Job)
	job.data = data
	job.path = strings_clone(path)
	sync.wait_group_add(&checkpoint_pending, 1)
	fmt.printfln("CHECKPOINT: snapshot taken (%d bytes), writing %s in background", len(data), path)
	thread.create_and_start_with_data(job, checkpoint_writer_proc, init_context = context, self_cleanup = true)
	return true
}

// checkpoint_wait blocks until every background checkpoint write has finished -- called by
// the shutdown path before the final synchronous save.
checkpoint_wait :: proc() {
	sync.wait_group_wait(&checkpoint_pending)
}

@(private = "file")
checkpoint_writer_proc :: proc(data: rawptr) {
	job := (^Checkpoint_Job)(data)
	defer free(job)
	defer delete(job.data)
	defer delete(job.path)
	defer sync.wait_group_done(&checkpoint_pending)

	werr := os.write_entire_file(job.path, job.data)
	if werr != nil {
		fmt.eprintfln("CHECKPOINT: writing %s FAILED: %v", job.path, werr)
	} else {
		fmt.printfln("CHECKPOINT: finished writing %s", job.path)
	}
}

@(private = "file")
strings_clone :: proc(s: string) -> string {
	buf := make([]byte, len(s))
	copy(buf, s)
	return string(buf)
}
