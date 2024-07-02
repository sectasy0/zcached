const ztype = @import("types/ztype.zig");

pub const ZType = ztype.ZType;
pub const ztype_free = ztype.ztype_free;
pub const ztype_copy = ztype.ztype_copy;

/// Purpose of this Context is to implement `ZType` as a key in `HashMap`.
/// `Set` and `SetUnordered` are implemented on `HashMap`
pub const ZContext = @import("types/context.zig");

pub const sets = @import("types/sets.zig");
pub const Set = sets.Set;
pub const UnorderedSet = sets.SetUnordered;
