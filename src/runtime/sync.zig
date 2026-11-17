//! Uncancelable synchronization primitives bound to the current runtime I/O.
const Io = @import("runtime_io");
const std = @import("std");

/// Exclusive lock whose waits use the active runtime's scheduler.
pub const Mutex = struct {
    /// Standard-library lock state; keep it paired with this wrapper.
    inner: std.Io.Mutex = .init,

    /// Acquires the lock without observing task cancellation.
    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(Io.get());
    }

    /// Releases a lock previously acquired through this wrapper.
    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(Io.get());
    }
};

/// Reader/writer lock bound to the currently selected I/O backend.
pub const RwLock = struct {
    /// Standard-library lock state shared by exclusive and reader ownership.
    inner: std.Io.RwLock = .init,

    /// Acquires exclusive ownership without cancellation.
    pub fn lock(self: *RwLock) void {
        self.inner.lockUncancelable(Io.get());
    }

    /// Acquires shared ownership without cancellation.
    pub fn lockShared(self: *RwLock) void {
        self.inner.lockSharedUncancelable(Io.get());
    }

    /// Releases exclusive ownership.
    pub fn unlock(self: *RwLock) void {
        self.inner.unlock(Io.get());
    }

    /// Releases one shared acquisition.
    pub fn unlockShared(self: *RwLock) void {
        self.inner.unlockShared(Io.get());
    }
};

/// Condition variable for waiting while holding a wrapped mutex.
pub const Condition = struct {
    /// Standard-library condition state.
    inner: std.Io.Condition = .init,

    /// Atomically releases `mutex` while waiting, then reacquires it.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(Io.get(), &mutex.inner);
    }

    /// Wakes one waiter, if any.
    pub fn signal(self: *Condition) void {
        self.inner.signal(Io.get());
    }

    /// Wakes all current waiters.
    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(Io.get());
    }
};

/// Manually signaled event; setting wakes waiters until the event is reset.
pub const Event = struct {
    /// Standard-library event state, initially unset.
    inner: std.Io.Event = .unset,

    /// Waits without observing cancellation until the event is set.
    pub fn wait(self: *Event) void {
        self.inner.waitUncancelable(Io.get());
    }

    /// Sets the event and wakes waiters using the active backend.
    pub fn set(self: *Event) void {
        self.inner.set(Io.get());
    }

    /// Clears the signaled state; callers must coordinate against concurrent setters.
    pub fn reset(self: *Event) void {
        self.inner.reset();
    }
};
