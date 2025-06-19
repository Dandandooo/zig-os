const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const ram_size = b.option([]const u8, "ram", "Kernel Ram Size (e.g. 8M)") orelse "8M";


    const build_options = b.addOptions();

    build_options.addOption(usize, "RAM_SIZE", parse_ram_size(ram_size));

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    // const target = b.standardTargetOptions(.{ .default_target = std.Target.Query{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none } });
    // const target = b.standardTargetOptions(.{
    //     .default_target = std.Target.Query{
    //         .cpu_arch = .riscv64,
    //         .os_tag = .freestanding,
    //         .abi = .none,
    //     }
    // });

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none
    });

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Create a module for the freestanding kernel
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medium
    });

    // Build the kernel with a custom linker script
    const kernel = b.addExecutable(.{
        .root_module = kernel_mod,
        .name = "kernel",
    });
    kernel.setLinkerScript(b.path("kernel.ld"));
    kernel.root_module.addOptions("build_options", build_options);

    // Assemble all ".s" files
    const allocator = std.heap.page_allocator;
    const src_dir = std.fs.cwd().openDir("src", .{}) catch unreachable;
    var walker = src_dir.walk(allocator) catch unreachable;
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const asmPath = entry.path;
        if (!std.mem.endsWith(u8, asmPath, ".s")) continue;

        std.debug.print("{s}\n", .{asmPath});
        kernel.addAssemblyFile(b.path(b.pathJoin(&.{"src", asmPath})));
    }

    const build_kernel = b.addInstallArtifact(kernel, .{ .dest_sub_path = "kernel.elf" });

    b.default_step.dependOn(&build_kernel.step);

    const run_qemu = b.addSystemCommand(&.{
        "qemu-system-riscv64",
        "-machine", "virt",
        "-bios", "none",
        "-kernel", "zig-out/bin/kernel.elf",
        "-m", ram_size,
        "-cpu", "rv64",
        "-nographic",

        // Console Device
        "-serial", "mon:stdio"
    });

    run_qemu.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Start the kernel in qemu.");
    run_step.dependOn(&run_qemu.step);

}

fn parse_ram_size(size: []const u8) usize {
    const len = size.len;
    if (len == 0) return 0;
    const last = size[len - 1];
    const unit: usize = switch (last) {
        'K','k' => 1,
        'M','m' => 2,
        'G','g' => 3,
        else => 0
    };
    const num = if (unit != 0) size[0..len-1] else size;
    const n = std.fmt.parseInt(usize, num, 10)
        catch std.debug.panic("invalid RAM size: {u}\n", .{size});
    return n * std.math.pow(usize, 1024, unit);
}
