// KTFS driver tests against the real ktfs.raw disk image.
//
// The KTFS driver (src/file/ktfs.zig) is still a stub: the fs.zig union
// refuses to mount it. These tests document the expected behavior once it
// lands and fail cleanly (Unsupported) until then. They must only reach
// KTFS through the FS union so the unfinished driver code is never
// analyzed directly.

const FS = @import("../../file/fs.zig");
const dev = @import("../../dev/device.zig");
const heap = @import("../../mem/heap.zig");
const util = @import("../util.zig");
const manifest = @import("testfiles");

pub fn run() util.test_results {
    return util.run_tests("KTFS", &.{
        .{ .name = "Mount (TODO)", .func = test_mount },
    });
}

/// The first vioblk device holds the ktfs image (see build.zig's qemu args).
fn test_mount() anyerror!void {
    const blkio = try dev.open("vioblk");
    defer blkio.close();

    var vfs = try FS.mount(.ktfs, blkio, heap.allocator);
    defer vfs.deinit();

    try util.expect(vfs.filecount() == manifest.entries.len);
}
