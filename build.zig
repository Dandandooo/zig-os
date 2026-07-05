const std = @import("std");

const qemu_base = .{
    "qemu-system-riscv64",
    "-machine",
    "virt",
    "-bios",
    "none",
    "-smp",
    "1",

    "-global",
    "virtio-mmio.force-legacy=false",
    "-cpu",
    "rv64",
    "-nographic",
    "-d",
    "guest_errors,invalid_mem,trace:virtio_*,int",
    "-D",
    "qemu.log",

    // Console Device
    "-serial",
    "mon:stdio",

    // RNG Device
    "-device",
    "virtio-rng-device,rng=rng0",
    "-object",
    "rng-random,filename=/dev/urandom,id=rng0",

    // Block Device
    "-device",
    "virtio-blk-device,drive=blk0",
    "-drive",
    "file=ktfs.raw,id=blk0,if=none,format=raw,readonly=false",

    // GPU Device
    // "-device", "virtio-gpu-device",
    // "-display", "gtk",
    // "-monitor", "pty",

    // Input Device
    // "-device", "virtio-keyboard-device",
    // "-device", "virtio-tablet-device",

    // Sound Device
    "-device",
    "virtio-sound-device,audiodev=audio0",
    // "-audio", "driver=pa,model=virtio,id=audio0,server=host.docker.internal:4713",
    // driver determined during build

    // Network Device
    // "-device", "virtio-net-device,netdev=u1",
    // "-netdev", "user,id=u1",

};

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const ram_size = b.option([]const u8, "ram", "Kernel Ram Size (e.g. 8M)") orelse "16M";
    const chroma_scope = b.option(bool, "gay", "Chroma scope coloring") orelse false;
    const time_zone = b.option([]const u8, "tz", "Time zone (e.g. UTC, EST, EDT, CST, CDT, PST, GMT, CET, EET)") orelse detect_time_zone(b) orelse "UTC";

    const audio_driver = blk: {
        const res = std.process.run(b.allocator, b.graph.io, .{
            .argv = &[_][]const u8{ "qemu-system-riscv64", "-audio", "help" },
        }) catch break :blk "wav";
        if (null != std.mem.indexOf(u8, res.stdout, "alsa"))
            break :blk "alsa";
        if (null != std.mem.indexOf(u8, res.stdout, "coreaudio"))
            break :blk "coreaudio";
        if (null != std.mem.indexOf(u8, res.stdout, "pa"))
            break :blk "pa,server=host.docker.internal:4713";
        break :blk "wav";
    };

    const audio_arg = b.fmt("driver={s},model=virtio,id=audio0", .{audio_driver});

    const qemu_args = qemu_base ++ .{ "-m", ram_size, "-audio", audio_arg };

    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });

    // -----------------------------
    // run - normal kernel build
    // -----------------------------
    const build_options = b.addOptions();

    build_options.addOption(usize, "RAM_SIZE", parse_ram_size(ram_size));
    build_options.addOption(bool, "gay", chroma_scope);
    build_options.addOption(bool, "test_mode", false);
    build_options.addOption([]const u8, "time_zone", time_zone);

    // Create a module for the freestanding kernel
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,
        .optimize = .Debug,
        .code_model = .medium,
    });
    kernel_mod.addOptions("build_options", build_options);
    kernel_mod.fuzz = false;
    kernel_mod.error_tracing = false;

    // Build the kernel with a custom linker script
    const kernel = b.addExecutable(.{
        .root_module = kernel_mod,
        .name = "kernel",
    });
    kernel.setLinkerScript(b.path("kernel.ld"));

    addAllAssemblyFiles(b, kernel);

    const build_kernel = b.addInstallArtifact(kernel, .{ .dest_sub_path = "kernel.elf" });

    b.default_step.dependOn(&build_kernel.step);

    const run_args = qemu_args ++ .{ "-kernel", "zig-out/bin/kernel.elf" };
    const run_qemu = b.addSystemCommand(&run_args);

    run_qemu.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Start the kernel in qemu.");
    run_step.dependOn(&run_qemu.step);

    // -----------------------------
    // test - kernel test mode
    // -----------------------------
    const test_options = b.addOptions();
    test_options.addOption(usize, "RAM_SIZE", parse_ram_size(ram_size));
    test_options.addOption(bool, "gay", chroma_scope);
    test_options.addOption(bool, "test_mode", true);
    test_options.addOption([]const u8, "time_zone", time_zone);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,
        .optimize = .Debug,
        .code_model = .medium,
        .fuzz = false,
        .error_tracing = false,
        .omit_frame_pointer = false,
        .strip = false,
    });
    test_mod.addOptions("build_options", test_options);

    const test_kernel = b.addExecutable(.{ .root_module = test_mod, .name = "test_kernel", .linkage = .static, .use_lld = true });
    test_kernel.setLinkerScript(b.path("kernel.ld"));

    addAllAssemblyFiles(b, test_kernel);
    // test_kernel.addCSourceFiles(.{ .files = "src/asm/*.s"});

    const build_test = b.addInstallArtifact(test_kernel, .{ .dest_sub_path = "kernel-test.elf" });

    b.default_step.dependOn(&build_test.step);

    const test_args = qemu_args ++ .{ "-kernel", "zig-out/bin/kernel-test.elf" };
    const test_qemu = b.addSystemCommand(&test_args);

    test_qemu.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run kernel tests in QEMU");
    test_step.dependOn(&test_qemu.step);

    // -----------------------------
    // debug - Run tests with gdb
    // -----------------------------
    const debug_args = test_args ++ .{ "-s", "-S" };
    const debug_qemu = b.addSystemCommand(&debug_args);

    debug_qemu.step.dependOn(b.getInstallStep());

    const debug_step = b.step("debug", "Run kernel tests in QEMU with GDB");
    debug_step.dependOn(&debug_qemu.step);

    // -----------------------------
    // docs - documentation builder
    // -----------------------------
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

fn addAllAssemblyFiles(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const allocator = std.heap.page_allocator;
    const io = b.graph.io;
    const src_dir = std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true }) catch @panic("no src dir");
    var walker = src_dir.walk(allocator) catch @panic("failed to walk");
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const asmPath = entry.path;
        if (!std.mem.endsWith(u8, asmPath, ".s")) continue;

        // std.debug.print("including: {s}\n", .{asmPath});
        // exe.addAssemblyFile(b.path(b.pathJoin(&.{ "src", asmPath })));
        exe.root_module.addCSourceFile(.{ .file = b.path(b.pathJoin(&.{ "src", asmPath })), .language = .assembly, .flags = &.{ "-g", "-fno-omit-frame-pointer" } });
    }
}

fn parse_ram_size(size: []const u8) usize {
    const len = size.len;
    if (len == 0) return 0;
    const unit: usize = switch (size[len - 1]) {
        'K', 'k' => 1,
        'M', 'm' => 2,
        'G', 'g' => 3,
        else => 0,
    };
    const n = std.fmt.parseInt(usize, if (unit != 0) size[0 .. len - 1] else size, 10) catch std.debug.panic("invalid RAM size: {s}\n", .{size});
    return n * std.math.pow(usize, 1024, unit);
}

fn detect_time_zone(b: *std.Build) ?[]const u8 {
    const stdout = blk: {
        const res = std.process.run(b.allocator, b.graph.io, .{
            .argv = &.{ "date", "+%Z" },
            .stdout_limit = .limited(64),
            .stderr_limit = .limited(0),
        }) catch return null;
        break :blk res.stdout;
    };

    const trimmed = std.mem.trim(u8, stdout, " \n\r\t");
    if (trimmed.len == 0) return null;
    return normalize_time_zone(trimmed);
}

fn normalize_time_zone(name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;

    const tz =
        .{ "UTC", "GMT", "PST", "PDT", "CST", "CDT", "EST", "EDT", "CET", "EET" };

    inline for (tz) |tz_name|
        if (std.ascii.eqlIgnoreCase(name, tz_name)) return tz_name;

    return null;
}
