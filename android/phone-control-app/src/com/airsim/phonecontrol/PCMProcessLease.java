package com.airsim.phonecontrol;
import java.io.*;
import java.nio.channels.*;
/** Process-wide ownership. Never delete the lock file while peers may hold it. */
final class PCMProcessLease implements AutoCloseable {
    private RandomAccessFile file;
    private FileLock lease;
    synchronized void acquire(File path) throws IOException {
        if (lease != null && lease.isValid()) return;
        RandomAccessFile candidate = new RandomAccessFile(path, "rw");
        path.setReadable(true, false); path.setWritable(true, false);
        try {
            FileLock selected = candidate.getChannel().tryLock();
            if (selected == null) throw new IOException("PCM bridge already owned by another service");
            file = candidate; lease = selected;
        } catch (IOException | OverlappingFileLockException e) {
            candidate.close(); throw new IOException("PCM service ownership unavailable", e);
        }
    }
    public synchronized void close() throws IOException {
        if (lease != null) { lease.release(); lease = null; }
        if (file != null) { file.close(); file = null; }
    }
}
