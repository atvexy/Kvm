const std = @import("std");
const bc = @import("kvm-bcode.zig");
const comp = @import("kvm-compiler.zig");

pub const KvmResult = enum(c_int) {
    success = 0,
    in_progress,
    unknown_error, // used for system errors like out of memory, when unknown_error is returned as result the actual error will be printed to the teminal
    not_initialized, // unless in init(), then equals to .already_initialized
    file_not_found,
    compilation_error, // error will be printed to the terminal also
    state_not_valid,
    symbol_not_found,
    step_out_of_bounds,
    pickup_zero_flags,
    place_max_flags,
    stop_encountered,
};

const Karel = struct {
    // home position on the map, (0, 0) is bottom-left
    home_x: u32,
    home_y: u32,

    // karels position on the map, (0, 0) is bottom-left
    pos_x: u32,
    pos_y: u32,

    // direction what kaler is facing, range 0 to 3 representing North, East, South and West
    dir: u2,

    // checks and simulates a step and returns it
    pub fn get_step(self: *const Karel, comptime map_size: u32) ?struct { x: u32, y: u32 } {
        //switch (self.dir) {
        //    0 => {
        //        if (self.pos_y + 1 == map_size) return null;
        //        return .{ .x = self.pos_x, .y = self.pos_y + 1 };
        //    },
        //
        //    1 => {
        //        if (self.pos_x == 0) return null;
        //        return .{ .x = self.pos_x - 1, .y = self.pos_y };
        //    },
        //
        //    2 => {
        //        if (self.pos_y == 0) return null;
        //        return .{ .x = self.pos_x, .y = self.pos_y - 1 };
        //    },
        //
        //    3 => {
        //        if (self.pos_x + 1 == map_size) return null;
        //        return .{ .x = self.pos_x + 1, .y = self.pos_y };
        //    },
        //}

        // optimized for modern processors with extensive pipelines (hopefully allows for less branch misses and mainly less pipeline flushes)
        // the above switch is (at least should be) equivalent to the following

        const is_even = self.dir % 2; // used to figure out the plane (x axis or y axis)
        const dir = self.dir >> 1; // efficient hack to skip the required cmp instruction (saving costly pipeline flushes), figures out if it should increment or decrement along the axis

        if ((is_even == 1 and self.pos_x == (map_size - 1) * (dir)) or
            (is_even == 0 and self.pos_y == (map_size - 1) * (1 - dir))) return null;

        const offset: i3 = (1 - @as(i3, dir) * 2); // precompute the offset

        return .{
            .x = @intCast(@as(i33, self.pos_x) + -offset * (is_even)),
            .y = @intCast(@as(i33, self.pos_y) + offset * (1 - is_even)),
        };
    }
};

const City = struct {
    pub const max_flags = 8; // max flags on a single square
    pub const map_size = 20; // city size, kvm only supports square maps, must be a multiple of 2

    // 4 bits per square, 0 to 8 is a non-wall square with that number of flags, ~0 (bitwise not) is a wall
    const CityByte = packed struct { s1: u4, s2: u4 };

    storage: [map_size * map_size / 2]CityByte,

    // storage accessors
    // Warning: accessing out of bound is Undefined Behaviour

    pub fn get_square(self: *const City, x: u32, y: u32) u4 {
        const data: u8 = @bitCast(self.storage[(x + y * map_size) / 2]);

        // return if (x % 2 == 1) data.s2 else data.s1;

        // equivalent to the code above but solved using bitwise shifting instead of branching
        return @intCast((data >> @as(u3, @intCast(x % 2)) * 4) & 0x0f);
    }

    pub fn set_square(self: *City, x: u32, y: u32, data: u4) void {
        const stored_data: *CityByte = @ptrCast(&self.storage[(x + y * map_size) / 2]);

        // here the branching method is actually faster then the bitwise method, this is why you always test every change you make
        if (x % 2 == 1) stored_data.s2 = data else stored_data.s1 = data;

        // const mask: u8 = @as(u8, 0x0f) << @as(u3, @intCast(x % 2)) * 4;
        //
        // stored_data.* &= ~mask;
        // stored_data.* |= data & mask;
    }
};

const LookupSymbolError = error{SymbolNotFound};
const RunFuncError = error{ StepOutOfBounds, PickupZeroFlags, PlaceMaxFlags, StopEncountered };

pub const Kvm = struct {
    // Kvm is tuned for fast and efficient execution until you reach this max function depth limit, where it falls back to allocating more stack at runtime
    pub const maxFastDepth = 512;
    pub const map_size = City.map_size;

    allocator: std.mem.Allocator,

    karel: Karel = undefined,
    city: City = undefined,

    // see kvm-bcode.zig for explanation
    bcode: std.ArrayList(u8),
    symbol_map: std.StringHashMap(bc.Func),

    // load state
    bcode_valid: bool = false,
    world_valid: bool = false,

    m: std.Thread.Mutex = std.Thread.Mutex{},

    // comunicates the interpreter status back to the main thread
    inter_status: std.atomic.Atomic(KvmResult),

    // used by main thread to stop the interpreter thread, see run_func()
    interupt_short: u1 = 1,

    pub fn init(allocator: std.mem.Allocator) !Kvm {
        var vm = Kvm{
            .allocator = allocator,
            .bcode = std.ArrayList(u8).init(allocator),
            .symbol_map = std.StringHashMap(bc.Func).init(allocator),
            .inter_status = std.atomic.Atomic(KvmResult).init(.success),
        };

        return vm;
    }

    pub fn deinit(self: *Kvm) void {
        self.m.lock();

        self.bcode.deinit();

        //{
        //    var iter = self.symbol_map.keyIterator();
        //
        //    while (iter.next()) |key| {
        //        self.allocator.destroy(key);
        //    }
        //
        //    self.symbol_map.deinit();
        //}
    }

    pub fn load(self: *Kvm, src: []const u8) !void {
        self.m.lock();
        defer self.m.unlock();

        self.bcode.clearRetainingCapacity();
        self.symbol_map.clearRetainingCapacity();

        var src_stream = std.io.fixedBufferStream(src);

        try comp.compile(src_stream.reader(), self.allocator, &self.bcode, &self.symbol_map);

        self.bcode_valid = true;
    }

    pub fn load_file(self: *Kvm, path: []const u8) !void {
        self.m.lock();
        defer self.m.unlock();

        self.bcode.clearRetainingCapacity();
        self.symbol_map.clearRetainingCapacity();

        try comp.compileFile(path, self.allocator, &self.bcode, &self.symbol_map);

        self.bcode_valid = true;
    }

    pub fn load_world(self: *Kvm, buf: []const u8, k_buf: []const u32) void {
        self.m.lock();
        defer self.m.unlock();

        self.karel = Karel{
            .home_x = k_buf[3],
            .home_y = k_buf[4],
            .pos_x = k_buf[0],
            .pos_y = k_buf[1],
            .dir = @intCast(k_buf[2]),
        };

        // clear map
        self.city = City{ .storage = undefined };

        for (buf, 0..) |square, i| {
            const stored_data: *City.CityByte = @ptrCast(&self.city.storage[i / 2]);
            const data: u4 = if (square != 255) @intCast(square) else ~@as(u4, 0);

            if (i % 2 == 1) stored_data.s2 = data else stored_data.s1 = data;
        }

        self.world_valid = true;
    }

    // symbols

    pub fn run_symbol(self: *Kvm, symbol: bc.Symbol) !void {
        self.m.lock();
        defer self.m.unlock();

        const func = self.lookup_symbol(symbol);
        if (func == null) return error.SymbolNotFound;

        self.inter_status.store(.in_progress, std.builtin.AtomicOrder.Release);
        self.interupt_short = 1;

        // can't automatically multithread in shared library mode due to: https://github.com/ziglang/zig/issues/15336
        // const t = try std.Thread.spawn(.{}, run_func, .{ self, func.? });

        try self.run_func(func.?);

        // t.detach();
    }

    pub fn dump_loaded_symbols(self: *const Kvm) void {
        var iter = self.symbol_map.iterator();

        std.log.info("Kvm Loaded Symbols:", .{});

        while (iter.next()) |entry| {
            std.log.info("  symbol: \"{s}\" func: 0x{x}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    fn lookup_symbol(self: *const Kvm, symbol: bc.Symbol) ?bc.Func {
        return self.symbol_map.get(symbol);
    }

    pub fn short_circuit(self: *Kvm) void {
        self.interupt_short = 0;
    }

    pub fn read_world(self: *const Kvm, buf: []u8) !void {
        if (self.world_valid) {
            var x: u32 = 0;
            while (x < City.map_size) : (x += 1) {
                var y: u32 = 0;
                while (y < City.map_size) : (y += 1) {
                    const val: u8 = @as(u8, self.city.get_square(x, y));

                    if (val == ~@as(u4, 0)) {
                        buf[x + y * City.map_size] = 255;
                    } else {
                        buf[x + y * City.map_size] = val;
                    }
                }
            }
        } else return error.KvmStateNotValid;
    }

    // interpreter (inter thread)

    fn run_func(self: *Kvm, func_entry: bc.Func) !void {
        if (!(self.bcode_valid and self.world_valid)) return error.KvmStateNotValid;

        // ordered from cold to hot vars

        // represents the function call (and repeat) stack for retn (and repeat stacks)
        var func_stack: std.ArrayList(bc.Func) = std.ArrayList(bc.Func).init(self.allocator);
        var repeat_stack: std.ArrayList(u16) = std.ArrayList(u16).init(self.allocator);

        defer func_stack.deinit();
        defer repeat_stack.deinit();

        // prealloc stack to avoid allocations bellow maxFastDepth
        try func_stack.ensureTotalCapacity(Kvm.maxFastDepth);
        try repeat_stack.ensureTotalCapacity(Kvm.maxFastDepth);

        var repeat_state: ?u16 = null;
        var repeat_origin: ?bc.Func = null;

        // essentially Karel's program counter
        var func: bc.Func = func_entry;

        var func_depth: u32 = 1;

        // entering hot loop
        while (true) {
            // reading the next opcode
            // multiplying by interupt_short to redirect the bcode execution to 0x0 if an interupt was triggered by main thread
            const opcode: bc.KvmByte = @bitCast(self.bcode.items[func * self.interupt_short]);

            switch (opcode.opcode) {
                bc.KvmOpCode.step => {
                    const step = self.karel.get_step(City.map_size);

                    if (if (step) |s| ~self.city.get_square(s.x, s.y) != 0 else false) {
                        self.karel.pos_x = step.?.x;
                        self.karel.pos_y = step.?.y;

                        std.log.debug("step: {} {} {}", .{ step.?.x, step.?.y, self.karel.dir });
                    } else {
                        self.inter_status.store(.step_out_of_bounds, std.builtin.AtomicOrder.Release);
                        return;
                    }

                    func += 1;
                },

                bc.KvmOpCode.left => {
                    self.karel.dir +%= 1;
                    func += 1;

                    std.log.debug("left: {}", .{self.karel.dir});
                },

                bc.KvmOpCode.pick_up => {
                    const tags = self.city.get_square(self.karel.pos_x, self.karel.pos_y);

                    if (tags != 0) {
                        self.city.set_square(self.karel.pos_x, self.karel.pos_y, tags - 1);

                        std.log.debug("pick_up: {}", .{tags - 1});
                    } else {
                        self.inter_status.store(.pickup_zero_flags, std.builtin.AtomicOrder.Release);
                        return;
                    }

                    func += 1;
                },

                bc.KvmOpCode.place => {
                    const tags = self.city.get_square(self.karel.pos_x, self.karel.pos_y);

                    if (tags != City.max_flags) {
                        self.city.set_square(self.karel.pos_x, self.karel.pos_y, tags + 1);

                        std.log.debug("place: {}", .{tags + 1});
                    } else {
                        self.inter_status.store(.place_max_flags, std.builtin.AtomicOrder.Release);
                        return;
                    }

                    func += 1;
                },

                bc.KvmOpCode.repeat => {
                    if (repeat_origin != func) {
                        if (repeat_origin) |f| {
                            // save in-progress loop onto the stack

                            func_stack.appendAssumeCapacity(f);
                            repeat_stack.appendAssumeCapacity(repeat_state.?);
                        }

                        // setup a new loop
                        repeat_origin = func;
                        repeat_state = bc.get_repeat_index(self.bcode.items[func .. func + 7]);

                        try incrementDepth(&func_depth, &func_stack, &repeat_stack);
                    }

                    if (repeat_state == 1) {
                        // finished loop

                        if (repeat_stack.items.len != 0) {
                            // resume loop from stack

                            repeat_origin = func_stack.pop();
                            repeat_state = repeat_stack.pop();
                        } else {
                            // all in-progress loops done

                            repeat_origin = null;
                            repeat_state = null;
                        }

                        func += 7;
                        func_depth -= 1;

                        std.log.debug("repeat: finished", .{});
                        continue;
                    }

                    // repeat instruction is at the *bottom* of the loop (pointing to the top)
                    repeat_state.? -= 1;

                    // continue looping
                    const repeat_func = bc.get_repeat_func(self.bcode.items[func .. func + 7]);

                    func = repeat_func;
                    std.log.debug("repeat: {} 0x{x}", .{ repeat_state.?, repeat_func });
                },

                bc.KvmOpCode.branch => {
                    // const cond = @call(.never_inline, Kvm.test_cond, .{ self, opcode });
                    const cond = self.test_cond(opcode);

                    if (cond == false) {
                        func += 5;

                        std.log.debug("branch: unmet", .{});
                        // continue;
                    } else {
                        func = bc.get_branch_func(self.bcode.items[func .. func + 5]);

                        std.log.debug("branch: 0x{x}", .{func});
                    }
                },

                bc.KvmOpCode.branch_linked => {
                    // linked branches are only used for symbol calls, which don't support conditions in vanilla karel-lang
                    //
                    // const cond = self.test_cond(opcode);
                    //
                    // if (cond == false) {
                    //     func += 5;
                    //
                    //     std.log.debug("branch_linked: unmet", .{});
                    //     continue;
                    // }

                    try incrementDepth(&func_depth, &func_stack, &repeat_stack);

                    func_stack.appendAssumeCapacity(func + 5);
                    func = bc.get_branch_func(self.bcode.items[func .. func + 5]);

                    std.log.debug("branch_linked: 0x{x}", .{func});
                },

                bc.KvmOpCode.retn => {
                    const ret_func: ?bc.Func = func_stack.popOrNull();

                    func_depth -= 1;

                    if (ret_func == null) {
                        std.log.debug("retn: final", .{});

                        self.inter_status.store(.success, std.builtin.AtomicOrder.Release);
                        return; // end of root function
                    }

                    func = ret_func.?; // return from linked call
                    std.log.debug("retn: 0x{x}", .{ret_func.?});
                },

                bc.KvmOpCode.stop => {
                    std.log.debug("stop: final", .{});

                    self.inter_status.store(.stop_encountered, std.builtin.AtomicOrder.Release);
                    return;
                },
            }
        }

        unreachable;
    }

    // test if a condition is true
    fn test_cond(self: *const Kvm, opcode: bc.KvmByte) bool {
        var result: bool = undefined;

        switch (opcode.condcode) {
            bc.KvmCondition.is_wall => {
                const step = self.karel.get_step(City.map_size);

                result = if (step) |s| ~self.city.get_square(s.x, s.y) == 0 else true;
            },

            bc.KvmCondition.is_flag => {
                result = self.city.get_square(self.karel.pos_x, self.karel.pos_y) != 0;
            },

            bc.KvmCondition.is_home => {
                result = self.karel.pos_x == self.karel.home_x and self.karel.pos_y == self.karel.home_y;
            },

            bc.KvmCondition.is_north => {
                result = self.karel.dir == 0;
            },

            bc.KvmCondition.is_west => {
                result = self.karel.dir == 1;
            },

            bc.KvmCondition.is_south => {
                result = self.karel.dir == 2;
            },

            bc.KvmCondition.is_east => {
                result = self.karel.dir == 3;
            },

            bc.KvmCondition.none => {
                result = true;
            },
        }

        return result != opcode.cond_inverse; // effectivelly a xor
    }

    inline fn incrementDepth(depth: *u32, fstack: *std.ArrayList(bc.Func), rstack: *std.ArrayList(u16)) !void {
        depth.* += 1;
        if (depth.* > Kvm.maxFastDepth) try fallbackAllocations(fstack, rstack);
    }

    fn fallbackAllocations(fstack: *std.ArrayList(bc.Func), rstack: *std.ArrayList(u16)) !void {
        @setCold(true); // tell the optimizer to banish this function from being viewed as a function that is called often

        try fstack.ensureUnusedCapacity(16);
        try rstack.ensureUnusedCapacity(16);
    }
};

test "City loading and accessing" {
    const c_data = [20]u8{ 0xa1, 0x1f, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const c = City.init(&c_data, 20);

    try std.testing.expect(@sizeOf(City.CityByte) == 1);
    try std.testing.expect(@bitSizeOf(City.CityByte) == 8);

    try std.testing.expect(c.get_square(0, 0) == 0x01);
    try std.testing.expect(c.get_square(1, 0) == 0x0a);

    try std.testing.expect(c.get_square(2, 0) == 0x0f);
}

test "City writing" {
    const c_data = [20]u8{ 0xa1, 0x1f, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var c = City.init(&c_data, 20);

    c.set_square(0, 0, 0x0f);

    try std.testing.expect(c.get_square(0, 0) == 0x0f);
    try std.testing.expect(c.get_square(1, 0) == 0x0a);

    c.set_square(1, 0, 0x0b);

    try std.testing.expect(c.get_square(0, 0) == 0x0f);
    try std.testing.expect(c.get_square(1, 0) == 0x0b);
}

test "Karel Direction Overflow" {
    const val: u2 = 3; // the u2 is important here

    try std.testing.expect(val +% 1 == 0);
}
