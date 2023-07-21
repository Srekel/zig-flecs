const std = @import("std");
const flecs = @import("flecs.zig");
const utils = @import("utils.zig");
const meta = @import("meta.zig");

const Entity = flecs.Entity;
const FlecsOrderByAction = fn (flecs.c.EcsEntity, ?*const anyopaque, flecs.c.EcsEntity, ?*const anyopaque) callconv(.C) c_int;

fn dummyFn(_: [*c]flecs.c.EcsIter) callconv(.C) void {}

const SystemParameters = struct {
    ctx: ?*anyopaque,
};

pub const World = struct {
    world: *flecs.c.EcsWorld,

    pub fn init() World {
        return .{ .world = flecs.c.ecs_init().? };
    }

    pub fn deinit(self: *World) void {
        _ = flecs.c.ecs_fini(self.world);
    }

    pub fn setTargetFps(self: World, fps: f32) void {
        flecs.c.ecs_set_target_fps(self.world, fps);
    }

    /// available at: https://www.flecs.dev/explorer/?remote=true
    /// test if running: http://localhost:27750/entity/flecs
    pub fn enableWebExplorer(self: World) void {
        _ = flecs.c.ecs_set_id(self.world, flecs.c.FLECS__EEcsRest, flecs.c.FLECS__EEcsRest, @sizeOf(flecs.c.EcsRest), &std.mem.zeroes(flecs.c.EcsRest));
    }

    /// -1 log level turns off logging
    pub fn setLogLevel(_: World, level: c_int, enable_colors: bool) void {
        _ = flecs.c.ecs_log_set_level(level);
        _ = flecs.c.ecs_log_enable_colors(enable_colors);
    }

    pub fn progress(self: World, delta_time: f32) void {
        _ = flecs.c.ecs_progress(self.world, delta_time);
    }

    pub fn getTypeStr(self: World, typ: flecs.c.EcsType) [*c]u8 {
        return flecs.c.ecs_type_str(self.world, typ);
    }

    pub fn newEntity(self: World) Entity {
        return Entity.init(self.world, flecs.c.ecs_new_id(self.world));
    }

    pub fn newEntityWithName(self: World, name: [*c]const u8) Entity {
        var desc = std.mem.zeroInit(flecs.c.ecs_entity_desc_t, .{ .name = name });
        return Entity.init(self.world, flecs.c.ecs_entity_init(self.world, &desc));
    }

    pub fn newPrefab(self: World, name: [*c]const u8) Entity {
        var desc = std.mem.zeroInit(flecs.c.EcsEntityDesc, .{
            .name = name,
            .add = [_]flecs.c.EcsId{0} ** 32,
        });
        desc.add[0] = flecs.c.Constants.EcsPrefab;
        return Entity.init(self.world, flecs.c.ecs_entity_init(self.world, &desc));
    }

    /// Allowed params: Entity, EntityId, type
    pub fn pair(self: World, relation: anytype, object: anytype) u64 {
        const Relation = @TypeOf(relation);
        const Object = @TypeOf(object);

        const rel_info = @typeInfo(Relation);
        const obj_info = @typeInfo(Object);

        std.debug.assert(rel_info == .Struct or rel_info == .Type or Relation == flecs.EntityId or Relation == flecs.Entity or Relation == c_int);
        std.debug.assert(obj_info == .Struct or obj_info == .Type or Object == flecs.EntityId or Object == flecs.Entity);

        const rel_id = switch (Relation) {
            c_int => @as(flecs.EntityId, @intCast(relation)),
            type => self.componentId(relation),
            flecs.EntityId => relation,
            flecs.Entity => relation.id,
            else => unreachable,
        };

        const obj_id = switch (Object) {
            type => self.componentId(object),
            flecs.EntityId => object,
            flecs.Entity => object.id,
            else => unreachable,
        };

        return flecs.c.Constants.ECS_PAIR | (rel_id << @as(u32, 32)) + @as(u32, @truncate(obj_id));
    }

    /// bulk registers a tuple of Types
    pub fn registerComponents(self: World, types: anytype) void {
        std.debug.assert(@typeInfo(@TypeOf(types)) == .Struct);
        inline for (types) |t| {
            _ = self.componentId(t);
        }
    }

    /// gets the EntityId for T creating it if it doesn't already exist
    pub fn componentId(self: World, comptime T: type) flecs.EntityId {
        return meta.componentId(self.world, T);
    }

    /// creates a new type entity, or finds an existing one. A type entity is an entity with the EcsType component. The name will be generated
    /// by adding the Ids of each component so that order doesnt matter.
    pub fn newType(self: World, comptime Types: anytype) flecs.EntityId {
        var i: flecs.EntityId = 0;
        inline for (Types) |T| {
            i += self.componentId(T);
        }

        const name = std.fmt.allocPrintZ(std.heap.c_allocator, "Type{d}", .{i}) catch unreachable;
        return self.newTypeWithName(name, Types);
    }

    /// creates a new type entity, or finds an existing one. A type entity is an entity with the EcsType component.
    pub fn newTypeWithName(self: World, name: [*c]const u8, comptime Types: anytype) flecs.EntityId {
        var desc = std.mem.zeroes(flecs.c.ecs_type_desc_t);
        desc.entity = std.mem.zeroInit(flecs.c.ecs_entity_desc_t, .{ .name = name });

        inline for (Types, 0..) |T, i| {
            desc.ids[i] = self.componentId(T);
        }

        return flecs.c.ecs_type_init(self.world, &desc);
    }

    pub fn newTypeExpr(self: World, name: [*c]const u8, expr: [*c]const u8) flecs.EntityId {
        var desc = std.mem.zeroInit(flecs.c.ecs_type_desc_t, .{ .ids_expr = expr });
        desc.entity = std.mem.zeroInit(flecs.c.ecs_entity_desc_t, .{ .name = name });

        return flecs.c.ecs_type_init(self.world, &desc);
    }

    /// this operation will preallocate memory in the world for the specified number of entities
    pub fn dim(self: World, entity_count: i32) void {
        flecs.c.ecs_dim(self.world, entity_count);
    }

    /// this operation will preallocate memory for a type (table) for the specified number of entities
    pub fn dimType(self: World, ecs_type: flecs.c.EcsType, entity_count: i32) void {
        flecs.c.ecs_dim_type(self.world, ecs_type, entity_count);
    }

    pub fn newSystem(self: World, name: [*c]const u8, phase: flecs.Phase, signature: [*c]const u8, action: flecs.c.EcsIterAction) void {
        var desc = std.mem.zeroes(flecs.c.EcsSystemDesc);
        desc.entity.name = name;
        desc.entity.add[0] = @intFromEnum(phase);
        desc.query.filter.expr = signature;
        // desc.multi_threaded = true;
        desc.callback = action;
        _ = flecs.c.ecs_system_init(self.world, &desc);
    }

    pub fn newRunSystem(self: World, name: [*c]const u8, phase: flecs.Phase, signature: [*c]const u8, action: flecs.c.EcsIterAction) void {
        var desc = std.mem.zeroes(flecs.c.EcsSystemDesc);
        desc.entity.name = name;
        desc.entity.add[0] = @intFromEnum(phase);
        desc.query.filter.expr = signature;
        // desc.multi_threaded = true;
        desc.callback = dummyFn;
        desc.run = action;
        _ = flecs.c.ecs_system_init(self.world, &desc);
    }

    pub fn newWrappedRunSystem(self: World, name: [*c]const u8, phase: flecs.Phase, comptime Components: type, comptime action: fn (*flecs.Iterator(Components)) void, params: SystemParameters) flecs.EntityId {
        var edesc = std.mem.zeroes(flecs.c.EcsEntityDesc);

        edesc.id = 0;
        edesc.name = name;
        edesc.add[0] = flecs.ecs_pair(flecs.c.Constants.EcsDependsOn, @intFromEnum(phase));
        edesc.add[1] = @intFromEnum(phase);

        var desc = std.mem.zeroes(flecs.c.EcsSystemDesc);
        desc.entity = flecs.c.ecs_entity_init(self.world, &edesc);
        desc.query.filter = meta.generateFilterDesc(self, Components);
        desc.callback = dummyFn;
        desc.run = wrapSystemFn(Components, action);
        desc.ctx = params.ctx;
        return flecs.c.ecs_system_init(self.world, &desc);
    }

    /// creates a Filter using the passed in struct
    pub fn filter(self: World, comptime Components: type) flecs.Filter {
        std.debug.assert(@typeInfo(Components) == .Struct);
        var desc = meta.generateFilterDesc(self, Components);
        return flecs.Filter.init(self, &desc);
    }

    /// probably temporary until we find a better way to handle it better, but a way to
    /// iterate the passed components of children of the parent entity
    pub fn filterParent(self: World, comptime Components: type, parent: flecs.Entity) flecs.Filter {
        std.debug.assert(@typeInfo(Components) == .Struct);
        var desc = meta.generateFilterDesc(self, Components);
        const component_info = @typeInfo(Components).Struct;
        desc.terms[component_info.fields.len].id = self.pair(flecs.c.EcsChildOf, parent);
        return flecs.Filter.init(self, &desc);
    }

    /// creates a Query using the passed in struct
    pub fn query(self: World, comptime Components: type) flecs.Query {
        std.debug.assert(@typeInfo(Components) == .Struct);
        var desc = std.mem.zeroes(flecs.c.ecs_query_desc_t);
        desc.filter = meta.generateFilterDesc(self, Components);

        if (@hasDecl(Components, "order_by")) {
            meta.validateOrderByFn(Components.order_by);
            const ti = @typeInfo(@TypeOf(Components.order_by));
            const OrderByType = meta.FinalChild(ti.Fn.args[1].arg_type.?);
            meta.validateOrderByType(Components, OrderByType);

            desc.order_by = wrapOrderByFn(OrderByType, Components.order_by);
            desc.order_by_component = self.componentId(OrderByType);
        }

        if (@hasDecl(Components, "instanced") and Components.instanced) desc.filter.instanced = true;

        return flecs.Query.init(self, &desc);
    }

    /// adds a system to the World using the passed in struct
    pub fn system(self: World, comptime Components: type, phase: flecs.Phase) void {
        std.debug.assert(@typeInfo(Components) == .Struct);
        std.debug.assert(@hasDecl(Components, "run"));
        std.debug.assert(@hasDecl(Components, "name"));

        var desc = std.mem.zeroes(flecs.c.EcsSystemDesc);
        desc.callback = dummyFn;
        desc.entity.name = Components.name;
        desc.entity.add[0] = @intFromEnum(phase);
        // desc.multi_threaded = true;
        desc.run = wrapSystemFn(Components, Components.run);
        desc.query.filter = meta.generateFilterDesc(self, Components);

        if (@hasDecl(Components, "order_by")) {
            meta.validateOrderByFn(Components.order_by);
            const ti = @typeInfo(@TypeOf(Components.order_by));
            const OrderByType = meta.FinalChild(ti.Fn.args[1].arg_type.?);
            meta.validateOrderByType(Components, OrderByType);

            desc.query.order_by = wrapOrderByFn(OrderByType, Components.order_by);
            desc.query.order_by_component = self.componentId(OrderByType);
        }

        if (@hasDecl(Components, "instanced") and Components.instanced) desc.filter.instanced = true;

        _ = flecs.c.ecs_system_init(self.world, &desc);
    }

    /// adds an observer system to the World using the passed in struct (see systems)
    pub fn observer(self: World, comptime Components: type, event: flecs.Event, ctx: ?*anyopaque) void {
        std.debug.assert(@typeInfo(Components) == .Struct);
        std.debug.assert(@hasDecl(Components, "run"));
        std.debug.assert(@hasDecl(Components, "name"));

        var desc = std.mem.zeroes(flecs.c.EcsObserverDesc);
        desc.callback = dummyFn;
        desc.ctx = ctx;
        // TODO
        // desc.entity.name = Components.name;
        desc.events[0] = @intFromEnum(event);

        desc.run = wrapSystemFn(Components, Components.run);
        desc.filter = meta.generateFilterDesc(self, Components);

        if (@hasDecl(Components, "instanced") and Components.instanced) desc.filter.instanced = true;

        _ = flecs.c.ecs_observer_init(self.world, &desc);
    }

    pub fn setName(self: World, entity: flecs.EntityId, name: [*c]const u8) void {
        _ = flecs.c.ecs_set_name(self.world, entity, name);
    }

    pub fn getName(self: World, entity: flecs.EntityId) [*c]const u8 {
        return flecs.c.ecs_get_name(self.world, entity);
    }

    /// sets a component on entity. Can be either a pointer to a struct or a struct
    pub fn set(self: *World, entity: flecs.EntityId, ptr_or_struct: anytype) void {
        std.debug.assert(@typeInfo(@TypeOf(ptr_or_struct)) == .Pointer or @typeInfo(@TypeOf(ptr_or_struct)) == .Struct);

        const T = meta.FinalChild(@TypeOf(ptr_or_struct));
        var component = if (@typeInfo(@TypeOf(ptr_or_struct)) == .Pointer) ptr_or_struct else &ptr_or_struct;
        _ = flecs.c.ecs_set_id(self.world, entity, self.componentId(T), @sizeOf(T), component);
    }

    pub fn getMut(self: *World, entity: flecs.EntityId, comptime T: type) *T {
        var ptr = flecs.c.ecs_get_mut_id(self.world, entity.id, meta.componentId(self.world, T));
        return @ptrCast(@alignCast(ptr.?));
    }

    /// removes a component from an Entity
    pub fn remove(self: *World, entity: flecs.EntityId, comptime T: type) void {
        flecs.c.ecs_remove_id(self.world, entity, self.componentId(T));
    }

    /// removes all components from an Entity
    pub fn clear(self: *World, entity: flecs.EntityId) void {
        flecs.c.ecs_clear(self.world, entity);
    }

    /// removes the entity from the world
    pub fn delete(self: *World, entity: flecs.EntityId) void {
        flecs.c.ecs_delete(self.world, entity);
    }

    /// deletes all entities with the component
    pub fn deleteWith(self: *World, comptime T: type) void {
        flecs.c.ecs_delete_with(self.world, self.componentId(T));
    }

    /// remove all instances of the specified component
    pub fn removeAll(self: *World, comptime T: type) void {
        flecs.c.ecs_remove_all(self.world, self.componentId(T));
    }

    pub fn setSingleton(self: World, ptr_or_struct: anytype) void {
        std.debug.assert(@typeInfo(@TypeOf(ptr_or_struct)) == .Pointer or @typeInfo(@TypeOf(ptr_or_struct)) == .Struct);

        const T = meta.FinalChild(@TypeOf(ptr_or_struct));
        var component = if (@typeInfo(@TypeOf(ptr_or_struct)) == .Pointer) ptr_or_struct else &ptr_or_struct;
        _ = flecs.c.ecs_set_id(self.world, self.componentId(T), self.componentId(T), @sizeOf(T), component);
    }

    // TODO: use ecs_get_mut_id optionally based on a bool perhaps or maybe if the passed in type is a pointer?
    pub fn getSingleton(self: World, comptime T: type) ?*const T {
        std.debug.assert(@typeInfo(T) == .Struct);
        var val = flecs.c.ecs_get_id(self.world, self.componentId(T), self.componentId(T));
        if (val == null) return null;
        return @as(*const T, @ptrCast(@alignCast(val)));
    }

    pub fn getSingletonMut(self: World, comptime T: type) ?*T {
        std.debug.assert(@typeInfo(T) == .Struct);
        var val = flecs.c.ecs_get_mut_id(self.world, self.componentId(T), self.componentId(T));
        if (val == null) return null;
        return @as(*T, @ptrCast(@alignCast(val)));
    }

    pub fn removeSingleton(self: World, comptime T: type) void {
        std.debug.assert(@typeInfo(T) == .Struct);
        flecs.c.ecs_remove_id(self.world, self.componentId(T), self.componentId(T));
    }
};

fn wrapSystemFn(comptime T: type, comptime cb: fn (*flecs.Iterator(T)) void) fn ([*c]flecs.c.EcsIter) callconv(.C) void {
    const Closure = struct {
        pub const callback: fn (*flecs.Iterator(T)) void = cb;

        pub fn closure(it: [*c]flecs.c.EcsIter) callconv(.C) void {
            var iter = flecs.Iterator(T).init(it, flecs.c.ecs_iter_next);
            callback(&iter);
        }
    };
    return Closure.closure;
}

fn wrapOrderByFn(comptime T: type, comptime cb: fn (flecs.EntityId, *const T, flecs.EntityId, *const T) c_int) FlecsOrderByAction {
    const Closure = struct {
        pub fn closure(e1: flecs.EntityId, c1: ?*const anyopaque, e2: flecs.EntityId, c2: ?*const anyopaque) callconv(.C) c_int {
            return @call(.{ .modifier = .always_inline }, cb, .{ e1, utils.componentCast(T, c1), e2, utils.componentCast(T, c2) });
        }
    };
    return Closure.closure;
}
