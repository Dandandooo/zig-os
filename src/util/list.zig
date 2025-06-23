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

        fn new_node(self: DLL(T), value: T) *node {
            return if (self.allocator != null)
                self.allocator.create(node) catch @panic("cannot create node")
            else &value;
        }

        fn insert_front(self: DLL(T), data: T) void {
            const new = DLL(T).new_node();
            new.* = node{.data = data};

            if (self.head == null) {
                assert(self.tail == null);
                self.head, self.tail = new;
            } else {
                new.*.next = self.head;
                self.head = new;
            }
        }

        fn insert_back(self: DLL(T), data: T) void {
            const new = self.allocator.create(node) catch @panic("cannot create node");
            new.* = node{.data = data};

            if (self.tail == null) {
                assert(self.head == null);
                self.head, self.tail = new;
            } else {
                self.tail.?.*.next = new;
                self.tail = new;
            }
        }

        fn pop(self: DLL(T), item: *node) T {
            assert(self.head != null and self.tail != null);

        }

        fn find(self: DLL(T), item: T) ?*node {
            var cur: ?*node = self.head;
            return while (cur) |cur_node| : (cur = cur_node.*.next){
                if (cur_node.*.data == item) break cur;
            } else null;
        }

        fn find_field(self: DLL(T), comptime field: []const u8, value: anytype) ?*node {
            assert(@FieldType(T, field) == @TypeOf(value));
            var cur: ?*node = self.head;
            return while (cur) |cur_node| : (cur = cur_node.*.next) {
                if (@field(cur_node.*.data, field) == value) break cur_node;
            } else null;
        }

        fn destroy(self: DLL(T)) void {
            while (self.head) |node_ptr| self.pop(node_ptr);
        }

    };
}
