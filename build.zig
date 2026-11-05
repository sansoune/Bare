const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const emu_mod = b.createModule(.{
        .root_source_file = b.path("emulator/emu.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "emu", .root_module = emu_mod });
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the emulator on a .s file").dependOn(&run.step);

    const filter = b.option([]const u8, "filter", "Only run tests whose name contains this");
    const test_step = b.step("test", "Run all tests");

    const test_files = [_][]const u8{ "emu", "assembler" };
    for (test_files) |name| {
        const t = b.addTest(.{
            .name = name,
            .filters = if (filter) |f| &.{f} else &.{},
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("test/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "emu", .module = emu_mod }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
