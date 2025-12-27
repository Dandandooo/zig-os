const std = @import("std");
const build_options = @import("build_options");
const util = @import("util.zig");
const cons = @import("../console.zig");
const assert = @import("../util/debug.zig").assert;


// modules to test

const test_map = .{
    @import("api/io.zig"),
    @import("mem/page.zig"),
    // @import("mem/vmem.zig"),
    @import("dev/virtio.zig"),
};


pub fn run() void {
    var passed: usize = 0;
    var total: usize = 0;

    comptime if (!build_options.test_mode) {
        @compileError("tests.run() requires a test build");
    };

    inline for (test_map) |module| {
        assert(@hasDecl(module, "run"), "test module must contain `run()` function");
        const results: util.test_results = module.run();
        total += results.total;
        passed += results.passed;
    }

    cons.icon_println(util.results, "RESULTS", "Passed {d}/{d} tests", .{ passed, total });
}
