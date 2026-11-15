const Io = @import("runtime_io");
const std = @import("std");

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(Io.get());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(Io.get());
    }
};

pub const RwLock = struct {
    inner: std.Io.RwLock = .init,

    pub fn lock(self: *RwLock) void {
        self.inner.lockUncancelable(Io.get());
    }

    pub fn lockShared(self: *RwLock) void {
        self.inner.lockSharedUncancelable(Io.get());
    }

    pub fn unlock(self: *RwLock) void {
        self.inner.unlock(Io.get());
    }

    pub fn unlockShared(self: *RwLock) void {
        self.inner.unlockShared(Io.get());
    }
};

pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(Io.get(), &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(Io.get());
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(Io.get());
    }
};

pub const Event = struct {
    inner: std.Io.Event = .unset,

    pub fn wait(self: *Event) void {
        self.inner.waitUncancelable(Io.get());
    }

    pub fn set(self: *Event) void {
        self.inner.set(Io.get());
    }

    pub fn reset(self: *Event) void {
        self.inner.reset();
    }
};
