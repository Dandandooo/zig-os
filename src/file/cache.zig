const std = @import("std");
const IO = @import("../api/io.zig");
const DLL = @import("../util/list.zig").DLL;
const wait = @import("../conc/wait.zig");
const assert = @import("../util/debug.zig").assert;

const log = std.log.scoped(.FSCACHE);

pub const BLKSZ = 512;
pub const CAPACITY = 64;

const Cache = @This();

bkgio: *IO,
allocator: std.mem.Allocator,
lru: DLL(Entry) = .{},
parole: wait.Condition = .{ .name = "parole" },

const Entry = struct {
    pos: u64,
    next: ?*Entry = null,
    prev: ?*Entry = null,
    lock: wait.Lock = .new("cache lock"),
    data: [BLKSZ]u8 = undefined,
};

pub const Release = enum {
    clean,
    dirty,
};

const Error = IO.Error;

pub fn init(bkgio: *IO, allocator: std.mem.Allocator) Cache {
    assert(bkgio.intf.readat != null, "cache backing IO must support readat");
    assert(bkgio.intf.writeat != null, "cache backing IO must support writeat");

    return .{
        .bkgio = bkgio,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Cache) void {
    while (self.lru.pop(self.lru.head)) |entry|
        self.allocator.destroy(entry);
}

pub fn get(self: *Cache, pos: u64) Error!*[BLKSZ]u8 {
    const entry = try self.get_block(pos);
    return &entry.data;
}

pub fn get_const(self: *Cache, pos: u64) Error!*const [BLKSZ]u8 {
    const entry = try self.get_block(pos);
    return &entry.data;
}

pub fn release(self: *Cache, block: []const u8, state: Release) void {
    const entry: *Entry = @alignCast(@fieldParentPtr("data", @as(*[BLKSZ]u8, @ptrCast(@constCast(block)))));

    switch (state) {
        .clean => {},
        .dirty => {
            const written = self.bkgio.writeat(entry.data[0..], entry.pos) catch |err| e: {
                log.err("failed to write cache block 0x{X}: {s}", .{ entry.pos, @errorName(err) });
                break :e 0;
            };
            if (written != BLKSZ)
                log.err("short cache write at 0x{X}: {d}/{d}", .{ entry.pos, written, BLKSZ });
        },
    }

    entry.lock.release();

    if (self.lru.size > CAPACITY)
        self.parole.broadcast();
}

pub fn flush(self: *Cache) IO.Error!void {
    _ = self;
}

fn get_block(self: *Cache, pos: u64) Error!*Entry {
    assert(pos % BLKSZ == 0, "cache blocks must be aligned");

    const entry = if (self.lru.find_field("pos", pos)) |node|
        node
    else
        try self.fetch(pos);
    entry.lock.acquire();

    if (self.lru.find(entry) != null)
        _ = self.lru.pop(entry);
    self.lru.prepend(entry);

    self.evict_until_fit();

    return entry;
}

fn fetch(self: *Cache, pos: u64) Error!*Entry {
    const entry = self.allocator.create(Entry) catch return IO.Error.Error;
    errdefer self.allocator.destroy(entry);

    entry.* = .{ .pos = pos };

    const read = try self.bkgio.readat(entry.data[0..], pos);
    if (read != BLKSZ) {
        log.err("short cache read at 0x{X}: {d}/{d}", .{ pos, read, BLKSZ });
        return IO.Error.Error;
    }

    return entry;
}

fn evict_until_fit(self: *Cache) void {
    while (self.lru.size > CAPACITY) {
        var to_free = self.lru.tail;
        while (to_free) |entry| {
            const prev = entry.prev;
            if (entry.lock.owner == null) {
                self.allocator.destroy(self.lru.pop(entry).?);
                break;
            }
            to_free = prev;
        } else {
            self.parole.wait();
        }
    }
}
