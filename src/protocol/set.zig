//! Generic unique-value collections with ordered and unordered storage policies.

const std = @import("std");
const context = @import("context.zig");

/// A contiguous, growable list of unique items in memory. Order is not preserved
/// This is a wrapper around an std.AutoHashMap of T keys with void value. Initialize with `init`.
///
/// This struct internally stores a `std.mem.Allocator` for memory management.
/// To manually specify an allocator with each method call see `SetUnmanaged`.
pub fn SetUnordered(comptime T: type) type {
    return struct {
        /// Hash map that stores each value as a key and owns its allocated capacity.
        const SetHashMap = std.HashMap(
            T,
            void,
            context.ZTypeContext(.unordered),
            std.hash_map.default_max_load_percentage,
        );

        /// Entry type returned when an item is removed.
        const KV = SetHashMap.KV;

        /// Map storage for the unique values.
        hash_map: SetHashMap,

        const Self = @This();

        /// Iterator over keys; traversal order is unspecified.
        pub const Iterator = SetHashMap.KeyIterator;

        /// Creates an empty set that allocates through `a`.
        /// Create a Set using an allocator. Data inside Set
        /// is managed by the caller. Will not automatically be freed.
        pub fn init(a: std.mem.Allocator) Self {
            return .{ .hash_map = SetHashMap.init(a) };
        }

        /// Releases the backing map storage and invalidates this set.
        pub fn deinit(self: *Self) void {
            self.hash_map.deinit();
            self.* = undefined;
        }

        /// Insert an item into the Set.
        /// Allocation failures are propagated to the caller.
        pub fn insert(self: *Self, value: T) !void {
            const gop = try self.hash_map.getOrPut(value);
            if (!gop.found_existing) gop.key_ptr.* = value;
        }

        /// Check if the set contains an item matching the passed value.
        pub fn contains(self: *Self, value: T) bool {
            return self.hash_map.contains(value);
        }

        /// Remove an item from the set.
        /// Returns the removed map entry, or null if no equal key exists.
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

        // Creates a copy of this set, using the same allocator
        /// Copies the map storage, retaining the original allocator.
        pub fn clone(self: *Self) !Self {
            var cloned = self.*;
            cloned.hash_map = try self.hash_map.clone();
            return cloned;
        }

        /// Creates a copy of this set, using a specified allocator.
        /// The returned copy owns its storage through `new_allocator`.
        pub fn cloneWithAllocator(self: *Self, new_allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
            // Since we're borrowing the internal map allocator, temporarily back it up.
            const prev_allocator = self.hash_map.allocator;
            // Restore it at the end of the func, because the self.map should use the
            // original allocator.
            defer self.hash_map.allocator = prev_allocator;

            // The cloned map must use and refer to the new allocator only.
            self.hash_map.allocator = new_allocator;
            const cloned = try self.clone();
            return cloned;
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
        /// Ordered map implementation used to retain insertion order.
        const SetHashMap = std.array_hash_map.Custom(
            T,
            void,
            context.ZTypeContext(.ordered),
            true,
        );

        /// Entry type returned when an item is removed.
        const KV = SetHashMap.KV;

        /// Allocator used for all backing-map allocations.
        allocator_: std.mem.Allocator,
        /// Map storage whose entries remain in insertion order.
        hash_map: SetHashMap,

        const Self = @This();

        /// Iterator over entries in insertion order.
        pub const Iterator = SetHashMap.Iterator;

        /// Creates an empty set that uses `a` for future allocations.
        /// Create a Set using an allocator. Data inside Set
        /// is managed by the caller. Will not automatically be freed.
        pub fn init(a: std.mem.Allocator) Self {
            return .{ .allocator_ = a, .hash_map = .empty };
        }

        /// Releases backing storage with the stored allocator and invalidates this set.
        pub fn deinit(self: *Self) void {
            self.hash_map.deinit(self.allocator_);
            self.* = undefined;
        }

        /// Insert an item into the Set.
        /// Allocation failures are propagated to the caller.
        pub fn insert(self: *Self, value: T) !void {
            const gop = try self.hash_map.getOrPut(self.allocator_, value);
            if (!gop.found_existing) gop.key_ptr.* = value;
        }

        /// Check if the set contains an item matching the passed value.
        pub fn contains(self: *Self, value: T) bool {
            return self.hash_map.contains(value);
        }

        /// Remove an item from the set.
        /// Returns the removed map entry, or null if no equal key exists.
        pub fn remove(self: *Self, value: T) ?KV {
            return self.hash_map.fetchOrderedRemove(value);
        }

        /// Returns the number of items stored in the set.
        pub fn count(self: *const Self) usize {
            return self.hash_map.count();
        }

        /// Returns an iterator over items in insertion order.
        pub fn iterator(self: *const Self) Iterator {
            return self.hash_map.iterator();
        }

        /// Get the allocator used by this set.
        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.allocator_;
        }

        // Creates a copy of this set, using the same allocator
        /// Copies the map storage, retaining the original allocator.
        pub fn clone(self: *Self) !Self {
            return .{
                .allocator_ = self.allocator_,
                .hash_map = try self.hash_map.clone(self.allocator_),
            };
        }

        /// Creates a copy of this set, using a specified allocator.
        /// The returned copy owns its storage through `new_allocator`.
        pub fn cloneWithAllocator(self: *Self, new_allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
            return .{
                .allocator_ = new_allocator,
                .hash_map = try self.hash_map.clone(new_allocator),
            };
        }
    };
}
