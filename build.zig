const std = @import("std");

const qemu_base = .{
    "qemu-system-riscv64",
    "-machine", "virt",
    "-bios", "none",
    "-smp", "1",

    "-global", "virtio-mmio.force-legacy=false",
    "-cpu", "rv64",
    "-nographic",
    "-d", "guest_errors,invalid_mem,trace:virtio_*,int",
    "-D", "qemu.log",

    // Console Device
    "-serial", "mon:stdio",

    // RNG Device
    "-device", "virtio-rng-device,rng=rng0",
    "-object", "rng-random,filename=/dev/urandom,id=rng0",

    // Block Device
    // "-device", "virtio-blk-device,drive=blk0",
    // "-drive", "file=ktfs.raw,id=blk0,if=none,format=raw,readonly=false",

    // GPU Device
    // "-device", "virtio-gpu-device",
    // "-display", "gtk",
    // "-monitor", "pty",

    // Input Device
    // "-device", "virtio-keyboard-device",
    // "-device", "virtio-tablet-device",

    // Sound Device
    "-device", "virtio-sound-device,audiodev=audio0",
    // driver determined later

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
    const time_zone = b.option([]const u8, "tz", "Time zone (e.g. UTC, EST, EDT, CST, CDT, PST, GMT, CET, EET)") orelse detect_host_time_zone(b.allocator);

    const qemu_args = qemu_base ++ .{ "-m", ram_size } ++
        switch (b.graph.host.result.os.tag) {
            .linux => .{ "-audio", "driver=alsa,model=virtio,id=audio0"},
            .macos => .{ "-audio", "driver=coreaudio,model=virtio,id=audio0"},
            else => .{ "-audio", "driver=wav,model=virtio,id=audio0"},
        };

    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });

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
        .optimize = optimize,
        .code_model = .medium,
    });
    kernel_mod.addOptions("build_options", build_options);
    kernel_mod.fuzz = false;
    kernel_mod.error_tracing = true;

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
        .optimize = optimize,
        .code_model = .medium,
        .fuzz = false,
        .error_tracing = true,
        .omit_frame_pointer = false,
        .strip = false,
    });
    test_mod.addOptions("build_options", test_options);

    const test_kernel = b.addExecutable(.{
        .root_module = test_mod,
        .name = "test_kernel",
        .strip = false,
        .omit_frame_pointer = false,
    });
    test_kernel.setLinkerScript(b.path("kernel.ld"));

    addAllAssemblyFiles(b, test_kernel);
    // test_kernel.addCSourceFiles(.{ .files = "src/asm/*.s"});

    const build_test = b.addInstallArtifact(test_kernel, .{ .dest_sub_path = "kernel-test.elf"});

    b.default_step.dependOn(&build_test.step);

    const test_args = qemu_args ++ .{ "-kernel", "zig-out/bin/kernel-test.elf" };
    const test_qemu = b.addSystemCommand(&test_args);

    test_qemu.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run kernel tests in QEMU");
    test_step.dependOn(&test_qemu.step);

    // -----------------------------
    // debug - Run tests with gdb
    // -----------------------------
    const debug_args = test_args ++ .{"-s", "-S"};
    const debug_qemu = b.addSystemCommand(&debug_args);

    debug_qemu.step.dependOn(b.getInstallStep());

    const debug_step = b.step("debug", "Run kernel tests in QEMU with GDB");
    debug_step.dependOn(&debug_qemu.step);

    // -----------------------------
    // gdb - launch gdb for the elf
    // -----------------------------
    const gdb_args = .{
        "riscv64-elf-gdb", "zig-out/bin/kernel-test.elf",
        "-ex", "break kernel.crash",
        "-ex", "target remote :1234",
        // "-ex", "continue",
    };
    const gdb_qemu = b.addSystemCommand(&gdb_args);
    const gdb_step = b.step("gdb", "Run GDB for kernel");
    gdb_step.dependOn(&gdb_qemu.step);


    // -----------------------------
    // addr - address finder
    // -----------------------------
    const addr_step = b.step("addr", "Translate address to source location");

    // Get positional parameter from args
    if (b.args) |args| {
        // Look for address after "addr" in command line
        for (args) | arg | {
            const addr_cmd = b.addSystemCommand(&.{
                "/opt/homebrew/opt/llvm/bin/llvm-addr2line",
                "-e", "zig-out/bin/kernel.elf",
                "-f", arg,
            });
            addr_cmd.step.dependOn(b.getInstallStep());
            addr_step.dependOn(&addr_cmd.step);
        }
    }

    // -----------------------------
    // taddr - address finder (test)
    // -----------------------------
    const taddr_step = b.step("taddr", "Translate address to source location (test)");

    // Get positional parameter from args
    if (b.args) |args| {
        // Look for address after "taddr" in command line
        for (args) | arg | {
            const taddr_cmd = b.addSystemCommand(&.{
                "/opt/homebrew/opt/llvm/bin/llvm-addr2line",
                "-e", "zig-out/bin/kernel-test.elf",
                "-f", arg,
            });
            taddr_cmd.step.dependOn(b.getInstallStep());
            taddr_step.dependOn(&taddr_cmd.step);
        }
    }

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
    const src_dir = std.fs.cwd().openDir("src", .{}) catch @panic("no src dir");
    var walker = src_dir.walk(allocator) catch @panic("failed to walk");
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const asmPath = entry.path;
        if (!std.mem.endsWith(u8, asmPath, ".s")) continue;

        // std.debug.print("including: {s}\n", .{asmPath});
        // exe.addAssemblyFile(b.path(b.pathJoin(&.{ "src", asmPath })));
        exe.addCSourceFile(.{
            .file = b.path(b.pathJoin(&.{ "src", asmPath })),
            .language = .assembly,
            .flags = &.{ "-g", "-fno-omit-frame-pointer" }
        });
    }
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

fn detect_host_time_zone(allocator: std.mem.Allocator) []const u8 {
    if (std.process.getEnvVarOwned(allocator, "TZ")) |tz_env| {
        if (normalize_time_zone(tz_env)) |tz| return tz;
    } else |_| {}

    if (detect_time_zone_from_date(allocator)) |tz| return tz;

    if (std.fs.realpathAlloc(allocator, "/etc/localtime")) |path| {
        if (normalize_time_zone(path)) |tz| return tz;
    } else |_| {}

    return "UTC";
}

fn detect_time_zone_from_date(allocator: std.mem.Allocator) ?[]const u8 {
    var child = std.process.Child.init(&.{ "date", "+%Z" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.stdin_behavior = .Ignore;

    child.spawn() catch return null;

    const stdout_file = child.stdout orelse return null;
    const stdout = stdout_file.readToEndAlloc(allocator, 64) catch return null;
    _ = child.wait() catch {};

    const trimmed = std.mem.trim(u8, stdout, " \n\r\t");
    if (trimmed.len == 0) return null;
    return normalize_time_zone(trimmed);
}

fn normalize_time_zone(name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;

    const tz =
        .{"UTC", "GMT", "PST", "CST", "CDT", "EST", "EDT", "CET", "EET"};

    inline for (tz) |tz_name|
        if (std.ascii.eqlIgnoreCase(name, tz_name)) return tz_name;


    if (std.mem.indexOf(u8, name, "America/New_York") != null) return "EST";
    if (std.mem.indexOf(u8, name, "America/Chicago") != null) return "CST";
    if (std.mem.indexOf(u8, name, "America/Los_Angeles") != null) return "PST";
    if (std.mem.indexOf(u8, name, "Europe/Berlin") != null) return "CET";
    if (std.mem.indexOf(u8, name, "Europe/Helsinki") != null) return "EET";
    if (std.mem.indexOf(u8, name, "Etc/UTC") != null) return "UTC";
    if (std.mem.indexOf(u8, name, "Etc/GMT") != null) return "GMT";

    return null;
}
