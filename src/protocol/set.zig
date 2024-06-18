const std = @import("std");
const context = @import("context.zig");

/// A contiguous, growable list of unique items in memory. Order is not preserved
/// This is a wrapper around an std.AutoHashMap of T keys with void value. Initialize with `init`.
///
/// This struct internally stores a `std.mem.Allocator` for memory management.
/// To manually specify an allocator with each method call see `SetUnmanaged`.
pub fn SetUnordered(comptime T: type) type {
    return struct {
        const SetHashMap = std.HashMap(
            T,
            void,
            context.ZTypeContext,
            std.hash_map.default_max_load_percentage,
        );

        const KV = SetHashMap.KV;

        hash_map: SetHashMap,

        const Self = @This();

        pub const Iterator = SetHashMap.KeyIterator;

        /// Create a Set using an allocator. Data inside Set
        /// is managed by the caller. Will not automatically be freed.
        pub fn init(a: std.mem.Allocator) Self {
            return .{ .hash_map = SetHashMap.init(a) };
        }

        pub fn deinit(self: *Self) void {
            self.hash_map.deinit();
            self.* = undefined;
        }

        /// Insert an item into the Set.
        pub fn insert(self: *Self, value: T) !void {
            const gop = try self.hash_map.getOrPut(value);
            if (!gop.found_existing) gop.key_ptr.* = value;
        }

        /// Check if the set contains an item matching the passed value.
        pub fn contains(self: *Self, value: T) bool {
            return self.hash_map.contains(value);
        }

        /// Remove an item from the set.
        pub fn remove(self: *Self, value: T) ?KV {
            return self.hash_map.fetchRemove(value);
        }

        /// Returns the number of items stored in the set.
        pub fn count(self: *const Self) usize {
            return self.hash_map.count();
        }

        /// Returns an iterator over the items stored in the set.
        /// Iteration order is arbitrary.
        pub fn iterator(self: *const Self) Iterator {
            return self.hash_map.keyIterator();
        }

        /// Get the allocator used by this set.
        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.hash_map.allocator;
        }

        /// Creates a copy of this set, using a specified allocator.
        pub fn cloneWithAllocator(
            self: *const Self,
            new_allocator: std.mem.Allocator,
        ) !Self {
            const cloned_hashmap = try self.hash_map.cloneWithAllocator(new_allocator);
            const cloned = Self{
                .hash_map = cloned_hashmap,
            };
            var it = cloned.hash_map.keyIterator();
            while (it.next()) |key_ptr| {
                key_ptr.* = try cloned.copy(key_ptr.*);
            }
            return cloned;
        }

        /// Creates a copy of this Set, using the same allocator.
        pub fn clone(self: *const Self) !Self {
            return self.cloneWithAllocator(self.allocator());
        }
    };
}

/// A contiguous, growable list of unique items in memory. Order is preserved
/// This is a wrapper around an std.AutoHashMap of T keys with void value. Initialize with `init`.
///
/// This struct internally stores a `std.mem.Allocator` for memory management.
/// To manually specify an allocator with each method call see `SetUnmanaged`.
pub fn Set(comptime T: type) type {
    return struct {
        const SetHashMap = std.ArrayHashMap(
            T,
            void,
            context.ZTypeArrayContext,
            true,
        );

        hash_map: SetHashMap,

        const Self = @This();

        pub const Iterator = SetHashMap.Iterator;

        /// Create a Set using an allocator. Data inside Set
        /// is managed by the caller. Will not automatically be freed.
        pub fn init(a: std.mem.Allocator) Self {
            return .{ .hash_map = SetHashMap.init(a) };
        }

        pub fn deinit(self: *Self) void {
            self.hash_map.deinit();
            self.* = undefined;
        }

        /// Insert an item into the Set.
        pub fn insert(self: *Self, value: T) !void {
            const gop = try self.hash_map.getOrPut(value);
            if (!gop.found_existing) gop.key_ptr.* = value;
        }

        /// Check if the set contains an item matching the passed value.
        pub fn contains(self: *Self, value: T) bool {
            return self.hash_map.contains(value);
        }

        /// Remove an item from the set.
        pub fn remove(self: *Self, value: T) ?T {
            return self.hash_map.fetchRemove(value);
        }

        /// Returns the number of items stored in the set.
        pub fn count(self: *const Self) usize {
            return self.hash_map.count();
        }

        /// Returns an iterator over the items stored in the set.
        /// Iteration order is arbitrary.
        pub fn iterator(self: *const Self) Iterator {
            return self.hash_map.iterator();
        }

        /// Get the allocator used by this set.
        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.hash_map.allocator;
        }

        /// Creates a copy of this set, using a specified allocator.
        pub fn cloneWithAllocator(
            self: *const Self,
            new_allocator: std.mem.Allocator,
        ) !Self {
            const cloned_hashmap = try self.hash_map.cloneWithAllocator(new_allocator);
            const cloned = Self{
                .hash_map = cloned_hashmap,
            };
            var it = cloned.hash_map.iterator();
            while (it.next()) |key_ptr| {
                key_ptr.* = try cloned.copy(key_ptr.*);
            }
            return cloned;
        }

        /// Creates a copy of this Set, using the same allocator.
        pub fn clone(self: *const Self) !Self {
            return self.cloneWithAllocator(self.allocator());
        }
    };
}
