const assert = @import("std").debug.assert;
const std = @import("std");

// Generic Doubly-Linked-List, node type T
pub fn DLL(comptime Node: type) type {
    comptime {
        assert(@hasField(Node, "next"));
        assert(@hasField(Node, "prev"));
        assert(@FieldType(Node, "next") == ?*Node);
        assert(@FieldType(Node, "prev") == ?*Node);
    }
    return struct {
        head: ?*Node = null,
        tail: ?*Node = null,
        size: u32 = 0,

        const Self = @This();

        pub fn insert_front(self: *Self, node: *Node) void {
            assert(node.*.next == null and node.*.prev == null);
            if (self.*.head == null) {
                assert(self.*.tail == null);
                self.*.tail = node;
            } else {
                node.*.next = self.*.head;
            }
            self.*.head = node;
            self.*.size += 1;
        }

        pub fn insert_back(self: *Self, node: *Node) void {
            assert(node.*.next == null and node.*.prev == null);
            if (self.*.tail == null) {
                assert(self.*.head == null);
                self.*.head = node;
            } else {
                self.*.tail.?.*.next = node;
            }
            self.*.tail = node;
            self.*.size += 1;
        }

        pub fn pop(self: *Self, node: ?*Node) ?*Node {
            assert(self.*.head != null and self.*.tail != null);
            assert(self.*.size > 0);

            const item = node orelse return null;

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

        pub fn find(self: *Self, item: *Node) ?*Node {
            var cur: ?*Node = self.*.head;
            return while (cur) |cur_node| : (cur = cur_node.*.next){
                if (cur_node.*.data == item) break cur;
            } else null;
        }

        pub fn find_field(self: *Self, comptime field: []const u8, value: anytype) ?*Node {
            comptime assert(@hasField(Node, field));
            comptime assert(@FieldType(Node, field) == @TypeOf(value));
            var cur: ?*Node = self.*.head;
            return while (cur) |cur_node| : (cur = cur_node.*.next) {
                if (@field(cur_node.*.data, field) == value) break cur_node;
            } else null;
        }

        pub fn concat(self: *Self, other: *Self) void {
            const ohead, const otail, const osize = other.displace();
            if (self.*.tail) |tail| {
                tail.*.next = ohead;
                if (ohead) |head| {
                    head.*.prev = self.*.tail;
                    self.*.tail = otail;
                }
            } else {
                self.*.head = ohead;
                self.*.tail = otail;
            }

            self.*.size += osize;
        }

        pub fn displace(self: *Self) .{ ?*Node, ?*Node, u32 } {
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
    };
}
