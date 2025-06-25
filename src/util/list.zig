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

        pub const node = struct {
            data: T,
            next: ?*node = null,
            prev: ?*node = null,
        };

        fn new_node(self: DLL(T), value: anytype) *node {
            return switch (@TypeOf(value)) {
                T => alloc: {
                    const new: *node = if (self.allocator != null)
                        self.allocator.create(node) catch @panic("allocator failed")
                    else &value;

                    new.* = node{.data = value};
                    break :alloc new;
                },
                *node => value,
                else => @panic("list got wrong datatype")
            };
        }

        pub fn insert_front(self: DLL(T), data: anytype) void {
            const new = DLL(T).new_node(data);

            if (self.head == null) {
                assert(self.tail == null);
                self.head, self.tail = new;
            } else {
                new.*.next = self.head;
                self.head = new;
            }
        }

        pub fn insert_back(self: DLL(T), data: T) void {
            const new = DLL(T).new_node();
            new.* = node{.data = data};

            if (self.*.tail == null) {
                assert(self.head == null);
                self.head = new;
                self.tail = new;
            } else {
                self.tail.?.*.next = new;
                self.tail = new;
            }
        }

        pub fn pop(self: *DLL(T), item: *node) *node {
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

        pub fn find(self: *DLL(T), item: T) ?*node {
            var cur: ?*node = self.*.head;
            return while (cur) |cur_node| : (cur = cur_node.*.next){
                if (cur_node.*.data == item) break cur;
            } else null;
        }

        pub fn find_field(self: *DLL(T), comptime field: []const u8, value: anytype) ?*node {
            comptime assert(@hasField(T, field));
            comptime assert(@FieldType(T, field) == @TypeOf(value));
            var cur: ?*node = self.*.head;
            return while (cur) |cur_node| : (cur = cur_node.*.next) {
                if (@field(cur_node.*.data, field) == value) break cur_node;
            } else null;
        }

        pub fn displace(self: *DLL(T)) .{ ?*node, ?*node, u32 } {
            defer {
                self.*.head = null;
                self.*.tail = null;
                self.*.size = 0;
            }
            return .{ self.*.head, self.*.tail, self.*.size };
        }

        pub fn destroy(self: *DLL(T)) void {
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

        pub fn iter(self: *DLL(T)) iterator {
            return iterator{ .cur = self.*.head };
        }
    };
}
