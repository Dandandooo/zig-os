const assert = @import("std").debug.assert;
const std = @import("std");

// Generic Doubly-Linked-List
pub fn DLL(comptime T: type) type {
    return struct {
        head: ?*node = null,
        tail: ?*node = null,
        size: u32 = 0,

        // If null, everything is stack allocated / embedded
        allocator: ?*std.mem.Allocator,

        const Self = @This();

        pub const node = struct {
            data: T,
            next: ?*node = null,
            prev: ?*node = null,
        };

        fn new_node(self: *Self, value: anytype) *node {
            return switch (@TypeOf(value)) {
                T => alloc: {
                    const new: *node = if (self.allocator != null)
                        self.*.allocator.create(node) catch @panic("allocator failed")
                    else &value;

                    new.* = node{.data = value};
                    break :alloc new;
                },
                *node => value,
                else => @panic("list got wrong datatype")
            };
        }

        pub fn insert_front(self: *Self, data: anytype) void {
            const new = self.new_node(data);

            if (self.*.head == null) {
                assert(self.*.tail == null);
                self.*.head = new;
                self.*.tail = new;
            } else {
                new.*.next = self.*.head;
                self.*.head = new;
            }
        }

        pub fn insert_back(self: *Self, data: T) void {
            const new = self.new_node(data);

            if (self.*.tail == null) {
                assert(self.*.head == null);
                self.*.head = new;
                self.*.tail = new;
            } else {
                self.*.tail.?.*.next = new;
                self.*.tail = new;
            }
        }

        pub fn pop(self: *Self, item: *node) *node {
            assert(self.*.head != null and self.*.tail != null);
            assert(self.*.size > 0);

            if (item.*.prev == null and item.*.next == null and item != self.*.head.?)
                return item; // item not in list

            if (item == self.*.head.?) {
                assert(item.*.prev == null);
                self.*.head = self.*.head.?.*.next;
            } else item.*.prev.?.*.next = item.*.next;

            if (item == self.*.tail.?) {
                assert(item.*.next == null);
                self.*.tail = self.*.tail.?.*.prev;
            } else item.*.next.?.*.prev = item.*.prev;

            item.next = null;
            item.prev = null;

            self.*.size -= 1;

            return item;
        }

        pub fn find(self: *Self, item: T) ?*node {
            var cur: ?*node = self.*.head;
            return while (cur) |cur_node| : (cur = cur_node.*.next){
                if (cur_node.*.data == item) break cur;
            } else null;
        }

        pub fn find_field(self: *Self, comptime field: []const u8, value: anytype) ?*node {
            comptime assert(@hasField(T, field));
            comptime assert(@FieldType(T, field) == @TypeOf(value));
            var cur: ?*node = self.*.head;
            return while (cur) |cur_node| : (cur = cur_node.*.next) {
                if (@field(cur_node.*.data, field) == value) break cur_node;
            } else null;
        }

        pub fn displace(self: *Self) .{ ?*node, ?*node, u32 } {
            defer {
                self.*.head = null;
                self.*.tail = null;
                self.*.size = 0;
            }
            return .{ self.*.head, self.*.tail, self.*.size };
        }

        pub fn destroy(self: *Self) void {
            while (self.*.head) |node_ptr| {
                const removed = self.*.pop(node_ptr);
                if (self.*.allocator != null)
                    self.*.allocator.?.destroy(removed);
            }
        }

        // Custom Iteration
        const iterator = struct {
            cur: ?*node,

            pub fn next(self: *iterator) ?*node {
                defer {if (self.*.cur) |cur| self.*.cur = cur.*.next;}
                return self.*.cur;
            }
        };

        pub fn iter(self: *Self) iterator {
            return iterator{ .cur = self.*.head };
        }
    };
}
