const std = @import("std");
const cons = @import("../console.zig");
const assert = @import("../util/debug.zig").assert;

const gay = @import("build_options").gay;

pub const running: [:0]const u8 = if (gay) "🍲" else "⏱️ ";
pub const pass: [:0]const u8 = if (gay) "💅" else "✅";
pub const fail: [:0]const u8 = if (gay) "🥀" else "🚫";
pub const results: [:0]const u8 = if (gay) "🏆" else "📋";
pub const reset: [:0]const u8 = "\r\x1b[2K";

pub const test_results = struct {
    passed: u32,
    total: u32
};

pub const test_error = error {
    Incorrect,
};

pub const test_function = fn () test_error!void;

pub const test_pair = struct {
    name: []const u8,
    func: test_function
};

const pad = "=" ** 15;

pub fn run_tests(comptime scope: []const u8, comptime tests: anytype) test_results {
    var total: u32 = 0;
    var failed: u32 = 0;

    cons.print("\x1b[90m" ++ pad ++ "{s:=^8}" ++ pad ++ "\x1b[0m\n", .{" " ++ scope ++ " "});

    inline for (tests) |t| {
        const name = t[0];
        const tfunc = t[1];
        var terror: ?anyerror = null;

        cons.icon_print(running, scope, "{s}", .{name});

        cons.disable();

        total += 1;
        tfunc() catch |err| {
            terror = err;
            failed += 1;
        };

        cons.enable();

        if (terror) |err| cons.icon_println(reset ++ fail, scope, "\x1b[31m{s}\x1b[0m: {s}", .{name, @errorName(err)})
        else cons.icon_println(reset ++ pass, scope, "\x1b[32m{s}\x1b[0m", .{name});
    }

    cons.icon_println(results, scope, "Passed {d}/{d} tests", .{ total - failed, total });
    return .{ .passed = total - failed, .total = total };
}

pub fn expect(ok: bool) test_error!void {
    if (!ok) return test_error.Incorrect;
}
