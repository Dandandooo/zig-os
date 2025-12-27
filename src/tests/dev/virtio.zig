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
    try util.expect(try calculate_entropy(&counts) > 7.99);
}

fn calculate_entropy(counts: []const u8) !f64 {
    try util.expect(counts.len == 256);

    var total: f64 = 0.0;
    for (counts) |c| total += @floatFromInt(c);

    var probs: [256]f64 = undefined;
    for (counts, 0..) |c, i| probs[i] = @as(f64, @floatFromInt(c))/total;

    var entropy: f64 = 0;
    for (probs) |p| entropy -= p * std.math.log2(p);

    return entropy;
}
