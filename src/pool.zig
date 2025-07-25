const std = @import("std");

pub const PoolError = error{PoolIsFull} || HandleError;

pub const HandleError = error{
    HandleIsUnacquired,
    HandleIsOutOfBounds,
    HandleIsReleased,
};

pub fn ColumnsDeinitialiser(comptime TColumns: type) type {
    return struct {
        pub const VTable = struct {
            deinit_columns: *const fn (ctx: *anyopaque, columns: *TColumns) void,
            deinit: ?*const fn (ctx: *anyopaque) void = null,
        };

        ctx: *anyopaque,
        vtable: *const VTable,

        pub fn deinit(self: *@This()) void {
            if (self.vtable.deinit) |func| {
                func(self.ctx);
            }
            self.* = undefined;
        }

        pub fn deinit_columns(self: @This(), columns: *TColumns) void {
            self.vtable.deinit_columns(self.ctx, columns);
        }

        pub const default = bk: {
            const Helper = struct {
                fn default_deinit(_: *anyopaque, columns: *TColumns) void {
                    if (@hasDecl(TColumns, "deinit")) {
                        columns.deinit();
                    } else {
                        inline for (std.meta.fields(TColumns)) |column_field| {
                            switch (@typeInfo(column_field.type)) {
                                .@"struct", .@"enum", .@"union", .@"opaque" => {
                                    if (@hasDecl(column_field.type, "deinit")) {
                                        @field(columns, column_field.name).deinit();
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
            };
            break :bk @This(){
                .ctx = undefined,
                .vtable = &VTable{
                    .deinit_columns = &Helper.default_deinit,
                },
            };
        };
    };
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/// Returns a struct that maintains a pool of data.  Handles returned by
/// `Pool.add()` can be used to get/set the data in zero or more columns.
///
/// See `handles.zig` for more information on `index_bits` and `cycle_bits`,
/// and handles in general.
///
/// `TResource` identifies type of resource referenced by a handle, and
/// provides a type-safe distinction between two otherwise equivalently
/// configured `Handle` types, such as:
/// * `const BufferHandle  = Handle(16, 16, Buffer);`
/// * `const TextureHandle = Handle(16, 16, Texture);`
///
/// `TColumns` is a struct that defines the column names, and the element types
/// of the column arrays.
///
/// ```zig
/// const Texture = gpu.Texture;
///
/// const TexturePool = Pool(16, 16, Texture, struct { obj:Texture, desc:Texture.Descriptor });
/// const TextureHandle = TexturePool.Handle;
///
/// const GPA = std.heap.GeneralPurposeAllocator;
/// var gpa = GPA(.{}){};
/// var pool = try TexturePool.initMaxCapacity(gpa.allocator());
/// defer pool.deinit();
///
/// // creating a texture and adding it to the pool returns a handle
/// const desc : Texture.Descriptor = .{ ... };
/// const obj = device.createTexture(desc);
/// const handle : TextureHandle = pool.add(.{ .obj = obj, .desc = desc });
///
/// // elsewhere, use the handle to get `obj` or `desc` as needed
/// const obj = pool.getColumn(handle, .obj);
/// const desc = pool.getColumn(handle, .desc);
///
/// // ...
///
/// // once the texture is no longer needed, release it.
/// _ = pool.removeIfLive(handle);
/// ```
pub fn PoolUnmanaged(
    comptime index_bits: u8,
    comptime cycle_bits: u8,
    comptime TResource: type,
    comptime TColumns: type,
) type {
    // Handle performs compile time checks on index_bits & cycle_bits
    const ring_queue = @import("embedded_ring_queue.zig");
    const handles = @import("handle.zig");
    const utils = @import("utils.zig");

    if (!utils.isStruct(TColumns)) @compileError("TColumns must be a struct");

    const assert = std.debug.assert;
    const meta = std.meta;
    const Allocator = std.mem.Allocator;
    const MultiArrayList = std.MultiArrayList;
    const StructOfSlices = utils.StructOfSlices;
    const RingQueue = ring_queue.EmbeddedRingQueue;

    return struct {
        const Self = @This();

        pub const Error = PoolError;

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        pub const Resource = TResource;
        pub const Handle = handles.Handle(index_bits, cycle_bits, TResource);

        pub const AddressableHandle = Handle.AddressableHandle;
        pub const AddressableIndex = Handle.AddressableIndex;
        pub const AddressableCycle = Handle.AddressableCycle;
        pub const Deinitialiser = ColumnsDeinitialiser(TColumns);

        pub const max_index: usize = Handle.max_index;
        pub const max_cycle: usize = Handle.max_cycle;
        pub const max_capacity: usize = Handle.max_count;

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        pub const Columns = TColumns;
        pub const ColumnSlices = StructOfSlices(Columns);
        pub const Column = meta.FieldEnum(Columns);

        pub const column_fields = meta.fields(Columns);
        pub const column_count = column_fields.len;

        pub fn ColumnType(comptime column: Column) type {
            return meta.fieldInfo(Columns, column).type;
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        const private_fields = meta.fields(struct {
            @"Pool._free_queue": AddressableIndex,
            @"Pool._curr_cycle": AddressableCycle,
        });

        const Storage = MultiArrayList(@Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = private_fields ++ column_fields,
            .decls = &.{},
            .is_tuple = false,
        } }));

        const FreeQueue = RingQueue(AddressableIndex);

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        _storage: Storage = .{},
        _free_queue: FreeQueue = .{},
        _curr_cycle: []AddressableCycle = &.{},
        columns: ColumnSlices = undefined,
        deinitialiser: Deinitialiser = undefined,

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Returns an initialized `Pool` that will use `allocator` for all
        /// allocations.  The `Pool` stores all handles and columns in a single
        /// memory allocation backed by `std.MultiArrayList`.
        pub fn init(deinitialiser: Deinitialiser) Self {
            var self = Self{
                .deinitialiser = deinitialiser,
            };
            updateSlices(&self);
            return self;
        }

        /// Returns an initialized `Pool` that will use `allocator` for all
        /// allocations, with at least `min_capacity` preallocated.
        pub fn initCapacity(allocator: Allocator, min_capacity: usize, deinitialiser: Deinitialiser) !Self {
            var self = Self{
                .deinitialiser = deinitialiser,
            };
            try self.reserve(allocator, min_capacity);
            return self;
        }

        /// Returns an initialized `Pool` that will use `allocator` for all
        /// allocations, with the `Pool.max_capacity` preallocated.
        pub fn initMaxCapacity(allocator: Allocator, deinitialiser: Deinitialiser) !Self {
            return initCapacity(allocator, max_capacity, deinitialiser);
        }

        /// Releases all resources associated with an initialized pool.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.clear();
            self._storage.deinit(allocator);
            self.deinitialiser.deinit();
            self.* = .{};
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Returns the capacity of the pool, i.e. the maximum number of handles
        /// it can contain without allocating additional memory.
        pub fn capacity(self: Self) usize {
            return self._storage.capacity;
        }

        /// Requests the capacity of the pool be at least `min_capacity`.
        /// If the pool `capacity()` is already equal to or greater than
        /// `min_capacity`, `reserve()` has no effect.
        pub fn reserve(self: *Self, allocator: Allocator, min_capacity: usize) !void {
            const old_capacity = self._storage.capacity;
            if (min_capacity <= old_capacity)
                return;

            if (min_capacity > max_capacity)
                return Error.PoolIsFull;

            try self._storage.setCapacity(allocator, min_capacity);
            updateSlices(self);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Returns the number of live handles.
        pub fn liveHandleCount(self: Self) usize {
            return self._storage.len - self._free_queue.len();
        }

        /// Returns `true` if `handle` is live, otherwise `false`.
        pub fn isLiveHandle(self: Self, handle: Handle) bool {
            return self.isLiveAddressableHandle(handle.addressable());
        }

        /// Checks whether `handle` is live.
        /// Unlike `std.debug.assert()`, this check is evaluated in all builds.
        pub fn requireLiveHandle(self: Self, handle: Handle) HandleError!void {
            try self.requireLiveAddressableHandle(handle.addressable());
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Returns an iterator that can enumerate each live index.
        /// The iterator is invalidated by calls to `add()`.
        pub fn liveIndices(self: Self) LiveIndexIterator {
            return .{ .curr_cycle = self._curr_cycle };
        }

        pub const LiveIndexIterator = struct {
            curr_cycle: []const AddressableCycle = &.{},
            next_index: AddressableIndex = 0,
            ended: bool = false,

            pub fn next(self: *LiveIndexIterator) ?AddressableIndex {
                while (!self.ended and self.next_index < self.curr_cycle.len) {
                    const curr_index = self.next_index;
                    if (curr_index < max_index) {
                        self.next_index += 1;
                    } else {
                        self.ended = true;
                    }
                    if (isLiveCycle(self.curr_cycle[curr_index]))
                        return curr_index;
                }
                return null;
            }
        };

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Returns an iterator that can enumerate each live handle.
        /// The iterator is invalidated by calls to `add()`.
        pub fn liveHandles(self: Self) LiveHandleIterator {
            return .{ .live_indices = liveIndices(self) };
        }

        pub const LiveHandleIterator = struct {
            live_indices: LiveIndexIterator = .{},

            pub fn next(self: *LiveHandleIterator) ?Handle {
                if (self.live_indices.next()) |index| {
                    const ahandle = AddressableHandle{
                        .index = index,
                        .cycle = self.live_indices.curr_cycle[index],
                    };
                    return ahandle.handle();
                }
                return null;
            }
        };

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Releases all live `Handles` and calls `deinit()` on columns if
        /// defined.
        pub fn clear(self: *Self) void {
            var ahandle = AddressableHandle{ .index = 0 };
            for (self._curr_cycle, 0..) |cycle, i| {
                if (isLiveCycle(cycle)) {
                    ahandle.index = @as(AddressableIndex, @intCast(i));
                    ahandle.cycle = cycle;
                    self.releaseAddressableHandleUnchecked(ahandle);
                }
            }
        }

        /// Adds `values` and returns a live `Handle` if possible, otherwise
        /// returns one of:
        /// * `Error.PoolIsFull`
        /// * `Allocator.Error.OutOfMemory`
        pub fn add(self: *Self, allocator: Allocator, values: Columns) !Handle {
            const ahandle = try self.acquireAddressableHandleAlloc(allocator);
            self.initColumnsAt(ahandle.index, values);
            return ahandle.handle();
        }

        /// Adds `values` and returns a live `Handle` if possible, otherwise
        /// returns null.
        pub fn addIfNotFull(self: *Self, values: Columns) ?Handle {
            if (self.acquireAddressableHandle() catch {
                return null;
            }) |ahandle| {
                self.initColumnsAt(ahandle.index, values);
                return ahandle.handle();
            }
            return null;
        }

        /// Adds `values` and returns a live `Handle` if possible, otherwise
        /// calls `std.debug.assert(false)` and returns `Handle.nil`.
        pub fn addAssumeNotFull(self: *Self, values: Columns) Handle {
            const ahandle = (self.acquireAddressableHandle() catch {
                assert(false);
                return Handle.nil;
            }).?;
            self.initColumnsAt(ahandle.index, values);
            return ahandle.handle();
        }

        /// Removes (and invalidates) `handle` if live.
        pub fn remove(self: *Self, handle: Handle) HandleError!void {
            try self.releaseAddressableHandle(handle.addressable());
        }

        /// Removes (and invalidates) `handle` if live.
        /// Returns `true` if removed, otherwise `false`.
        pub fn removeIfLive(self: *Self, handle: Handle) bool {
            const ahandle = handle.addressable();
            if (self.isLiveAddressableHandle(ahandle)) {
                self.releaseAddressableHandleUnchecked(ahandle);
                return true;
            }
            return false;
        }

        /// Attempts to remove (and invalidates) `handle` assuming it is live.
        /// Liveness of `handle` is checked by `std.debug.assert()`.
        pub fn removeAssumeLive(self: *Self, handle: Handle) void {
            const ahandle = handle.addressable();
            assert(self.isLiveAddressableHandle(ahandle));
            self.releaseAddressableHandleUnchecked(ahandle);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Gets a column pointer if `handle` is live.
        pub fn getColumnPtr(self: Self, handle: Handle, comptime column: Column) HandleError!*ColumnType(column) {
            const ahandle = handle.addressable();
            try self.requireLiveAddressableHandle(ahandle);
            return self.getColumnPtrUnchecked(ahandle, column);
        }

        /// Gets a column value if `handle` is live.
        pub fn getColumn(self: Self, handle: Handle, comptime column: Column) HandleError!ColumnType(column) {
            const ahandle = handle.addressable();
            try self.requireLiveAddressableHandle(ahandle);
            return self.getColumnUnchecked(ahandle, column);
        }

        /// Gets column values if `handle` is live.
        pub fn getColumns(self: Self, handle: Handle) HandleError!Columns {
            const ahandle = handle.addressable();
            try self.requireLiveAddressableHandle(ahandle);
            return self.getColumnsUnchecked(ahandle);
        }

        /// Sets a column value if `handle` is live.
        pub fn setColumn(self: Self, handle: Handle, comptime column: Column, value: ColumnType(column)) HandleError!void {
            const ahandle = handle.addressable();
            try self.requireLiveAddressableHandle(ahandle);
            self.setColumnUnchecked(ahandle, column, value);
        }

        /// Sets column values if `handle` is live.
        pub fn setColumns(self: Self, handle: Handle, values: Columns) HandleError!void {
            const ahandle = handle.addressable();
            try self.requireLiveAddressableHandle(ahandle);
            self.setColumnsUnchecked(ahandle, values);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Gets a column pointer if `handle` is live, otherwise `null`.
        pub fn getColumnPtrIfLive(self: Self, handle: Handle, comptime column: Column) ?*ColumnType(column) {
            const ahandle = handle.addressable();
            if (self.isLiveAddressableHandle(ahandle)) {
                return self.getColumnPtrUnchecked(ahandle, column);
            }
            return null;
        }

        /// Gets a column value if `handle` is live, otherwise `null`.
        pub fn getColumnIfLive(self: Self, handle: Handle, comptime column: Column) ?ColumnType(column) {
            const ahandle = handle.addressable();
            if (self.isLiveAddressableHandle(ahandle)) {
                return self.getColumnUnchecked(ahandle, column);
            }
            return null;
        }

        /// Gets column values if `handle` is live, otherwise `null`.
        pub fn getColumnsIfLive(self: Self, handle: Handle) ?Columns {
            const ahandle = handle.addressable();
            if (self.isLiveAddressableHandle(ahandle)) {
                return self.getColumnsUnchecked(ahandle);
            }
            return null;
        }

        /// Sets a column value if `handle` is live.
        /// Returns `true` if the column value was set, otherwise `false`.
        pub fn setColumnIfLive(self: Self, handle: Handle, comptime column: Column, value: ColumnType(column)) bool {
            const ahandle = handle.addressable();
            if (self.isLiveAddressableHandle(ahandle)) {
                self.setColumnUnchecked(ahandle, column, value);
                return true;
            }
            return false;
        }

        /// Sets column values if `handle` is live.
        /// Returns `true` if the column value was set, otherwise `false`.
        pub fn setColumnsIfLive(self: Self, handle: Handle, values: Columns) bool {
            const ahandle = handle.addressable();
            if (self.isLiveAddressableHandle(ahandle)) {
                self.setColumnsUnchecked(ahandle, values);
                return true;
            }
            return false;
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Attempts to get a column pointer assuming `handle` is live.
        /// Liveness of `handle` is checked by `std.debug.assert()`.
        pub fn getColumnPtrAssumeLive(self: Self, handle: Handle, comptime column: Column) *ColumnType(column) {
            const ahandle = handle.addressable();
            assert(self.isLiveAddressableHandle(ahandle));
            return self.getColumnPtrUnchecked(ahandle, column);
        }

        /// Attempts to get a column value assuming `handle` is live.
        /// Liveness of `handle` is checked by `std.debug.assert()`.
        pub fn getColumnAssumeLive(self: Self, handle: Handle, comptime column: Column) ColumnType(column) {
            const ahandle = handle.addressable();
            assert(self.isLiveAddressableHandle(ahandle));
            return self.getColumnUnchecked(ahandle, column);
        }

        /// Attempts to get column values assuming `handle` is live.
        /// Liveness of `handle` is checked by `std.debug.assert()`.
        pub fn getColumnsAssumeLive(self: Self, handle: Handle) Columns {
            const ahandle = handle.addressable();
            assert(self.isLiveAddressableHandle(ahandle));
            return self.getColumnsUnchecked(ahandle);
        }

        /// Attempts to set a column value assuming `handle` is live.
        /// Liveness of `handle` is checked by `std.debug.assert()`.
        pub fn setColumnAssumeLive(self: Self, handle: Handle, comptime column: Column, value: ColumnType(column)) void {
            const ahandle = handle.addressable();
            assert(self.isLiveAddressableHandle(ahandle));
            self.setColumnUnchecked(ahandle, column, value);
        }

        /// Attempts to set column values assuming `handle` is live.
        /// Liveness of `handle` is checked by `std.debug.assert()`.
        pub fn setColumnsAssumeLive(self: Self, handle: Handle, values: Columns) void {
            const ahandle = handle.addressable();
            assert(self.isLiveAddressableHandle(ahandle));
            self.setColumnsUnchecked(ahandle, values);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Gets a column pointer. In most cases, `getColumnPtrAssumeLive` should be used instead.
        pub fn getColumnPtrUnchecked(self: Self, handle: AddressableHandle, comptime column: Column) *ColumnType(column) {
            const column_field = meta.fieldInfo(Columns, column);
            return &@field(self.columns, column_field.name)[handle.index];
        }

        /// Gets a column value. In most cases, `getColumnAssumeLive` should be used instead.
        pub fn getColumnUnchecked(self: Self, handle: AddressableHandle, comptime column: Column) ColumnType(column) {
            return self.getColumnPtrUnchecked(handle, column).*;
        }

        /// Gets column values. In most cases, `getColumnsAssumeLive` should be used instead.
        pub fn getColumnsUnchecked(self: Self, handle: AddressableHandle) Columns {
            var values: Columns = undefined;
            inline for (column_fields) |column_field| {
                @field(values, column_field.name) =
                    @field(self.columns, column_field.name)[handle.index];
            }
            return values;
        }

        /// Sets a column value. In most cases, `setColumnAssumeLive` should be used instead.
        pub fn setColumnUnchecked(self: Self, handle: AddressableHandle, comptime column: Column, value: ColumnType(column)) void {
            const column_field = meta.fieldInfo(Columns, column);
            self.deinitColumnAt(handle.index, column_field);
            @field(self.columns, column_field.name)[handle.index] = value;
        }

        /// Sets column values. In most cases, `setColumnsAssumeLive` should be used instead.
        pub fn setColumnsUnchecked(self: Self, handle: AddressableHandle, values: Columns) void {
            self.deinitColumnsAt(handle.index);
            self.initColumnsAt(handle.index, values);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        const StructField = std.builtin.Type.StructField;

        fn initColumnsAt(self: Self, index: AddressableIndex, values: Columns) void {
            inline for (column_fields) |column_field| {
                @field(self.columns, column_field.name)[index] =
                    @field(values, column_field.name);
            }
        }

        /// Call `value.deinit()` if defined.
        fn deinitColumnAt(self: Self, index: AddressableIndex, comptime column_field: StructField) void {
            switch (@typeInfo(column_field.type)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => {
                    if (@hasDecl(column_field.type, "deinit")) {
                        @field(self.columns, column_field.name)[index].deinit();
                    }
                },
                else => {},
            }
        }

        fn deinitColumnsAt(self: Self, index: AddressableIndex) void {
            var values: Columns = undefined;
            inline for (column_fields) |column_field| {
                @field(values, column_field.name) =
                    @field(self.columns, column_field.name)[index];
            }
            self.deinitialiser.deinit_columns(&values);
            inline for (column_fields) |column_field| {
                @field(self.columns, column_field.name)[index] =
                    @field(values, column_field.name);
            }
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        fn updateSlices(self: *Self) void {
            var slice = self._storage.slice();

            const free_queue_storage = slice.items(.@"Pool._free_queue");
            self._free_queue.resize(free_queue_storage);

            self._curr_cycle = slice.items(.@"Pool._curr_cycle");
            inline for (column_fields, 0..) |column_field, i| {
                const F = column_field.type;
                const p = slice.ptrs[private_fields.len + i];
                const f = @as([*]F, @ptrCast(@alignCast(p)));
                @field(self.columns, column_field.name) = f[0..slice.len];
            }
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        fn isLiveAddressableHandle(
            self: Self,
            handle: AddressableHandle,
        ) bool {
            if (isFreeCycle(handle.cycle))
                return false;
            if (handle.index >= self._curr_cycle.len)
                return false;
            if (handle.cycle != self._curr_cycle[handle.index])
                return false;
            return true;
        }

        fn requireLiveAddressableHandle(
            self: Self,
            handle: AddressableHandle,
        ) HandleError!void {
            if (isFreeCycle(handle.cycle))
                return Error.HandleIsUnacquired;
            if (handle.index >= self._curr_cycle.len)
                return Error.HandleIsOutOfBounds;
            if (handle.cycle != self._curr_cycle[handle.index])
                return Error.HandleIsReleased;
        }

        fn acquireAddressableHandle(self: *Self) !?AddressableHandle {
            if (self._storage.len == max_capacity) {
                return Error.PoolIsFull;
            }

            var handle = AddressableHandle{};
            if (self.didGetNewHandleNoResize(&handle)) {
                assert(self.isLiveAddressableHandle(handle));
                return handle;
            }

            if (self.didDequeueFreeIndex(&handle.index)) {
                handle.cycle = self.incrementAndReturnCycle(handle.index);
                assert(self.isLiveAddressableHandle(handle));
                return handle;
            }

            return null;
        }

        fn acquireAddressableHandleAlloc(self: *Self, allocator: Allocator) !AddressableHandle {
            if (try self.acquireAddressableHandle()) |handle|
                return handle;

            var handle = AddressableHandle{};
            try self.getNewHandleAfterResize(allocator, &handle);
            assert(self.isLiveAddressableHandle(handle));
            return handle;
        }

        fn releaseAddressableHandle(
            self: *Self,
            handle: AddressableHandle,
        ) !void {
            try self.requireLiveAddressableHandle(handle);
            self.releaseAddressableHandleUnchecked(handle);
        }

        fn releaseAddressableHandleUnchecked(
            self: *Self,
            handle: AddressableHandle,
        ) void {
            self.deinitColumnsAt(handle.index);
            self.incrementCycle(handle.index);
            self.enqueueFreeIndex(handle.index);
        }

        fn tryReleaseAddressableHandle(
            self: *Self,
            handle: AddressableHandle,
        ) bool {
            if (self.isLiveAddressableHandle(handle)) {
                self.releaseAddressableHandleUnchecked(handle);
                return true;
            }
            return false;
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Even cycles (least significant bit is `0`) are "free".
        fn isFreeCycle(cycle: AddressableCycle) bool {
            return (cycle & @as(AddressableCycle, 1)) == @as(AddressableCycle, 0);
        }

        /// Odd cycles (least significant bit is `1`) are "live".
        fn isLiveCycle(cycle: AddressableCycle) bool {
            return (cycle & @as(AddressableCycle, 1)) == @as(AddressableCycle, 1);
        }

        fn incrementCycle(self: *Self, index: AddressableIndex) void {
            const new_cycle = self._curr_cycle[index] +% 1;
            self._curr_cycle[index] = new_cycle;
        }

        fn incrementAndReturnCycle(
            self: *Self,
            index: AddressableIndex,
        ) AddressableCycle {
            const new_cycle = self._curr_cycle[index] +% 1;
            self._curr_cycle[index] = new_cycle;
            return new_cycle;
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        fn enqueueFreeIndex(self: *Self, index: AddressableIndex) void {
            self._free_queue.enqueueAssumeNotFull(index);
        }

        fn didDequeueFreeIndex(self: *Self, index: *AddressableIndex) bool {
            return self._free_queue.dequeueIfNotEmpty(index);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        fn didGetNewHandleNoResize(self: *Self, handle: *AddressableHandle) bool {
            if (self._storage.len < max_capacity and
                self._storage.len < self._storage.capacity and
                self._free_queue.canResize())
            {
                const new_index = self._storage.addOneAssumeCapacity();
                updateSlices(self);
                self._curr_cycle[new_index] = 1;
                handle.index = @as(AddressableIndex, @intCast(new_index));
                handle.cycle = 1;
                return true;
            }
            return false;
        }

        fn getNewHandleAfterResize(self: *Self, allocator: Allocator, handle: *AddressableHandle) !void {
            const new_index = try self._storage.addOne(allocator);
            updateSlices(self);
            self._curr_cycle[new_index] = 1;
            handle.index = @as(AddressableIndex, @intCast(new_index));
            handle.cycle = 1;
        }
    };
}

pub fn Pool(
    comptime index_bits: u8,
    comptime cycle_bits: u8,
    comptime TResource: type,
    comptime TColumns: type,
) type {
    const Allocator = std.mem.Allocator;

    return struct {
        const Self = @This();

        const Unmanaged = PoolUnmanaged(index_bits, cycle_bits, TResource, TColumns);
        pub const Error = Unmanaged.Error;

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        pub const Resource = Unmanaged.Resource;
        pub const Handle = Unmanaged.Handle;

        pub const AddressableHandle = Unmanaged.AddressableHandle;
        pub const AddressableIndex = Unmanaged.AddressableIndex;
        pub const AddressableCycle = Unmanaged.AddressableCycle;
        pub const Deinitialiser = Unmanaged.Deinitialiser;

        pub const max_index: usize = Unmanaged.max_index;
        pub const max_cycle: usize = Unmanaged.max_cycle;
        pub const max_capacity: usize = Unmanaged.max_capacity;

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        pub const Columns = Unmanaged.Columns;
        pub const ColumnSlices = Unmanaged.ColumnSlices;
        pub const Column = Unmanaged.Column;

        pub const column_fields = Unmanaged.column_fields;
        pub const column_count = Unmanaged.column_count;

        pub fn ColumnType(comptime column: Column) type {
            return Unmanaged.ColumnType(column);
        }

        unmanaged: Unmanaged,
        allocator: Allocator,

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Returns an initialized `Pool` that will use `allocator` for all
        /// allocations.  The `Pool` stores all handles and columns in a single
        /// memory allocation backed by `std.MultiArrayList`.
        pub fn init(allocator: Allocator, deinitialiser: Deinitialiser) Self {
            return Self{
                .allocator = allocator,
                .unmanaged = Unmanaged.init(deinitialiser),
            };
        }

        /// Returns an initialized `Pool` that will use `allocator` for all
        /// allocations, with at least `min_capacity` preallocated.
        pub fn initCapacity(allocator: Allocator, min_capacity: usize, deinitialiser: Deinitialiser) !Self {
            return Self{
                .allocator = allocator,
                .unmanaged = try Unmanaged.initCapacity(allocator, min_capacity, deinitialiser),
            };
        }

        /// Returns an initialized `Pool` that will use `allocator` for all
        /// allocations, with the `Pool.max_capacity` preallocated.
        pub fn initMaxCapacity(allocator: Allocator, deinitialiser: Deinitialiser) !Self {
            return Self{
                .allocator = allocator,
                .unmanaged = try Unmanaged.initMaxCapacity(allocator, deinitialiser),
            };
        }

        /// Releases all resources associated with an initialized pool.
        pub fn deinit(self: *Self) void {
            self.unmanaged.deinit(self.allocator);
            self.* = undefined;
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Returns the capacity of the pool, i.e. the maximum number of handles
        /// it can contain without allocating additional memory.
        pub fn capacity(self: Self) usize {
            return self.unmanaged.capacity();
        }

        /// Requests the capacity of the pool be at least `min_capacity`.
        /// If the pool `capacity()` is already equal to or greater than
        /// `min_capacity`, `reserve()` has no effect.
        pub fn reserve(self: *Self, min_capacity: usize) !void {
            return self.unmanaged.reserve(self.allocator, min_capacity);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Returns the number of live handles.
        pub fn liveHandleCount(self: Self) usize {
            return self.unmanaged.liveHandleCount();
        }

        /// Returns `true` if `handle` is live, otherwise `false`.
        pub fn isLiveHandle(self: Self, handle: Handle) bool {
            return self.unmanaged.isLiveHandle(handle);
        }

        /// Checks whether `handle` is live.
        /// Unlike `std.debug.assert()`, this check is evaluated in all builds.
        pub fn requireLiveHandle(self: Self, handle: Handle) HandleError!void {
            try self.unmanaged.requireLiveHandle(handle);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Returns an iterator that can enumerate each live index.
        /// The iterator is invalidated by calls to `add()`.
        pub fn liveIndices(self: Self) LiveIndexIterator {
            return self.unmanaged.liveIndices();
        }

        pub const LiveIndexIterator = Unmanaged.LiveIndexIterator;

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Returns an iterator that can enumerate each live handle.
        /// The iterator is invalidated by calls to `add()`.
        pub fn liveHandles(self: Self) LiveHandleIterator {
            return self.unmanaged.liveHandles();
        }

        pub const LiveHandleIterator = Unmanaged.LiveHandleIterator;

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Releases all live `Handles` and calls `deinit()` on columns if
        /// defined.
        pub fn clear(self: *Self) void {
            self.unmanaged.clear();
        }

        /// Adds `values` and returns a live `Handle` if possible, otherwise
        /// returns one of:
        /// * `Error.PoolIsFull`
        /// * `Allocator.Error.OutOfMemory`
        pub fn add(self: *Self, values: Columns) !Handle {
            return self.unmanaged.add(self.allocator, values);
        }

        /// Adds `values` and returns a live `Handle` if possible, otherwise
        /// returns null.
        pub fn addIfNotFull(self: *Self, values: Columns) ?Handle {
            return self.unmanaged.addIfNotFull(values);
        }

        /// Adds `values` and returns a live `Handle` if possible, otherwise
        /// calls `std.debug.assert(false)` and returns `Handle.nil`.
        pub fn addAssumeNotFull(self: *Self, values: Columns) Handle {
            return self.unmanaged.addAssumeNotFull(values);
        }

        /// Removes (and invalidates) `handle` if live.
        pub fn remove(self: *Self, handle: Handle) HandleError!void {
            try self.unmanaged.remove(handle);
        }

        /// Removes (and invalidates) `handle` if live.
        /// Returns `true` if removed, otherwise `false`.
        pub fn removeIfLive(self: *Self, handle: Handle) bool {
            return self.unmanaged.removeIfLive(handle);
        }

        /// Attempts to remove (and invalidates) `handle` assuming it is live.
        /// Liveness of `handle` is checked by `std.debug.assert()`.
        pub fn removeAssumeLive(self: *Self, handle: Handle) void {
            return self.unmanaged.removeAssumeLive(handle);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Gets a column pointer if `handle` is live.
        pub fn getColumnPtr(self: Self, handle: Handle, comptime column: Column) HandleError!*ColumnType(column) {
            return self.unmanaged.getColumnPtr(handle, column);
        }

        /// Gets a column value if `handle` is live.
        pub fn getColumn(self: Self, handle: Handle, comptime column: Column) HandleError!ColumnType(column) {
            return self.unmanaged.getColumn(handle, column);
        }

        /// Gets column values if `handle` is live.
        pub fn getColumns(self: Self, handle: Handle) HandleError!Columns {
            return self.unmanaged.getColumns(handle);
        }

        /// Sets a column value if `handle` is live.
        pub fn setColumn(self: Self, handle: Handle, comptime column: Column, value: ColumnType(column)) HandleError!void {
            return self.unmanaged.setColumn(handle, column, value);
        }

        /// Sets column values if `handle` is live.
        pub fn setColumns(self: Self, handle: Handle, values: Columns) HandleError!void {
            return self.unmanaged.setColumns(handle, values);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Gets a column pointer if `handle` is live, otherwise `null`.
        pub fn getColumnPtrIfLive(self: Self, handle: Handle, comptime column: Column) ?*ColumnType(column) {
            return self.unmanaged.getColumnPtrIfLive(handle, column);
        }

        /// Gets a column value if `handle` is live, otherwise `null`.
        pub fn getColumnIfLive(self: Self, handle: Handle, comptime column: Column) ?ColumnType(column) {
            return self.unmanaged.getColumnIfLive(handle, column);
        }

        /// Gets column values if `handle` is live, otherwise `null`.
        pub fn getColumnsIfLive(self: Self, handle: Handle) ?Columns {
            return self.unmanaged.getColumnsIfLive(handle);
        }

        /// Sets a column value if `handle` is live.
        /// Returns `true` if the column value was set, otherwise `false`.
        pub fn setColumnIfLive(self: Self, handle: Handle, comptime column: Column, value: ColumnType(column)) bool {
            return self.unmanaged.setColumnIfLive(handle, column, value);
        }

        /// Sets column values if `handle` is live.
        /// Returns `true` if the column value was set, otherwise `false`.
        pub fn setColumnsIfLive(self: Self, handle: Handle, values: Columns) bool {
            return self.unmanaged.setColumnsIfLive(handle, values);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Attempts to get a column pointer assuming `handle` is live.
        /// Liveness of `handle` is checked by `std.debug.assert()`.
        pub fn getColumnPtrAssumeLive(self: Self, handle: Handle, comptime column: Column) *ColumnType(column) {
            return self.unmanaged.getColumnPtrAssumeLive(handle, column);
        }

        /// Attempts to get a column value assuming `handle` is live.
        /// Liveness of `handle` is checked by `std.debug.assert()`.
        pub fn getColumnAssumeLive(self: Self, handle: Handle, comptime column: Column) ColumnType(column) {
            return self.unmanaged.getColumnAssumeLive(handle, column);
        }

        /// Attempts to get column values assuming `handle` is live.
        /// Liveness of `handle` is checked by `std.debug.assert()`.
        pub fn getColumnsAssumeLive(self: Self, handle: Handle) Columns {
            return self.unmanaged.getColumnsAssumeLive(handle);
        }

        /// Attempts to set a column value assuming `handle` is live.
        /// Liveness of `handle` is checked by `std.debug.assert()`.
        pub fn setColumnAssumeLive(self: Self, handle: Handle, comptime column: Column, value: ColumnType(column)) void {
            return self.unmanaged.setColumnAssumeLive(handle, column, value);
        }

        /// Attempts to set column values assuming `handle` is live.
        /// Liveness of `handle` is checked by `std.debug.assert()`.
        pub fn setColumnsAssumeLive(self: Self, handle: Handle, values: Columns) void {
            return self.unmanaged.setColumnsAssumeLive(handle, values);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Gets a column pointer. In most cases, `getColumnPtrAssumeLive` should be used instead.
        pub fn getColumnPtrUnchecked(self: Self, handle: AddressableHandle, comptime column: Column) *ColumnType(column) {
            return self.unmanaged.getColumnPtrUnchecked(handle, column);
        }

        /// Gets a column value. In most cases, `getColumnAssumeLive` should be used instead.
        pub fn getColumnUnchecked(self: Self, handle: AddressableHandle, comptime column: Column) ColumnType(column) {
            return self.unmanaged.getColumnUnchecked(handle, column);
        }

        /// Gets column values. In most cases, `getColumnsAssumeLive` should be used instead.
        pub fn getColumnsUnchecked(self: Self, handle: AddressableHandle) Columns {
            return self.unmanaged.getColumnsUnchecked(handle);
        }

        /// Sets a column value. In most cases, `setColumnAssumeLive` should be used instead.
        pub fn setColumnUnchecked(self: Self, handle: AddressableHandle, comptime column: Column, value: ColumnType(column)) void {
            return self.unmanaged.setColumnUnchecked(handle, column, value);
        }

        /// Sets column values. In most cases, `setColumnsAssumeLive` should be used instead.
        pub fn setColumnsUnchecked(self: Self, handle: AddressableHandle, values: Columns) void {
            return self.unmanaged.setColumnsUnchecked(handle, values);
        }
    };
}

//------------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const DeinitCounter = struct {
    const Self = @This();

    counter: *u32,

    fn init(_counter: *u32) Self {
        return Self{ .counter = _counter };
    }

    fn deinit(self: *Self) void {
        self.counter.* += 1;
    }
};

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.init()" {
    const TestPool = Pool(8, 8, void, struct {});
    var pool = TestPool.init(std.testing.allocator, .default);
    defer pool.deinit();
}

test "Pool with no columns" {
    const TestPool = Pool(8, 8, void, struct {});
    try expectEqual(@as(usize, 0), TestPool.column_count);
    try expectEqual(@as(usize, 0), @sizeOf(TestPool.ColumnSlices));

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    const handle = try pool.add(.{});
    defer _ = pool.removeIfLive(handle);

    try pool.requireLiveHandle(handle);
    try expect(pool.isLiveHandle(handle));
    try expectEqual(@as(u8, 0), handle.addressable().index);
    try expectEqual(@as(u8, 1), handle.addressable().cycle);
    try expectEqual(@as(usize, 1), pool.liveHandleCount());
}

test "Pool with one column" {
    const TestPool = Pool(8, 8, void, struct { a: u32 });
    try expectEqual(@as(usize, 1), TestPool.column_count);
    try expectEqual(@sizeOf([]u32), @sizeOf(TestPool.ColumnSlices));

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    const handle = try pool.add(.{ .a = 123 });
    defer _ = pool.removeIfLive(handle);

    try pool.requireLiveHandle(handle);
    try expect(pool.isLiveHandle(handle));
    try expectEqual(@as(usize, 1), pool.liveHandleCount());
    try expectEqual(@as(u8, 0), handle.addressable().index);
    try expectEqual(@as(u8, 1), handle.addressable().cycle);

    try expectEqual(@as(u32, 123), try pool.getColumn(handle, .a));
    try pool.setColumn(handle, .a, 456);
    try expectEqual(@as(u32, 456), try pool.getColumn(handle, .a));
}

test "Pool with two columns" {
    const TestPool = Pool(8, 8, void, struct { a: u32, b: u64 });
    try expectEqual(@as(usize, 2), TestPool.column_count);
    try expectEqual(@sizeOf([]u32) * 2, @sizeOf(TestPool.ColumnSlices));

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    const handle = try pool.add(.{ .a = 123, .b = 456 });
    defer _ = pool.removeIfLive(handle);

    try pool.requireLiveHandle(handle);
    try expect(pool.isLiveHandle(handle));
    try expectEqual(@as(usize, 1), pool.liveHandleCount());
    try expectEqual(@as(u8, 0), handle.addressable().index);
    try expectEqual(@as(u8, 1), handle.addressable().cycle);

    try expectEqual(@as(u32, 123), try pool.getColumn(handle, .a));
    try pool.setColumn(handle, .a, 456);
    try expectEqual(@as(u32, 456), try pool.getColumn(handle, .a));

    try expectEqual(@as(u64, 456), try pool.getColumn(handle, .b));
    try pool.setColumn(handle, .b, 123);
    try expectEqual(@as(u64, 123), try pool.getColumn(handle, .b));
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.liveHandleCount()" {
    const TestPool = Pool(8, 8, void, struct {});

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const handle0 = try pool.add(.{});
    try expectEqual(@as(usize, 1), pool.liveHandleCount());

    const handle1 = try pool.add(.{});
    try expectEqual(@as(usize, 2), pool.liveHandleCount());

    try pool.remove(handle0);
    try expectEqual(@as(usize, 1), pool.liveHandleCount());

    try pool.remove(handle1);
    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const handle2 = try pool.add(.{});
    try expectEqual(@as(usize, 1), pool.liveHandleCount());

    try pool.remove(handle2);
    try expectEqual(@as(usize, 0), pool.liveHandleCount());
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.isLiveHandle()" {
    const TestPool = Pool(8, 8, void, struct {});

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const unacquiredHandle = TestPool.Handle.init(0, 0);
    try expect(!pool.isLiveHandle(unacquiredHandle));

    const outOfBoundsHandle = TestPool.Handle.init(1, 1);
    try expect(!pool.isLiveHandle(outOfBoundsHandle));

    const handle = try pool.add(.{});
    try expect(pool.isLiveHandle(handle));

    try pool.remove(handle);
    try expect(!pool.isLiveHandle(handle));
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.requireLiveHandle()" {
    const TestPool = Pool(8, 8, void, struct {});
    try expectEqual(@as(usize, 0), TestPool.column_count);
    try expectEqual(@as(usize, 0), @sizeOf(TestPool.ColumnSlices));

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const unacquiredHandle = TestPool.Handle.init(0, 0);
    try expectError(TestPool.Error.HandleIsUnacquired, pool.requireLiveHandle(unacquiredHandle));

    const outOfBoundsHandle = TestPool.Handle.init(1, 1);
    try expectError(TestPool.Error.HandleIsOutOfBounds, pool.requireLiveHandle(outOfBoundsHandle));

    const handle = try pool.add(.{});
    try pool.requireLiveHandle(handle);

    try pool.remove(handle);
    try expectError(TestPool.Error.HandleIsReleased, pool.requireLiveHandle(handle));
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.liveIndices()" {
    const TestPool = Pool(8, 8, void, struct {});

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const handle0 = try pool.add(.{});
    const handle1 = try pool.add(.{});
    const handle2 = try pool.add(.{});
    try expectEqual(@as(usize, 3), pool.liveHandleCount());

    var live_indices = pool.liveIndices();
    try expectEqual(handle0.addressable().index, live_indices.next().?);
    try expectEqual(handle1.addressable().index, live_indices.next().?);
    try expectEqual(handle2.addressable().index, live_indices.next().?);
    try expect(null == live_indices.next());
}

test "Pool.liveIndices() when full" {
    // Test that iterator's internal index doesn't overflow when pool is full.
    // (8,8 is the smallest size we can easily test because AddressableIndex is
    // at least a u8)
    const TestPool = Pool(8, 8, void, struct {});

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    var i: usize = 0;
    while (i < 256) {
        _ = try pool.add(.{});
        i += 1;
    }
    try expectEqual(@as(usize, 256), pool.liveHandleCount());

    // Make sure it does correctly iterate all the way.
    var j: usize = 0;
    var live_indices = pool.liveIndices();
    while (live_indices.next()) |_| {
        j += 1;
    }
    try expectEqual(@as(usize, 256), j);
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.liveHandles()" {
    const TestPool = Pool(8, 8, void, struct {});

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const handle0 = try pool.add(.{});
    const handle1 = try pool.add(.{});
    const handle2 = try pool.add(.{});
    try expectEqual(@as(usize, 3), pool.liveHandleCount());

    var live_handles = pool.liveHandles();
    try expectEqual(handle0.id, live_handles.next().?.id);
    try expectEqual(handle1.id, live_handles.next().?.id);
    try expectEqual(handle2.id, live_handles.next().?.id);
    try expect(null == live_handles.next());
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.clear()" {
    const TestPool = Pool(8, 8, void, struct {});

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const handle0 = try pool.add(.{});
    const handle1 = try pool.add(.{});
    const handle2 = try pool.add(.{});
    try expectEqual(@as(usize, 3), pool.liveHandleCount());
    try expect(pool.isLiveHandle(handle0));
    try expect(pool.isLiveHandle(handle1));
    try expect(pool.isLiveHandle(handle2));

    pool.clear();
    try expectEqual(@as(usize, 0), pool.liveHandleCount());
    try expect(!pool.isLiveHandle(handle0));
    try expect(!pool.isLiveHandle(handle1));
    try expect(!pool.isLiveHandle(handle2));
}

test "Pool.clear() calls Columns.deinit()" {
    const TestPool = Pool(2, 6, void, DeinitCounter);

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    var deinit_count: u32 = 0;
    _ = try pool.add(DeinitCounter.init(&deinit_count));
    try expectEqual(@as(u32, 0), deinit_count);
    pool.clear();
    try expectEqual(@as(u32, 1), deinit_count);
}

test "Pool.clear() calls ColumnType.deinit()" {
    const TestPool = Pool(2, 6, void, struct { a: DeinitCounter, b: DeinitCounter });

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    var deinit_count: u32 = 0;
    _ = try pool.add(.{
        .a = DeinitCounter.init(&deinit_count),
        .b = DeinitCounter.init(&deinit_count),
    });
    try expectEqual(@as(u32, 0), deinit_count);
    pool.clear();
    try expectEqual(@as(u32, 2), deinit_count);
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.add()" {
    const TestPool = Pool(2, 6, void, struct {});
    try expectEqual(@sizeOf(u8), @sizeOf(TestPool.Handle));
    try expectEqual(@as(usize, 4), TestPool.max_capacity);

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const handle0 = try pool.add(.{});
    const handle1 = try pool.add(.{});
    const handle2 = try pool.add(.{});
    const handle3 = try pool.add(.{});
    try expectEqual(@as(usize, 4), pool.liveHandleCount());
    try expect(pool.isLiveHandle(handle0));
    try expect(pool.isLiveHandle(handle1));
    try expect(pool.isLiveHandle(handle2));
    try expect(pool.isLiveHandle(handle3));
    try expectError(TestPool.Error.PoolIsFull, pool.add(.{}));
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.remove()" {
    const TestPool = Pool(2, 6, void, struct {});

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const handle0 = try pool.add(.{});
    const handle1 = try pool.add(.{});
    const handle2 = try pool.add(.{});
    const handle3 = try pool.add(.{});
    try pool.remove(handle0);
    try pool.remove(handle1);
    try pool.remove(handle2);
    try pool.remove(handle3);
    try expectError(TestPool.Error.HandleIsReleased, pool.remove(handle0));
    try expectError(TestPool.Error.HandleIsReleased, pool.remove(handle1));
    try expectError(TestPool.Error.HandleIsReleased, pool.remove(handle2));
    try expectError(TestPool.Error.HandleIsReleased, pool.remove(handle3));
}

test "Pool.remove() calls Columns.deinit()" {
    const TestPool = Pool(2, 6, void, DeinitCounter);

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    var deinit_count: u32 = 0;
    const handle = try pool.add(DeinitCounter.init(&deinit_count));
    try expectEqual(@as(u32, 0), deinit_count);
    try pool.remove(handle);
    try expectEqual(@as(u32, 1), deinit_count);
}

test "Pool.remove() calls ColumnType.deinit()" {
    const TestPool = Pool(2, 6, void, struct { a: DeinitCounter, b: DeinitCounter });

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    var deinit_count: u32 = 0;
    const handle = try pool.add(.{
        .a = DeinitCounter.init(&deinit_count),
        .b = DeinitCounter.init(&deinit_count),
    });
    try expectEqual(@as(u32, 0), deinit_count);
    try pool.remove(handle);
    try expectEqual(@as(u32, 2), deinit_count);
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.removeIfLive()" {
    const TestPool = Pool(2, 6, void, struct {});

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const handle0 = try pool.add(.{});
    const handle1 = try pool.add(.{});
    const handle2 = try pool.add(.{});
    const handle3 = try pool.add(.{});
    try expect(pool.isLiveHandle(handle0));
    try expect(pool.isLiveHandle(handle1));
    try expect(pool.isLiveHandle(handle2));
    try expect(pool.isLiveHandle(handle3));

    try expect(pool.removeIfLive(handle0));
    try expect(pool.removeIfLive(handle1));
    try expect(pool.removeIfLive(handle2));
    try expect(pool.removeIfLive(handle3));

    try expect(!pool.isLiveHandle(handle0));
    try expect(!pool.isLiveHandle(handle1));
    try expect(!pool.isLiveHandle(handle2));
    try expect(!pool.isLiveHandle(handle3));

    try expect(!pool.removeIfLive(handle0));
    try expect(!pool.removeIfLive(handle1));
    try expect(!pool.removeIfLive(handle2));
    try expect(!pool.removeIfLive(handle3));
}

test "Pool.removeIfLive() calls Columns.deinit()" {
    const TestPool = Pool(2, 6, void, DeinitCounter);

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    var deinit_count: u32 = 0;
    const handle = try pool.add(DeinitCounter.init(&deinit_count));
    try expectEqual(@as(u32, 0), deinit_count);
    try expect(pool.removeIfLive(handle));
    try expectEqual(@as(u32, 1), deinit_count);
}

test "Pool.removeIfLive() calls ColumnType.deinit()" {
    const TestPool = Pool(2, 6, void, struct { a: DeinitCounter, b: DeinitCounter });

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    var deinit_count: u32 = 0;
    const handle = try pool.add(.{
        .a = DeinitCounter.init(&deinit_count),
        .b = DeinitCounter.init(&deinit_count),
    });
    try expectEqual(@as(u32, 0), deinit_count);
    try expect(pool.removeIfLive(handle));
    try expectEqual(@as(u32, 2), deinit_count);
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.getColumnPtr*()" {
    const TestPool = Pool(2, 6, void, struct { a: u32 });

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const handle0 = try pool.add(.{ .a = 0 });
    const handle1 = try pool.add(.{ .a = 1 });
    const handle2 = try pool.add(.{ .a = 2 });
    const handle3 = try pool.add(.{ .a = 3 });

    const a0ptr: *u32 = try pool.getColumnPtr(handle0, .a);
    const a1ptr: *u32 = try pool.getColumnPtr(handle1, .a);
    const a2ptr: *u32 = try pool.getColumnPtr(handle2, .a);
    const a3ptr: *u32 = try pool.getColumnPtr(handle3, .a);
    try expectEqual(@as(u32, 0), a0ptr.*);
    try expectEqual(@as(u32, 1), a1ptr.*);
    try expectEqual(@as(u32, 2), a2ptr.*);
    try expectEqual(@as(u32, 3), a3ptr.*);
    try expectEqual(a0ptr, pool.getColumnPtrIfLive(handle0, .a).?);
    try expectEqual(a1ptr, pool.getColumnPtrIfLive(handle1, .a).?);
    try expectEqual(a2ptr, pool.getColumnPtrIfLive(handle2, .a).?);
    try expectEqual(a3ptr, pool.getColumnPtrIfLive(handle3, .a).?);
    try expectEqual(a0ptr, pool.getColumnPtrAssumeLive(handle0, .a));
    try expectEqual(a1ptr, pool.getColumnPtrAssumeLive(handle1, .a));
    try expectEqual(a2ptr, pool.getColumnPtrAssumeLive(handle2, .a));
    try expectEqual(a3ptr, pool.getColumnPtrAssumeLive(handle3, .a));

    try pool.remove(handle0);
    try pool.remove(handle1);
    try pool.remove(handle2);
    try pool.remove(handle3);
    try expectError(TestPool.Error.HandleIsReleased, pool.getColumnPtr(handle0, .a));
    try expectError(TestPool.Error.HandleIsReleased, pool.getColumnPtr(handle1, .a));
    try expectError(TestPool.Error.HandleIsReleased, pool.getColumnPtr(handle2, .a));
    try expectError(TestPool.Error.HandleIsReleased, pool.getColumnPtr(handle3, .a));
    try expect(null == pool.getColumnPtrIfLive(handle0, .a));
    try expect(null == pool.getColumnPtrIfLive(handle1, .a));
    try expect(null == pool.getColumnPtrIfLive(handle2, .a));
    try expect(null == pool.getColumnPtrIfLive(handle3, .a));
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.getColumn*()" {
    const TestPool = Pool(2, 6, void, struct { a: u32 });

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const handle0 = try pool.add(.{ .a = 0 });
    const handle1 = try pool.add(.{ .a = 1 });
    const handle2 = try pool.add(.{ .a = 2 });
    const handle3 = try pool.add(.{ .a = 3 });

    try expectEqual(@as(u32, 0), try pool.getColumn(handle0, .a));
    try expectEqual(@as(u32, 1), try pool.getColumn(handle1, .a));
    try expectEqual(@as(u32, 2), try pool.getColumn(handle2, .a));
    try expectEqual(@as(u32, 3), try pool.getColumn(handle3, .a));
    try expectEqual(@as(u32, 0), pool.getColumnIfLive(handle0, .a).?);
    try expectEqual(@as(u32, 1), pool.getColumnIfLive(handle1, .a).?);
    try expectEqual(@as(u32, 2), pool.getColumnIfLive(handle2, .a).?);
    try expectEqual(@as(u32, 3), pool.getColumnIfLive(handle3, .a).?);
    try expectEqual(@as(u32, 0), pool.getColumnAssumeLive(handle0, .a));
    try expectEqual(@as(u32, 1), pool.getColumnAssumeLive(handle1, .a));
    try expectEqual(@as(u32, 2), pool.getColumnAssumeLive(handle2, .a));
    try expectEqual(@as(u32, 3), pool.getColumnAssumeLive(handle3, .a));

    try pool.remove(handle0);
    try pool.remove(handle1);
    try pool.remove(handle2);
    try pool.remove(handle3);
    try expectError(TestPool.Error.HandleIsReleased, pool.getColumn(handle0, .a));
    try expectError(TestPool.Error.HandleIsReleased, pool.getColumn(handle1, .a));
    try expectError(TestPool.Error.HandleIsReleased, pool.getColumn(handle2, .a));
    try expectError(TestPool.Error.HandleIsReleased, pool.getColumn(handle3, .a));
    try expect(null == pool.getColumnIfLive(handle0, .a));
    try expect(null == pool.getColumnIfLive(handle1, .a));
    try expect(null == pool.getColumnIfLive(handle2, .a));
    try expect(null == pool.getColumnIfLive(handle3, .a));
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.setColumn*()" {
    const TestPool = Pool(2, 6, void, struct { a: u32 });

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const handle0 = try pool.add(.{ .a = 0 });
    const handle1 = try pool.add(.{ .a = 1 });
    const handle2 = try pool.add(.{ .a = 2 });
    const handle3 = try pool.add(.{ .a = 3 });

    try expectEqual(@as(u32, 0), try pool.getColumn(handle0, .a));
    try expectEqual(@as(u32, 1), try pool.getColumn(handle1, .a));
    try expectEqual(@as(u32, 2), try pool.getColumn(handle2, .a));
    try expectEqual(@as(u32, 3), try pool.getColumn(handle3, .a));
    try expectEqual(@as(u32, 0), pool.getColumnIfLive(handle0, .a).?);
    try expectEqual(@as(u32, 1), pool.getColumnIfLive(handle1, .a).?);
    try expectEqual(@as(u32, 2), pool.getColumnIfLive(handle2, .a).?);
    try expectEqual(@as(u32, 3), pool.getColumnIfLive(handle3, .a).?);
    try expectEqual(@as(u32, 0), pool.getColumnAssumeLive(handle0, .a));
    try expectEqual(@as(u32, 1), pool.getColumnAssumeLive(handle1, .a));
    try expectEqual(@as(u32, 2), pool.getColumnAssumeLive(handle2, .a));
    try expectEqual(@as(u32, 3), pool.getColumnAssumeLive(handle3, .a));

    try pool.setColumn(handle0, .a, 10);
    try pool.setColumn(handle1, .a, 11);
    try pool.setColumn(handle2, .a, 12);
    try pool.setColumn(handle3, .a, 13);
    try expect(pool.setColumnIfLive(handle0, .a, 20));
    try expect(pool.setColumnIfLive(handle1, .a, 21));
    try expect(pool.setColumnIfLive(handle2, .a, 22));
    try expect(pool.setColumnIfLive(handle3, .a, 23));
    pool.setColumnAssumeLive(handle0, .a, 30);
    pool.setColumnAssumeLive(handle1, .a, 31);
    pool.setColumnAssumeLive(handle2, .a, 32);
    pool.setColumnAssumeLive(handle3, .a, 33);

    try expectEqual(@as(u32, 30), try pool.getColumn(handle0, .a));
    try expectEqual(@as(u32, 31), try pool.getColumn(handle1, .a));
    try expectEqual(@as(u32, 32), try pool.getColumn(handle2, .a));
    try expectEqual(@as(u32, 33), try pool.getColumn(handle3, .a));
    try expectEqual(@as(u32, 30), pool.getColumnIfLive(handle0, .a).?);
    try expectEqual(@as(u32, 31), pool.getColumnIfLive(handle1, .a).?);
    try expectEqual(@as(u32, 32), pool.getColumnIfLive(handle2, .a).?);
    try expectEqual(@as(u32, 33), pool.getColumnIfLive(handle3, .a).?);
    try expectEqual(@as(u32, 30), pool.getColumnAssumeLive(handle0, .a));
    try expectEqual(@as(u32, 31), pool.getColumnAssumeLive(handle1, .a));
    try expectEqual(@as(u32, 32), pool.getColumnAssumeLive(handle2, .a));
    try expectEqual(@as(u32, 33), pool.getColumnAssumeLive(handle3, .a));

    try pool.remove(handle0);
    try pool.remove(handle1);
    try pool.remove(handle2);
    try pool.remove(handle3);
    try expectError(TestPool.Error.HandleIsReleased, pool.setColumn(handle0, .a, 40));
    try expectError(TestPool.Error.HandleIsReleased, pool.setColumn(handle1, .a, 41));
    try expectError(TestPool.Error.HandleIsReleased, pool.setColumn(handle2, .a, 42));
    try expectError(TestPool.Error.HandleIsReleased, pool.setColumn(handle3, .a, 43));
    try expect(!pool.setColumnIfLive(handle0, .a, 50));
    try expect(!pool.setColumnIfLive(handle1, .a, 51));
    try expect(!pool.setColumnIfLive(handle2, .a, 52));
    try expect(!pool.setColumnIfLive(handle3, .a, 53));

    // setColumnAssumeLive() would fail an assert()
}

test "Pool.setColumn*() calls ColumnType.deinit()" {
    const TestPool = Pool(2, 6, void, struct { a: DeinitCounter, b: DeinitCounter });

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    var deinit_count: u32 = 0;
    const handle = try pool.add(.{
        .a = DeinitCounter.init(&deinit_count),
        .b = DeinitCounter.init(&deinit_count),
    });
    try expectEqual(@as(u32, 0), deinit_count);

    try pool.setColumn(handle, .a, DeinitCounter.init(&deinit_count));
    try expectEqual(@as(u32, 1), deinit_count);
    try pool.setColumn(handle, .b, DeinitCounter.init(&deinit_count));
    try expectEqual(@as(u32, 2), deinit_count);

    try expect(pool.setColumnIfLive(handle, .a, DeinitCounter.init(&deinit_count)));
    try expectEqual(@as(u32, 3), deinit_count);
    try expect(pool.setColumnIfLive(handle, .b, DeinitCounter.init(&deinit_count)));
    try expectEqual(@as(u32, 4), deinit_count);

    pool.setColumnAssumeLive(handle, .a, DeinitCounter.init(&deinit_count));
    try expectEqual(@as(u32, 5), deinit_count);
    pool.setColumnAssumeLive(handle, .b, DeinitCounter.init(&deinit_count));
    try expectEqual(@as(u32, 6), deinit_count);
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "Pool.setColumns*()" {
    const TestPool = Pool(2, 6, void, struct { a: u32 });

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    try expectEqual(@as(usize, 0), pool.liveHandleCount());

    const handle0 = try pool.add(.{ .a = 0 });
    const handle1 = try pool.add(.{ .a = 1 });
    const handle2 = try pool.add(.{ .a = 2 });
    const handle3 = try pool.add(.{ .a = 3 });

    try expectEqual(@as(u32, 0), try pool.getColumn(handle0, .a));
    try expectEqual(@as(u32, 1), try pool.getColumn(handle1, .a));
    try expectEqual(@as(u32, 2), try pool.getColumn(handle2, .a));
    try expectEqual(@as(u32, 3), try pool.getColumn(handle3, .a));
    try expectEqual(@as(u32, 0), pool.getColumnIfLive(handle0, .a).?);
    try expectEqual(@as(u32, 1), pool.getColumnIfLive(handle1, .a).?);
    try expectEqual(@as(u32, 2), pool.getColumnIfLive(handle2, .a).?);
    try expectEqual(@as(u32, 3), pool.getColumnIfLive(handle3, .a).?);
    try expectEqual(@as(u32, 0), pool.getColumnAssumeLive(handle0, .a));
    try expectEqual(@as(u32, 1), pool.getColumnAssumeLive(handle1, .a));
    try expectEqual(@as(u32, 2), pool.getColumnAssumeLive(handle2, .a));
    try expectEqual(@as(u32, 3), pool.getColumnAssumeLive(handle3, .a));

    try pool.setColumns(handle0, .{ .a = 10 });
    try pool.setColumns(handle1, .{ .a = 11 });
    try pool.setColumns(handle2, .{ .a = 12 });
    try pool.setColumns(handle3, .{ .a = 13 });
    try expect(pool.setColumnsIfLive(handle0, .{ .a = 20 }));
    try expect(pool.setColumnsIfLive(handle1, .{ .a = 21 }));
    try expect(pool.setColumnsIfLive(handle2, .{ .a = 22 }));
    try expect(pool.setColumnsIfLive(handle3, .{ .a = 23 }));
    pool.setColumnsAssumeLive(handle0, .{ .a = 30 });
    pool.setColumnsAssumeLive(handle1, .{ .a = 31 });
    pool.setColumnsAssumeLive(handle2, .{ .a = 32 });
    pool.setColumnsAssumeLive(handle3, .{ .a = 33 });

    try expectEqual(@as(u32, 30), try pool.getColumn(handle0, .a));
    try expectEqual(@as(u32, 31), try pool.getColumn(handle1, .a));
    try expectEqual(@as(u32, 32), try pool.getColumn(handle2, .a));
    try expectEqual(@as(u32, 33), try pool.getColumn(handle3, .a));
    try expectEqual(@as(u32, 30), pool.getColumnIfLive(handle0, .a).?);
    try expectEqual(@as(u32, 31), pool.getColumnIfLive(handle1, .a).?);
    try expectEqual(@as(u32, 32), pool.getColumnIfLive(handle2, .a).?);
    try expectEqual(@as(u32, 33), pool.getColumnIfLive(handle3, .a).?);
    try expectEqual(@as(u32, 30), pool.getColumnAssumeLive(handle0, .a));
    try expectEqual(@as(u32, 31), pool.getColumnAssumeLive(handle1, .a));
    try expectEqual(@as(u32, 32), pool.getColumnAssumeLive(handle2, .a));
    try expectEqual(@as(u32, 33), pool.getColumnAssumeLive(handle3, .a));

    try pool.remove(handle0);
    try pool.remove(handle1);
    try pool.remove(handle2);
    try pool.remove(handle3);
    try expectError(TestPool.Error.HandleIsReleased, pool.setColumns(handle0, .{ .a = 40 }));
    try expectError(TestPool.Error.HandleIsReleased, pool.setColumns(handle1, .{ .a = 41 }));
    try expectError(TestPool.Error.HandleIsReleased, pool.setColumns(handle2, .{ .a = 42 }));
    try expectError(TestPool.Error.HandleIsReleased, pool.setColumns(handle3, .{ .a = 43 }));
    try expect(!pool.setColumnsIfLive(handle0, .{ .a = 50 }));
    try expect(!pool.setColumnsIfLive(handle1, .{ .a = 51 }));
    try expect(!pool.setColumnsIfLive(handle2, .{ .a = 52 }));
    try expect(!pool.setColumnsIfLive(handle3, .{ .a = 53 }));

    // setColumnsAssumeLive() would fail an assert()
}

test "Pool.setColumns() calls Columns.deinit()" {
    const TestPool = Pool(2, 6, void, DeinitCounter);

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    var deinit_count: u32 = 0;
    const handle = try pool.add(DeinitCounter.init(&deinit_count));
    try expectEqual(@as(u32, 0), deinit_count);

    try pool.setColumns(handle, DeinitCounter.init(&deinit_count));
    try expectEqual(@as(u32, 1), deinit_count);

    try expect(pool.setColumnsIfLive(handle, DeinitCounter.init(&deinit_count)));
    try expectEqual(@as(u32, 2), deinit_count);

    pool.setColumnsAssumeLive(handle, DeinitCounter.init(&deinit_count));
    try expectEqual(@as(u32, 3), deinit_count);
}

test "Pool.setColumns() calls ColumnType.deinit()" {
    const TestPool = Pool(2, 6, void, struct { a: DeinitCounter, b: DeinitCounter });

    var pool = try TestPool.initMaxCapacity(std.testing.allocator, .default);
    defer pool.deinit();

    var deinit_count: u32 = 0;
    const handle = try pool.add(.{
        .a = DeinitCounter.init(&deinit_count),
        .b = DeinitCounter.init(&deinit_count),
    });
    try expectEqual(@as(u32, 0), deinit_count);

    try pool.setColumns(handle, .{
        .a = DeinitCounter.init(&deinit_count),
        .b = DeinitCounter.init(&deinit_count),
    });
    try expectEqual(@as(u32, 2), deinit_count);

    try expect(pool.setColumnsIfLive(handle, .{
        .a = DeinitCounter.init(&deinit_count),
        .b = DeinitCounter.init(&deinit_count),
    }));
    try expectEqual(@as(u32, 4), deinit_count);

    pool.setColumnsAssumeLive(handle, .{
        .a = DeinitCounter.init(&deinit_count),
        .b = DeinitCounter.init(&deinit_count),
    });
    try expectEqual(@as(u32, 6), deinit_count);
}

test "Adds and removes triggering resize" {
    const TestPool = Pool(16, 16, void, struct {});

    var pool = TestPool.init(std.testing.allocator, .default);
    defer pool.deinit();

    var handles: std.ArrayListUnmanaged(TestPool.Handle) = .empty;
    defer handles.deinit(std.testing.allocator);

    for (0..16) |ix| {
        for (0..5 * ix) |_| {
            (try handles.addOne(std.testing.allocator)).* = try pool.add(.{});
        }

        for (0..3 * ix) |_| {
            const handle = handles.orderedRemove(0);
            try pool.remove(handle);
        }
    }
}

//------------------------------------------------------------------------------
