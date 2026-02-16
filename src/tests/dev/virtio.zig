const std = @import("std");
const dev = @import("../../dev/device.zig");
const log = std.log.scoped(.VIRTIO);
const util = @import("../util.zig");
const heap = @import("../../mem/heap.zig");

pub fn run() util.test_results {
    return util.merge_results("VIRTIO",
        &[_]util.test_results{
            util.run_tests( "VIORNG", &.{
                .{.name = "shannon entropy test", .func = shannon_entropy_test},
            }),
            util.run_tests("VIOBLK", &.{
                .{.name = "write then read", .func = vioblk_write_read_test, .cons = true}
            })
        },
    );

}

fn shannon_entropy_test() anyerror!void {
    const bufsz = 256;
    var buf: [bufsz]u8 = [_]u8{0} ** bufsz;
    const io = try dev.open("rng");
    try io.fill(&buf);
    var counts: [256]u8 = [_]u8{0} ** 256;
    for (buf) |n| counts[n] += 1;
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

fn vioblk_write_read_test() anyerror!void {
    const blksz = 512;
    const num_blocks = 4;
    const bufsz = blksz * num_blocks;

    // Open the block device
    const io = try dev.open("vioblk");
    defer io.close();

    // Save original bytes
    const orig_buf: []u8 = try heap.allocator.alloc(u8, blksz);
    defer heap.allocator.free(orig_buf);
    const read_orig = try io.readat(orig_buf, 0);
    try util.expect(read_orig == bufsz);

    // Create test pattern: ascending bytes
    const write_buf: []u8 = try heap.allocator.alloc(u8, blksz);
    defer heap.allocator.free(write_buf);
    for (0..bufsz) |i| {
        write_buf[i] = @intCast(i % 256);
    }

    // Write to sector 0
    const written = try io.writeat(write_buf, 0);
    try util.expect(written == bufsz);

    // Read back from sector 0
    const read_buf: []u8 = try heap.allocator.alloc(u8, blksz);
    defer heap.allocator.free(read_buf);
    @memset(read_buf, 0);
    const read = try io.readat(read_buf, 0);
    try util.expect(read == bufsz);

    // Verify consistency
    for (0..bufsz) |i| {
        try util.expect(read_buf[i] == write_buf[i]);
    }

    // Restore original bytes
    const restored = try io.writeat(orig_buf, 0);
    try util.expect(restored == bufsz);

    // Verify restoration
    const verify_buf: []u8 = try heap.allocator.alloc(u8, blksz);
    defer heap.allocator.free(verify_buf);
    @memset(verify_buf, 0);
    const read_verify = try io.readat(verify_buf, 0);
    try util.expect(read_verify == bufsz);
    for (0..bufsz) |i| {
        try util.expect(verify_buf[i] == orig_buf[i]);
    }

}
