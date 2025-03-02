const std = @import("std");
const flecs = @import("flecs.zig");
const meta = @import("meta.zig");

pub fn TableIterator(comptime Components: type) type {
    std.debug.assert(@typeInfo(Components) == .Struct);

    const Columns = meta.TableIteratorData(Components);

    return struct {
        pub const InnerIterator = struct {
            data: Columns = undefined,
            count: i32,
        };

        iter: *flecs.c.EcsIter,
        nextFn: fn ([*c]flecs.c.EcsIter) callconv(.C) bool,

        pub fn init(iter: *flecs.c.EcsIter, nextFn: fn ([*c]flecs.c.EcsIter) callconv(.C) bool) @This() {
            meta.validateIterator(Components, iter);
            return .{
                .iter = iter,
                .nextFn = nextFn,
            };
        }

        pub fn tableType(self: *@This()) flecs.Type {
            return flecs.Type.init(self.iter.world.?, self.iter.type);
        }

        pub fn skip(self: *@This()) void {
            meta.assertMsg(self.nextFn == flecs.c.ecs_query_next, "skip only valid on Queries!", .{});
            flecs.c.ecs_query_skip(self.iter);
        }

        pub fn next(self: *@This()) ?InnerIterator {
            if (!self.nextFn(self.iter)) return null;

            var iter: InnerIterator = .{ .count = self.iter.count };
            var index: usize = 0;
            inline for (@typeInfo(Components).Struct.fields, 0..) |field, i| {
                // skip filters since they arent returned when we iterate
                while (self.iter.terms[index].inout == .ecs_in_out_none) : (index += 1) {}

                const is_optional = @typeInfo(field.type) == .Optional;
                const col_type = meta.FinalChild(field.type);
                if (meta.isConst(field.type)) std.debug.assert(flecs.c.ecs_field_is_readonly(self.iter, i + 1));

                if (is_optional) @field(iter.data, field.name) = null;
                const column_index = self.iter.terms[index].index;
                var skip_term = if (is_optional) meta.componentHandle(col_type).* != flecs.c.ecs_term_id(&self.iter, @intCast(column_index + 1)) else false;

                // note that an OR is actually a single term!
                // std.debug.print("---- col_type: {any}, optional: {any}, i: {d}, col_index: {d}\n", .{ col_type, is_optional, i, column_index });
                if (!skip_term) {
                    if (flecs.columnOpt(self.iter, col_type, column_index + 1)) |col| {
                        @field(iter.data, field.name) = col;
                    }
                }
                index += 1;
            }

            return iter;
        }
    };
}
