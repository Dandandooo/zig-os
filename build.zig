const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const ram_size = b.option([]const u8, "ram", "Kernel Ram Size (e.g. 8M)") orelse "16M";

    const chroma_scope = b.option(bool, "gay", "Chroma scope coloring") orelse false;

    const build_options = b.addOptions();

    build_options.addOption(usize, "RAM_SIZE", parse_ram_size(ram_size));
    build_options.addOption(bool, "gay", chroma_scope);

    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });

    build_options.addOption(usize, "page_size_max", 4096);
    build_options.addOption(usize, "page_size_min", 4096);

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });

    // Create a module for the freestanding kernel
    const kernel_mod = b.createModule(.{ .root_source_file = b.path("src/kernel.zig"), .target = target, .optimize = optimize, .code_model = .medium });
    kernel_mod.addOptions("build_options", build_options);
    kernel_mod.fuzz = false;
    kernel_mod.error_tracing = true;

    // Build the kernel with a custom linker script
    const kernel = b.addExecutable(.{
        .root_module = kernel_mod,
        .name = "kernel",
    });
    kernel.setLinkerScript(b.path("kernel.ld"));

    // Assemble all ".s" files
    const allocator = std.heap.page_allocator;
    const src_dir = std.fs.cwd().openDir("src", .{}) catch @panic("no src dir");
    var walker = src_dir.walk(allocator) catch @panic("failed to walk");
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const asmPath = entry.path;
        if (!std.mem.endsWith(u8, asmPath, ".s")) continue;

        // std.debug.print("including: {s}\n", .{asmPath});
        kernel.addAssemblyFile(b.path(b.pathJoin(&.{ "src", asmPath })));
    }

    const build_kernel = b.addInstallArtifact(kernel, .{ .dest_sub_path = "kernel.elf" });

    b.default_step.dependOn(&build_kernel.step);

    const run_qemu = b.addSystemCommand(&.{
        "qemu-system-riscv64",
        "-machine", "virt",
        "-bios", "none",
        "-kernel", "zig-out/bin/kernel.elf",
        "-global", "virtio-mmio.force-legacy=false",
        "-m", ram_size,
        "-cpu", "rv64",
        "-nographic",
        "-d", "guest_errors,invalid_mem",
        "-D", "qemu.log",

        // Console Device
        "-serial", "mon:stdio",

        // Block Device
        // "-drive", "file=ktfs.raw,id=blk0,if=none,format=raw,readonly=false",
        // "-device", "virtio-blk-device,drive=blk0",
    });

    run_qemu.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Start the kernel in qemu.");
    run_step.dependOn(&run_qemu.step);

    const addr_step = b.step("addr", "Translate address to source location");

    // Get positional parameter from args
    if (b.args) |args| {
        // Look for address after "addr" in command line
        for (args) |
            arg,
        | {
            std.debug.print("{s}\n", .{arg});
            const addr_cmd = b.addSystemCommand(&.{
                "/opt/homebrew/opt/llvm/bin/llvm-addr2line",
                "-e",
                "zig-out/bin/kernel.elf",
                "-f",
                arg,
            });
            addr_cmd.step.dependOn(b.getInstallStep());
            addr_step.dependOn(&addr_cmd.step);
        }
    }

    const docs_step = b.step("docs", "Generate documentation");
    const save_docs = b.addInstallDirectory(.{
        .source_dir = kernel.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const run_docs = b.addSystemCommand(&.{ "python", "-m", "http.server", "--directory", "zig-out/docs", "8000" });
    run_docs.step.dependOn(&save_docs.step);
    docs_step.dependOn(&run_docs.step);
}

fn parse_ram_size(size: []const u8) usize {
    const len = size.len;
    if (len == 0) return 0;
    const last = size[len - 1];
    const unit: usize = switch (last) {
        'K', 'k' => 1,
        'M', 'm' => 2,
        'G', 'g' => 3,
        else => 0,
    };
    const num = if (unit != 0) size[0 .. len - 1] else size;
    const n = std.fmt.parseInt(usize, num, 10) catch std.debug.panic("invalid RAM size: {u}\n", .{size});
    return n * std.math.pow(usize, 1024, unit);
}
