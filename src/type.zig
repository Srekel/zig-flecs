const std = @import("std");
const flecs = @import("flecs.zig");

pub const Type = struct {
    world: *flecs.c.EcsWorld,
    type: flecs.c.EcsType,

    pub fn init(world: *flecs.c.EcsWorld, t: flecs.c.EcsType) Type {
        return .{ .world = world, .type = t.? };
    }

    /// returns the number of component ids in the type
    pub fn count(self: Type) usize {
        return @intCast(usize, flecs.c.ecs_vector_count(self.type.?));
    }

    /// returns the formatted list of components in the type
    pub fn asString(self: Type) []const u8 {
        const str = flecs.c.ecs_type_str(self.world, self.type);
        const len = std.mem.len(str);
        return str[0..len];
    }

    /// returns an array of component ids
    pub fn toArray(self: Type) []const flecs.EntityId {
        return @ptrCast([*c]const flecs.EntityId, @alignCast(@alignOf(u64), flecs.c._ecs_vector_first(self.type, @sizeOf(u64), @alignOf(u64))))[1 .. self.count() + 1];
    }
};
