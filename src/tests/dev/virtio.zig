const std = @import("std");
const dev = @import("../../dev/device.zig");
const log = std.log.scoped(.VIRTIO);
const util = @import("../util.zig");

pub fn run() util.test_results {
    return util.merge_results("VIRTIO",
        &[_]util.test_results{util.run_tests( "VIORNG", .{
            .{"shannon entropy test", shannon_entropy_test},
        })},
    );
}

fn shannon_entropy_test() !void {
    const bufsz = 256;
    log.debug("hi", .{});
    var buf: [bufsz]u8 = [_]u8{0} ** bufsz;
    log.debug("hi", .{});
    const io = try dev.open("rng");
    log.debug("hi", .{});
    try io.fill(&buf);
    log.debug("hi", .{});
    var counts: [256]u8 = [_]u8{0} ** 256;
    log.debug("hi", .{});
    for (buf) |n| counts[n] += 1;
    log.debug("hi", .{});
    // Empirical entropy for a 256-byte sample should still be high, but not
    // near 8.0 due to sample size limits.
    try util.expect(try calculate_entropy_q10(&counts) > 7000); // > ~6.84 bits
}

const log2_q10 = blk: {
    var table: [257]u16 = [_]u16{0} ** 257;
    for (1..257) |n| {
        const x: f64 = @floatFromInt(n);
        table[n] = @intFromFloat(std.math.log2(x) * 1024.0);
    }
    break :blk table;
};

fn calculate_entropy_q10(counts: []const u8) !u32 {
    try util.expect(counts.len == 256);

    var weighted_log_sum_q10: u32 = 0;
    for (counts) |c| {
        if (c == 0) continue;
        weighted_log_sum_q10 += @as(u32, c) * log2_q10[c];
    }

    // H = 8 - (1/256) * sum(c * log2(c)), scaled by 1024.
    const eight_q10: u32 = 8 * 1024;
    return eight_q10 - (weighted_log_sum_q10 / 256);
}
