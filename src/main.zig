pub const Handle = @import("handle.zig").Handle;
pub const PoolUnmanaged = @import("pool.zig").PoolUnmanaged;
pub const Pool = @import("pool.zig").Pool;

// ensure transitive closure of test coverage
comptime {
    _ = Handle;
    _ = Pool;
    _ = PoolUnmanaged;
}
