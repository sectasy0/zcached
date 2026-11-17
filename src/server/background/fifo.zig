//! Ring-buffer FIFO with fixed, caller-provided, or allocator-managed storage.
const std = @import("std");
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

pub const LinearFifoBufferType = union(enum) {
    /// The buffer is internal to the fifo; it is of the specified size.
    Static: usize,
    /// The buffer is passed as a slice to the initialiser.
    Slice,
    /// The buffer is managed dynamically using a `mem.Allocator`.
    Dynamic,
};

/// Generates a typed FIFO whose storage strategy is selected at compile time.
pub fn LinearFifo(comptime T: type, comptime buffer_type: LinearFifoBufferType) type {
    const autoalign = false;

    const powers_of_two = switch (buffer_type) {
        .Static => std.math.isPowerOfTwo(buffer_type.Static),
        .Slice => false, // Any size slice could be passed in
        .Dynamic => true, // This could be configurable in future
    };

    return struct {
        /// Allocator retained only by dynamically growing instances.
        allocator: if (buffer_type == .Dynamic) Allocator else void,
        /// Ring storage; statically embedded, borrowed, or dynamically owned.
        buf: if (buffer_type == .Static) [buffer_type.Static]T else []T,
        /// Index of the first readable item in the ring.
        head: usize,
        /// Number of initialized items currently queued.
        count: usize,

        /// Concrete FIFO type produced by this generic specialization.
        const Self = @This();
        /// Reader convenience wrapper borrowing a FIFO for incremental reads.
        pub const Reader = struct {
            /// FIFO accessed by this reader; must outlive the wrapper.
            context: *Self,

            /// Copies available FIFO items into `destination`, returning the count.
            pub fn read(self: Reader, destination: []u8) error{}!usize {
                return self.context.read(destination);
            }

            /// Reads through a delimiter, returning null only when EOF occurs before any data.
            pub fn readUntilDelimiterOrEof(self: Reader, buffer: []u8, delimiter: u8) !?[]u8 {
                var index: usize = 0;
                while (index < buffer.len) : (index += 1) {
                    var byte: [1]u8 = undefined;
                    if (try self.read(&byte) == 0) return if (index == 0) null else buffer[0..index];
                    if (byte[0] == delimiter) return buffer[0..index];
                    buffer[index] = byte[0];
                }
                return error.StreamTooLong;
            }
        };

        /// Writer convenience wrapper borrowing a FIFO for append operations.
        pub const Writer = struct {
            /// FIFO receiving output; must outlive the wrapper.
            context: *Self,

            /// Appends all bytes and reports their length, or allocation failure.
            pub fn write(self: Writer, bytes: []const u8) error{OutOfMemory}!usize {
                try self.context.write(bytes);
                return bytes.len;
            }

            /// Appends all bytes, propagating capacity-allocation failure.
            pub fn writeAll(self: Writer, bytes: []const u8) error{OutOfMemory}!void {
                try self.context.write(bytes);
            }

            /// Formats into a temporary allocation and appends the result.
            pub fn print(self: Writer, comptime format: []const u8, args: anytype) !void {
                const allocator = if (comptime buffer_type == .Dynamic)
                    self.context.allocator
                else
                    std.heap.page_allocator;
                const bytes = try std.fmt.allocPrint(allocator, format, args);
                defer allocator.free(bytes);
                try self.context.write(bytes);
            }
        };

        // Type of Self argument for slice operations.
        // If buffer is inline (Static) then we need to ensure we haven't
        // returned a slice into a copy on the stack
        /// Receiver form required to keep returned slices tied to static storage.
        const SliceSelfArg = if (buffer_type == .Static) *Self else Self;

        /// Buffer-type-specific initializer selected at compile time.
        pub const init = switch (buffer_type) {
            .Static => initStatic,
            .Slice => initSlice,
            .Dynamic => initDynamic,
        };

        /// Initializes an empty FIFO with embedded static storage.
        fn initStatic() Self {
            comptime assert(buffer_type == .Static);
            return .{
                .allocator = {},
                .buf = undefined,
                .head = 0,
                .count = 0,
            };
        }
        /// Initializes an empty FIFO borrowing the caller's slice without owning it.
        fn initSlice(buf: []T) Self {
            comptime assert(buffer_type == .Slice);
            return .{
                .allocator = {},
                .buf = buf,
                .head = 0,
                .count = 0,
            };
        }
        /// Initializes an empty FIFO that grows using the supplied allocator.
        fn initDynamic(allocator: Allocator) Self {
            comptime assert(buffer_type == .Dynamic);
            return .{
                .allocator = allocator,
                .buf = &.{},
                .head = 0,
                .count = 0,
            };
        }

        /// Frees dynamic storage; static and caller-owned slice storage are untouched.
        pub fn deinit(self: Self) void {
            if (buffer_type == .Dynamic) self.allocator.free(self.buf);
        }

        /// Moves queued items to the start of storage, preserving FIFO order.
        pub fn realign(self: *Self) void {
            if (self.buf.len - self.head >= self.count) {
                mem.copyForwards(T, self.buf[0..self.count], self.buf[self.head..][0..self.count]);
                self.head = 0;
            } else {
                var tmp: [4096 / 2 / @sizeOf(T)]T = undefined;

                while (self.head != 0) {
                    const n = @min(self.head, tmp.len);
                    const m = self.buf.len - n;
                    @memcpy(tmp[0..n], self.buf[0..n]);
                    mem.copyForwards(T, self.buf[0..m], self.buf[n..][0..m]);
                    @memcpy(self.buf[m..][0..n], tmp[0..n]);
                    self.head -= n;
                }
            }
            { // set unused area to undefined
                const unused = mem.sliceAsBytes(self.buf[self.count..]);
                @memset(unused, undefined);
            }
        }

        /// Reduce allocated capacity to `size`.
        /// Dynamic realloc failure is ignored, leaving the previous capacity intact.
        pub fn shrink(self: *Self, size: usize) void {
            assert(size >= self.count);
            if (buffer_type == .Dynamic) {
                self.realign();
                self.buf = self.allocator.realloc(self.buf, size) catch |e| switch (e) {
                    error.OutOfMemory => return, // no problem, capacity is still correct then.
                };
            }
        }

        /// Ensure that the buffer can fit at least `size` items
        /// Dynamic storage may grow; fixed storage returns `OutOfMemory` if too small.
        pub fn ensureTotalCapacity(self: *Self, size: usize) !void {
            if (self.buf.len >= size) return;
            if (buffer_type == .Dynamic) {
                self.realign();
                const new_size = if (powers_of_two) math.ceilPowerOfTwo(usize, size) catch return error.OutOfMemory else size;
                self.buf = try self.allocator.realloc(self.buf, new_size);
            } else {
                return error.OutOfMemory;
            }
        }

        /// Makes sure at least `size` items are unused
        /// Grows dynamic storage as needed and reports failure for fixed-capacity buffers.
        pub fn ensureUnusedCapacity(self: *Self, size: usize) error{OutOfMemory}!void {
            if (self.writableLength() >= size) return;

            return try self.ensureTotalCapacity(math.add(usize, self.count, size) catch return error.OutOfMemory);
        }

        /// Returns number of items currently in fifo
        /// Does not mutate the queue.
        pub fn readableLength(self: Self) usize {
            return self.count;
        }

        /// Returns a writable slice from the 'read' end of the fifo
        /// This mutable internal view may be empty when `offset` exceeds the queue length.
        fn readableSliceMut(self: SliceSelfArg, offset: usize) []T {
            if (offset > self.count) return &[_]T{};

            var start = self.head + offset;
            if (start >= self.buf.len) {
                start -= self.buf.len;
                return self.buf[start .. start + (self.count - offset)];
            } else {
                const end = @min(self.head + self.count, self.buf.len);
                return self.buf[start..end];
            }
        }

        /// Returns a readable slice from `offset`
        /// The returned slice is contiguous and does not include wrapped items beyond it.
        pub fn readableSlice(self: SliceSelfArg, offset: usize) []const T {
            return self.readableSliceMut(offset);
        }

        /// Returns `len` contiguous readable items, realigning the ring if it wraps.
        pub fn readableSliceOfLen(self: *Self, len: usize) []const T {
            assert(len <= self.count);
            const buf = self.readableSlice(0);
            if (buf.len >= len) {
                return buf[0..len];
            } else {
                self.realign();
                return self.readableSlice(0)[0..len];
            }
        }

        /// Discard first `count` items in the fifo
        /// Asserts that the requested count does not exceed the current queue length.
        pub fn discard(self: *Self, count: usize) void {
            assert(count <= self.count);
            { // set old range to undefined. Note: may be wrapped around
                const slice = self.readableSliceMut(0);
                if (slice.len >= count) {
                    const unused = mem.sliceAsBytes(slice[0..count]);
                    @memset(unused, undefined);
                } else {
                    const unused = mem.sliceAsBytes(slice[0..]);
                    @memset(unused, undefined);
                    const unused2 = mem.sliceAsBytes(self.readableSliceMut(slice.len)[0 .. count - slice.len]);
                    @memset(unused2, undefined);
                }
            }
            if (autoalign and self.count == count) {
                self.head = 0;
                self.count = 0;
            } else {
                var head = self.head + count;
                if (powers_of_two) {
                    // Note it is safe to do a wrapping subtract as
                    // bitwise & with all 1s is a noop
                    head &= self.buf.len -% 1;
                } else {
                    head %= self.buf.len;
                }
                self.head = head;
                self.count -= count;
            }
        }

        /// Read the next item from the fifo
        /// Returns null when empty, otherwise removes and returns the head item.
        pub fn readItem(self: *Self) ?T {
            if (self.count == 0) return null;

            const c = self.buf[self.head];
            self.discard(1);
            return c;
        }

        /// Read data from the fifo into `dst`, returns number of items copied.
        /// Removes every copied item and stops when the queue or destination is exhausted.
        pub fn read(self: *Self, dst: []T) usize {
            var dst_left = dst;

            while (dst_left.len > 0) {
                const slice = self.readableSlice(0);
                if (slice.len == 0) break;
                const n = @min(slice.len, dst_left.len);
                @memcpy(dst_left[0..n], slice[0..n]);
                self.discard(n);
                dst_left = dst_left[n..];
            }

            return dst.len - dst_left.len;
        }

        /// Returns a lightweight reader borrowing this FIFO.
        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        /// Returns number of items available in fifo
        /// Capacity is storage length minus the number of queued items.
        pub fn writableLength(self: Self) usize {
            return self.buf.len - self.count;
        }

        /// Returns the first section of writable buffer.
        /// Note that this may be of length 0
        /// The returned mutable slice is the first contiguous free region.
        pub fn writableSlice(self: SliceSelfArg, offset: usize) []T {
            if (offset > self.buf.len) return &[_]T{};

            const tail = self.head + offset + self.count;
            if (tail < self.buf.len) {
                return self.buf[tail..];
            } else {
                return self.buf[tail - self.buf.len ..][0 .. self.writableLength() - offset];
            }
        }

        /// Returns a writable buffer of at least `size` items, allocating memory as needed.
        /// Use `fifo.update` once you've written data to it.
        /// The returned slice is contiguous; only the written prefix should be committed.
        pub fn writableWithSize(self: *Self, size: usize) ![]T {
            try self.ensureUnusedCapacity(size);

            // try to avoid realigning buffer
            var slice = self.writableSlice(0);
            if (slice.len < size) {
                self.realign();
                slice = self.writableSlice(0);
            }
            return slice;
        }

        /// Update the tail location of the buffer (usually follows use of writable/writableWithSize)
        /// Marks `count` previously writable items as initialized and queued.
        pub fn update(self: *Self, count: usize) void {
            assert(self.count + count <= self.buf.len);
            self.count += count;
        }

        /// Appends the data in `src` to the fifo.
        /// You must have ensured there is enough space.
        /// Does not allocate; asserts sufficient free capacity.
        pub fn writeAssumeCapacity(self: *Self, src: []const T) void {
            assert(self.writableLength() >= src.len);

            var src_left = src;
            while (src_left.len > 0) {
                const writable_slice = self.writableSlice(0);
                assert(writable_slice.len != 0);
                const n = @min(writable_slice.len, src_left.len);
                @memcpy(writable_slice[0..n], src_left[0..n]);
                self.update(n);
                src_left = src_left[n..];
            }
        }

        /// Write a single item to the fifo
        /// Ensures one free slot first, allocating only for dynamic storage.
        pub fn writeItem(self: *Self, item: T) !void {
            try self.ensureUnusedCapacity(1);
            return self.writeItemAssumeCapacity(item);
        }

        /// Appends one item without checking capacity; caller must reserve a slot.
        pub fn writeItemAssumeCapacity(self: *Self, item: T) void {
            var tail = self.head + self.count;
            if (powers_of_two) {
                tail &= self.buf.len - 1;
            } else {
                tail %= self.buf.len;
            }
            self.buf[tail] = item;
            self.update(1);
        }

        /// Appends the data in `src` to the fifo.
        /// Allocates more memory as necessary
        /// Returns `OutOfMemory` if dynamic growth fails or fixed storage is full.
        pub fn write(self: *Self, src: []const T) !void {
            try self.ensureUnusedCapacity(src.len);

            return self.writeAssumeCapacity(src);
        }

        /// Returns a lightweight writer borrowing this FIFO.
        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        /// Make `count` items available before the current read location
        /// Moves the head backward to reserve slots before existing data.
        fn rewind(self: *Self, count: usize) void {
            assert(self.writableLength() >= count);

            var head = self.head + (self.buf.len - count);
            if (powers_of_two) {
                head &= self.buf.len - 1;
            } else {
                head %= self.buf.len;
            }
            self.head = head;
            self.count += count;
        }

        /// Place data back into the read stream
        /// Prepends a copy of `src` in its original order, growing dynamic storage if needed.
        pub fn unget(self: *Self, src: []const T) !void {
            try self.ensureUnusedCapacity(src.len);

            self.rewind(src.len);

            const slice = self.readableSliceMut(0);
            if (src.len < slice.len) {
                @memcpy(slice[0..src.len], src);
            } else {
                @memcpy(slice, src[0..slice.len]);
                const slice2 = self.readableSliceMut(slice.len);
                @memcpy(slice2[0 .. src.len - slice.len], src[slice.len..]);
            }
        }

        /// Returns the item at `offset`.
        /// Asserts offset is within bounds.
        /// Does not remove or otherwise modify the item.
        pub fn peekItem(self: Self, offset: usize) T {
            assert(offset < self.count);

            var index = self.head + offset;
            if (powers_of_two) {
                index &= self.buf.len - 1;
            } else {
                index %= self.buf.len;
            }
            return self.buf[index];
        }

        /// Pump data from a reader into a writer.
        /// Stops when reader returns 0 bytes (EOF).
        /// Buffer size must be set before calling; a buffer length of 0 is invalid.
        /// Writes all buffered data before reading further and propagates writer errors.
        pub fn pump(self: *Self, src_reader: anytype, dest_writer: anytype) !void {
            assert(self.buf.len > 0);
            while (true) {
                if (self.writableLength() > 0) {
                    const n = src_reader.read(self.writableSlice(0));
                    if (n == 0) break; // EOF
                    self.update(n);
                }
                const readable = self.readableSlice(0);
                try dest_writer.writeAll(readable);
                self.discard(readable.len);
            }
            // flush remaining data
            while (self.readableLength() > 0) {
                const readable = self.readableSlice(0);
                try dest_writer.writeAll(readable);
                self.discard(readable.len);
            }
        }

        /// Transfers queued items to a newly owned allocation and resets this FIFO.
        /// Dynamic FIFOs transfer or duplicate storage; use is unsupported for fixed storage.
        pub fn toOwnedSlice(self: *Self) Allocator.Error![]T {
            if (self.head != 0) self.realign();
            assert(self.head == 0);
            assert(self.count <= self.buf.len);
            const allocator = self.allocator;
            if (allocator.resize(self.buf, self.count)) {
                const result = self.buf[0..self.count];
                self.* = Self.init(allocator);
                return result;
            }
            const new_memory = try allocator.dupe(T, self.buf[0..self.count]);
            allocator.free(self.buf);
            self.* = Self.init(allocator);
            return new_memory;
        }
    };
}
