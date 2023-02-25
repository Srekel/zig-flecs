const std = @import("std");

// copied and adjusted from zig-gamedev's build

pub const Package = struct {
    flecs: *std.Build.Module,
    flecs_c_cpp: *std.Build.CompileStep,

    pub fn build(
        b: *std.Build,
        target: std.zig.CrossTarget,
        optimize: std.builtin.Mode,
        _: struct {},
    ) Package {
        const flecs = b.createModule(.{
            .source_file = .{ .path = thisDir() ++ "/src/flecs.zig" },
            .dependencies = &.{},
        });

        const flecs_c_cpp = b.addStaticLibrary(.{
            .name = "flecs",
            .target = target,
            .optimize = optimize,
        });
        flecs_c_cpp.linkLibC();
        flecs_c_cpp.addIncludePath(thisDir() ++ "/src/c/flecs");
        flecs_c_cpp.addCSourceFile(thisDir() ++ "/src/c/flecs.c", &.{
            "-fno-sanitize=undefined",
            "-DFLECS_NO_CPP",
            if (@import("builtin").mode == .Debug) "-DFLECS_SANITIZE" else "",
        });

        if (flecs_c_cpp.target.isWindows()) {
            flecs_c_cpp.linkSystemLibraryName("ws2_32");
        }

        return .{
            .flecs = flecs,
            .flecs_c_cpp = flecs_c_cpp,
        };
    }

    pub fn link(flecs_pkg: Package, exe: *std.Build.CompileStep) void {
        exe.addIncludePath(thisDir() ++ "/src/c");
        exe.linkLibrary(flecs_pkg.flecs_c_cpp);
    }
};

pub fn build(_: *std.Build) void {}

pub fn buildTests(
    b: *std.Build,
    optimize: std.builtin.Mode,
    target: std.zig.CrossTarget,
) *std.Build.CompileStep {
    const tests = b.addTest(.{
        .root_source_file = .{ .path = thisDir() ++ "/src/flecs.zig" },
        .target = target,
        .optimize = optimize,
    });
    return tests;
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
