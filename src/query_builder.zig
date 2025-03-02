const std = @import("std");
const flecs = @import("flecs.zig");

pub const QueryBuilder = struct {
    world: flecs.World,
    desc: flecs.c.EcsSystemDesc,
    terms_count: usize = 0,

    pub fn init(world: flecs.World) @This() {
        return .{
            .world = world,
            .desc = std.mem.zeroes(flecs.c.EcsSystemDesc),
        };
    }

    /// adds an InOut (read/write) component to the query
    pub fn with(self: *@This(), comptime T: type) *@This() {
        self.desc.query.filter.terms[self.terms_count].id = self.world.componentId(T);
        self.terms_count += 1;
        return self;
    }

    pub fn withReadonly(self: *@This(), comptime T: type) *@This() {
        self.desc.query.filter.terms[self.terms_count].id = self.world.componentId(T);
        self.desc.query.filter.terms[self.terms_count].inout = .ecs_in;
        self.terms_count += 1;
        return self;
    }

    pub fn withWriteonly(self: *@This(), comptime T: type) *@This() {
        self.desc.query.filter.terms[self.terms_count].id = self.world.componentId(T);
        self.desc.query.filter.terms[self.terms_count].inout = .ecs_out;
        self.terms_count += 1;
        return self;
    }

    /// the term will be used for the query but it is neither read nor written
    pub fn withFilter(self: *@This(), comptime T: type) *@This() {
        self.desc.query.filter.terms[self.terms_count].id = self.world.componentId(T);
        self.desc.query.filter.terms[self.terms_count].inout = .ecs_in_out_none;
        self.terms_count += 1;
        return self;
    }

    pub fn without(self: *@This(), comptime T: type) *@This() {
        self.desc.query.filter.terms[self.terms_count] = std.mem.zeroInit(flecs.c.EcsTerm, .{
            .id = self.world.componentId(T),
            .oper = .ecs_not,
        });
        self.terms_count += 1;
        return self;
    }

    pub fn optional(self: *@This(), comptime T: type) *@This() {
        self.desc.query.filter.terms[self.terms_count] = std.mem.zeroInit(flecs.c.EcsTerm, .{
            .id = self.world.componentId(T),
            .oper = .ecs_optional,
        });
        self.terms_count += 1;
        return self;
    }

    pub fn either(self: *@This(), comptime T1: type, comptime T2: type) *@This() {
        self.desc.query.filter.terms[self.terms_count] = std.mem.zeroInit(flecs.c.EcsTerm, .{
            .id = self.world.componentId(T1),
            .oper = .ecs_or,
        });
        self.terms_count += 1;
        self.desc.query.filter.terms[self.terms_count] = std.mem.zeroInit(flecs.c.EcsTerm, .{
            .id = self.world.componentId(T2),
            .oper = .ecs_or,
        });
        self.terms_count += 1;
        return self;
    }

    /// the query will need to match `T1 || T2` but it will not return data for either column
    pub fn eitherAsFilter(self: *@This(), comptime T1: type, comptime T2: type) *@This() {
        _ = self.either(T1, T2);
        self.desc.query.filter.terms[self.terms_count - 1].inout = .ecs_in_out_none;
        self.desc.query.filter.terms[self.terms_count - 2].inout = .ecs_in_out_none;
        return self;
    }

    pub fn manualTerm(self: *@This()) *flecs.c.EcsTerm {
        self.terms_count += 1;
        return &self.desc.query.filter.terms[self.terms_count - 1];
    }

    /// inject a plain old string expression into the builder
    pub fn expression(self: *@This(), expr: [*c]const u8) *@This() {
        self.desc.filter.expr = expr;
        return self;
    }

    pub fn singleton(self: *@This(), comptime T: type, entity: flecs.EntityId) *@This() {
        self.desc.filter.terms[self.terms_count] = std.mem.zeroInit(flecs.c.EcsTerm, .{ .id = self.world.componentId(T) });
        self.desc.filter.terms[self.terms_count].subj.entity = entity;
        self.terms_count += 1;
        return self;
    }

    pub fn buildFilter(self: *@This()) flecs.Filter {
        return flecs.Filter.init(self.world, &self.desc.query.filter);
    }

    pub fn buildQuery(self: *@This()) flecs.Query {
        return flecs.Query.init(self.world, &self.desc.query);
    }

    /// queries/system only
    pub fn orderBy(self: *@This(), comptime T: type, orderByFn: fn (flecs.EntityId, ?*const anyopaque, flecs.EntityId, ?*const anyopaque) callconv(.C) c_int) *@This() {
        self.desc.query.order_by_component = self.world.componentId(T);
        self.desc.query.order_by = orderByFn;
        return self;
    }

    /// queries/system only
    pub fn orderByEntity(self: *@This(), orderByFn: fn (flecs.EntityId, ?*const anyopaque, flecs.EntityId, ?*const anyopaque) callconv(.C) c_int) *@This() {
        self.desc.query.order_by = orderByFn;
        return self;
    }

    /// systems only. This system callback will be called at least once for each table that matches the query
    pub fn callback(self: *@This(), cb: fn ([*c]flecs.c.ecs_iter_t) callconv(.C) void) *@This() {
        self.callback = cb;
        return self;
    }

    /// systems only. This system callback will only be called once. The iterator should then be iterated with ecs_iter_next.
    pub fn run(self: *@This(), cb: fn ([*c]flecs.c.ecs_iter_t) callconv(.C) void) *@This() {
        self.desc.run = cb;
        return self;
    }
};
