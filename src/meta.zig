const std = @import("std");
const flecs = @import("flecs.zig");
const meta = @import("meta.zig");

const assert = std.debug.assert;

const TermInfo = @import("term_info.zig").TermInfo;

/// asserts with a message
pub fn assertMsg(ok: bool, comptime msg: []const u8, args: anytype) void {
    if (@import("builtin").mode == .Debug) {
        if (!ok) {
            std.debug.print("Assertion: " ++ msg ++ "\n", args);
            unreachable;
        }
    }
}

/// registered component handle cache. Stores the EntityId for the type.
pub fn componentHandle(comptime T: type) *flecs.EntityId {
    return flecs.ecs_id_handle(T);
}

/// gets the EntityId for T creating it if it doesn't already exist
pub fn componentId(world: *flecs.c.EcsWorld, comptime T: type) flecs.EntityId {
    var handle = componentHandle(T);
    if (handle.* < std.math.maxInt(flecs.EntityId)) {
        return handle.*;
    }

    if (@sizeOf(T) == 0) {
        var desc = std.mem.zeroInit(flecs.c.EcsEntityDesc, .{ .name = @typeName(T) });
        handle.* = flecs.c.ecs_entity_init(world, &desc);
    } else {
        var edesc = std.mem.zeroInit(flecs.c.EcsEntityDesc, .{ .name = @typeName(T) });
        var desc = std.mem.zeroInit(flecs.c.EcsComponentDesc, .{
            .entity = flecs.c.ecs_entity_init(world, &edesc),
            .type = .{
                .size = @sizeOf(T),
                .alignment = @alignOf(T),
                .hooks = std.mem.zeroInit(flecs.EcsTypeHooks, .{}),
                .component = 0,
            },
        });
        handle.* = flecs.c.ecs_component_init(world, &desc);
    }

    // allow disabling reflection data with a root bool
    if (!@hasDecl(@import("root"), "disable_reflection") or !@as(bool, @field(@import("root"), "disable_reflection")))
        registerReflectionData(world, T, handle.*);

    return handle.*;
}

/// given a pointer or optional pointer returns the base struct type.
pub fn FinalChild(comptime T: type) type {
    switch (@typeInfo(T)) {
        .Pointer => |info| switch (info.size) {
            .One => switch (@typeInfo(info.child)) {
                .Struct => return info.child,
                .Optional => |opt_info| return opt_info.child,
                else => {
                    @compileError("Expected pointer or optional pointer, found '" ++ @typeInfo(info.child) ++ "'");
                },
            },
            else => {},
        },
        .Optional => |info| return FinalChild(info.child),
        .Struct => return T,
        else => {},
    }
    @compileError("Expected pointer or optional pointer, found '" ++ @typeName(T) ++ "'");
}

/// given a pointer or optional pointer returns a pointer-to-many. constness and optionality are retained.
pub fn PointerToMany(comptime T: type) type {
    var is_const = false;
    var is_optional = false;
    var PointerT = T;

    switch (@typeInfo(T)) {
        .Optional => |opt_info| switch (@typeInfo(opt_info.child)) {
            .Pointer => |ptr_info| {
                is_const = ptr_info.is_const;
                is_optional = true;
                PointerT = opt_info.child;
            },
            else => unreachable,
        },
        .Pointer => |ptr_info| is_const = ptr_info.is_const,
        else => unreachable,
    }

    const info = @typeInfo(PointerT).Pointer;
    const InnerType = @Type(.{
        .Pointer = .{
            .size = .Many,
            .is_const = is_const,
            .is_volatile = info.is_volatile,
            .alignment = info.alignment,
            .address_space = info.address_space,
            .child = info.child,
            .is_allowzero = info.is_allowzero,
            .sentinel = null,
        },
    });

    if (is_optional) return @Type(.{
        .Optional = .{
            .child = InnerType,
        },
    });

    return InnerType;
}

/// gets the number of arguments in the function
pub fn argCount(comptime function: anytype) usize {
    return switch (@typeInfo(@TypeOf(function))) {
        .BoundFn => |func_info| func_info.args.len,
        .Fn => |func_info| func_info.args.len,
        else => assert("invalid function"),
    };
}

/// given a query struct, returns a type with the exact same fields except the fields are made pointer-to-many.
/// constness and optionality are retained.
pub fn TableIteratorData(comptime Components: type) type {
    const src_fields = std.meta.fields(Components);
    const StructField = std.builtin.Type.StructField;
    var fields: [src_fields.len]StructField = undefined;

    for (src_fields, 0..) |field, i| {
        const T = FinalChild(field.type);
        fields[i] = .{
            .name = field.name,
            .type = PointerToMany(field.type),
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(*T),
        };
    }

    return @Type(.{ .Struct = .{
        .layout = .Auto,
        .fields = &fields,
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = false,
    } });
}

/// returns a tuple consisting of the field values of value
pub fn fieldsTuple(value: anytype) FieldsTupleType(@TypeOf(value)) {
    const T = @TypeOf(value);
    assert(@typeInfo(T) == .Struct);
    const ti = @typeInfo(T).Struct;
    const FieldsTuple = FieldsTupleType(T);

    var tuple: FieldsTuple = undefined;
    comptime var i = 0;
    inline while (i < ti.fields.len) : (i += 1) {
        tuple[i] = @field(value, ti.fields[i].name);
    }

    return tuple;
}

/// returns the Type of the tuple version of T
pub fn FieldsTupleType(comptime T: type) type {
    const ti = @typeInfo(T).Struct;
    return @Type(.{
        .Struct = .{
            .layout = ti.layout,
            .fields = ti.fields,
            .decls = &[0]std.builtin.Type.Declaration{},
            .is_tuple = true,
        },
    });
}

pub fn validateIterator(comptime Components: type, iter: *const flecs.c.EcsIter) void {
    if (@import("builtin").mode == .Debug) {
        var index: usize = 0;
        const component_info = @typeInfo(Components).Struct;

        inline for (component_info.fields) |field| {
            // skip filters since they arent returned when we iterate
            while (iter.terms[index].inout == .ecs_in_out_none) : (index += 1) {}
            const is_optional = @typeInfo(field.type) == .Optional;
            const col_type = FinalChild(field.type);
            const type_entity = meta.componentHandle(col_type).*;

            // ensure order matches for terms vs struct fields. note that pairs need to have their first term extracted.
            if (flecs.c.ecs_id_is_pair(iter.terms[index].id)) {
                assertMsg(flecs.pairFirst(iter.terms[index].id) == type_entity, "Order of struct does not match order of iter.terms! {d} != {d}\n", .{ iter.terms[index].id, type_entity });
            } else {
                assertMsg(iter.terms[index].id == type_entity, "Order of struct does not match order of iter.terms! {d} != {d}. term index: {d}\n", .{ iter.terms[index].id, type_entity, index });
            }

            // validate readonly (non-ptr types in the struct) matches up with the inout
            const is_const = isConst(field.type);
            if (is_const) assert(iter.terms[index].inout == .ecs_in);
            if (iter.terms[index].inout == .ecs_in) assert(is_const);

            // validate that optionals (?* types in the struct) match up with valid opers
            if (is_optional) assert(iter.terms[index].oper == .ecs_or or iter.terms[index].oper == .ecs_optional);
            if (iter.terms[index].oper == .ecs_or or iter.terms[index].oper == .ecs_optional) assert(is_optional);

            index += 1;
        }
    }
}

/// ensures an orderBy function for a query/system is legit
pub fn validateOrderByFn(comptime func: anytype) void {
    if (@import("builtin").mode == .Debug) {
        const ti = @typeInfo(@TypeOf(func));
        assert(ti == .Fn);
        assert(ti.Fn.args.len == 4);

        // args are: EntityId, *const T, EntityId, *const T
        assert(ti.Fn.args[0].arg_type.? == flecs.EntityId);
        assert(ti.Fn.args[2].arg_type.? == flecs.EntityId);
        assert(ti.Fn.args[1].arg_type.? == ti.Fn.args[3].arg_type.?);
        assert(isConst(ti.Fn.args[1].arg_type.?));
        assert(@typeInfo(ti.Fn.args[1].arg_type.?) == .Pointer);
    }
}

/// ensures the order by type is in the Components struct and that that it isnt an optional term
pub fn validateOrderByType(comptime Components: type, comptime T: type) void {
    if (@import("builtin").mode == .Debug) {
        var valid = false;

        const component_info = @typeInfo(Components).Struct;
        inline for (component_info.fields) |field| {
            if (FinalChild(field.type) == T) {
                valid = true;
            }
        }

        // allow types in Filter with no fields
        if (@hasDecl(Components, "modifiers")) {
            inline for (Components.modifiers) |inout_tuple| {
                const ti = TermInfo.init(inout_tuple);
                if (ti.inout == .ecs_in_out_none) {
                    if (ti.term_type == T)
                        valid = true;
                }
            }
        }

        assertMsg(valid, "type {any} was not found in the struct!", .{T});
    }
}

/// checks a Pointer or Optional for constness. Any other types passed in will error.
pub fn isConst(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .Pointer => |ptr| return ptr.is_const,
        .Optional => |opt| {
            switch (@typeInfo(opt.child)) {
                .Pointer => |ptr| return ptr.is_const,
                else => {},
            }
        },
        else => {},
    }

    @compileError("Invalid type passed to isConst: " ++ @typeName(T));
}

/// https://github.com/SanderMertens/flecs/tree/master/examples/c/reflection
fn registerReflectionData(world: *flecs.c.EcsWorld, comptime T: type, entity: flecs.EntityId) void {
    // var entityDesc = std.mem.zeroInit(flecs.c.EcsEntityDesc, .{ .entity = entity });
    var desc = std.mem.zeroInit(flecs.c.EcsStructDesc, .{ .entity = entity });

    switch (@typeInfo(T)) {
        .Struct => |si| {
            // tags have no size so ignore them
            if (@sizeOf(T) == 0) return;

            inline for (si.fields, 0..) |field, i| {
                var member = std.mem.zeroes(flecs.c.EcsMember);
                member.name = field.name.ptr;

                // TODO: support nested structs
                member.type = switch (field.type) {
                    // Struct => componentId(field.type),
                    bool => flecs.c.FLECS__Eecs_bool_t,
                    f32 => flecs.c.FLECS__Eecs_f32_t,
                    f64 => flecs.c.FLECS__Eecs_f64_t,
                    u8 => flecs.c.FLECS__Eecs_u8_t,
                    u16 => flecs.c.FLECS__Eecs_u16_t,
                    u32 => flecs.c.FLECS__Eecs_u32_t,
                    flecs.EntityId => blk: {
                        // bit of a hack, but if the field name has "entity" in it we consider it an Entity reference
                        if (std.mem.indexOf(u8, field.name, "entity") != null)
                            break :blk flecs.c.FLECS__Eecs_entity_t;
                        break :blk flecs.c.FLECS__Eecs_u64_t;
                    },
                    i8 => flecs.c.FLECS__Eecs_i8_t,
                    i16 => flecs.c.FLECS__Eecs_i16_t,
                    i32 => flecs.c.FLECS__Eecs_i32_t,
                    i64 => flecs.c.FLECS__Eecs_i64_t,
                    usize => flecs.c.FLECS__Eecs_uptr_t,
                    []const u8 => flecs.c.FLECS__Eecs_string_t,
                    [*]const u8 => flecs.c.FLECS__Eecs_string_t,
                    else => switch (@typeInfo(field.type)) {
                        .Pointer => flecs.c.FLECS__Eecs_uptr_t,

                        .Struct => componentId(world, field.type),

                        .Enum => blk: {
                            var enum_desc = std.mem.zeroes(flecs.c.ecs_enum_desc_t);
                            // TODO
                            enum_desc.entity = meta.componentHandle(T).*;

                            inline for (@typeInfo(field.type).Enum.fields, 0..) |f, index| {
                                enum_desc.constants[index] = std.mem.zeroInit(flecs.c.ecs_enum_constant_t, .{
                                    .name = f.name.ptr,
                                    .value = @intCast(f.value),
                                });
                            }

                            break :blk flecs.c.ecs_enum_init(world, &enum_desc);
                        },

                        .Array => blk: {
                            var array_desc = std.mem.zeroes(flecs.c.ecs_array_desc_t);
                            array_desc.type = flecs.c.FLECS__Eecs_f32_t;
                            array_desc.entity = meta.componentHandle(T).*;
                            array_desc.count = @typeInfo(field.type).Array.len;

                            break :blk flecs.c.ecs_array_init(world, &array_desc);
                        },

                        else => {
                            std.debug.print("unhandled field type: {any}, ti: {any}\n", .{ field.type, @typeInfo(field.type) });
                            unreachable;
                        },
                    },
                };
                desc.members[i] = member;
            }
            _ = flecs.c.ecs_struct_init(world, &desc);
        },
        else => unreachable,
    }
}

/// given a struct of Components with optional embedded "metadata", "name", "order_by" data it generates an EcsFilterDesc
pub fn generateFilterDesc(world: flecs.World, comptime Components: type) flecs.c.EcsFilterDesc {
    assert(@typeInfo(Components) == .Struct);
    var desc = std.mem.zeroes(flecs.c.EcsFilterDesc);

    // first, extract what we can from the Components fields
    const component_info = @typeInfo(Components).Struct;
    inline for (component_info.fields, 0..) |field, i| {
        desc.terms[i].id = world.componentId(meta.FinalChild(field.type));

        if (@typeInfo(field.type) == .Optional)
            desc.terms[i].oper = .ecs_optional;

        if (meta.isConst(field.type))
            desc.terms[i].inout = .ecs_in;
    }

    // optionally, apply any additional modifiers if present. Keep track of the term_index in case we have to add Or + Filters or Ands
    var next_term_index = component_info.fields.len;
    if (@hasDecl(Components, "modifiers")) {
        inline for (Components.modifiers) |inout_tuple| {
            const ti = TermInfo.init(inout_tuple);
            std.debug.print("{any}: {any}\n", .{ inout_tuple, ti });

            if (getTermIndex(ti.term_type, ti.field, &desc, component_info.fields)) |term_index| {
                // Not terms should not be present in the Components struct
                assert(ti.oper != .ecs_not);

                // if we have a Filter on an existing type ensure we also have an Or. That is the only legit case for having a Filter and also
                // having the term present in the query. For that case, we will leave both optionals and add the two Or terms.
                if (ti.inout == .ecs_in_out_none) {
                    assert(ti.oper == .ecs_or);
                    if (ti.or_term_type) |or_term_type| {
                        // ensure the term is optional. If the second Or term is present ensure it is optional as well.
                        assert(desc.terms[term_index].oper == .ecs_optional);
                        if (getTermIndex(or_term_type, null, &desc, component_info.fields)) |or_term_index| {
                            assert(desc.terms[or_term_index].oper == .ecs_optional);
                        }

                        desc.terms[next_term_index].id = world.componentId(ti.term_type);
                        desc.terms[next_term_index].inout = ti.inout;
                        desc.terms[next_term_index].oper = ti.oper;
                        next_term_index += 1;

                        desc.terms[next_term_index].id = world.componentId(or_term_type);
                        desc.terms[next_term_index].inout = ti.inout;
                        desc.terms[next_term_index].oper = ti.oper;
                        next_term_index += 1;
                    } else unreachable;
                } else {
                    if (ti.inout == .ecs_out) {
                        assert(desc.terms[term_index].inout == .ecs_in_out_default);
                        desc.terms[term_index].inout = ti.inout;
                    }

                    // the only valid oper left is Or since Not terms cant be in Components struct
                    if (ti.oper == .ecs_or) {
                        assert(desc.terms[term_index].oper == .ecs_optional);

                        if (getTermIndex(ti.or_term_type.?, null, &desc, component_info.fields)) |or_term_index| {
                            assert(desc.terms[or_term_index].oper == .ecs_optional);
                            desc.terms[or_term_index].oper = ti.oper;
                        } else unreachable;
                        desc.terms[term_index].oper = ti.oper;
                    }
                }

                if (ti.mask != 0) {
                    assert(desc.terms[term_index].subj.set.mask == 0);
                    desc.terms[term_index].subj.set.mask = ti.mask;
                }

                if (ti.obj_type) |obj_type| {
                    desc.terms[term_index].id = world.pair(ti.relation_type.?, obj_type);
                }
            } else {
                // the term wasnt found so we must have either a Filter, Not or EcsNothing mask
                if (ti.inout != .ecs_in_out_none and ti.oper != .ecs_not and ti.mask != .ecs_nothing) std.debug.print("invalid inout found! No matching type found in the Components struct. Only Not and Filters are valid for types not in the struct. This should assert/panic but a zig bug lets us only print it.\n", .{});
                if (ti.inout == .ecs_in_out_none) {
                    desc.terms[next_term_index].id = world.componentId(ti.term_type);
                    desc.terms[next_term_index].inout = ti.inout;
                    next_term_index += 1;
                } else if (ti.oper == .ecs_not) {
                    desc.terms[next_term_index].id = world.componentId(ti.term_type);
                    desc.terms[next_term_index].oper = ti.oper;
                    next_term_index += 1;
                } else if (ti.mask == .ecs_nothing) {
                    desc.terms[next_term_index].id = world.componentId(ti.term_type);
                    desc.terms[next_term_index].inout = ti.inout;
                    desc.terms[next_term_index].subj.set.mask = ti.mask;
                    next_term_index += 1;
                } else {
                    std.debug.print("invalid inout applied to a term not in the query. only Not and Filter are allowed for terms not present.\n", .{});
                }
            }
        }
    }

    // optionally add the expression string
    if (@hasDecl(Components, "expr")) {
        assertMsg(std.meta.Elem(@TypeOf(Components.expr)) == u8, "expr must be a const string. Found: {s}", .{std.meta.Elem(@TypeOf(Components.expr))});
        desc.expr = Components.expr;
    }

    return desc;
}

/// gets the index into the terms array of this type or null if it isnt found (likely a new filter term)
pub fn getTermIndex(comptime T: type, field_name: ?[]const u8, filter: *flecs.c.EcsFilterDesc, fields: []const std.builtin.Type.StructField) ?usize {
    if (fields.len == 0) return null;
    const comp_id = meta.componentHandle(T).*;

    // if we have a field_name get the index of it so we can match it up to the term index and double check the type matches
    const named_field_index: ?usize = if (field_name) |fname| blk: {
        const f_idx = inline for (fields, 0..) |field, field_index| {
            if (std.mem.eql(u8, field.name, fname))
                break field_index;
        };
        break :blk f_idx;
    } else null;

    var i: usize = 0;
    while (i < fields.len) : (i += 1) {
        if (filter.terms[i].id == comp_id) {
            if (named_field_index == null) return i;

            // we have a field_name so make sure the term index matches the named field index
            if (named_field_index == i) return i;
        }
    }
    return null;
}
