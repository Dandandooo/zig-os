const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    // const target = b.standardTargetOptions(.{ .default_target = std.Target.Query{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none } });
    const target = std.Target.Query{ .cpu_arch = .riscv64, .os_tag = .freestanding };

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Create a module for the freestanding kernel
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,

        .optimize = optimize,
    });

    // Build the kernel with a custom linker script
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
    });
    kernel.setLinkerScript(b.path("kernel.ld"));

    b.default_step.dependOn(&kernel.step);
}
