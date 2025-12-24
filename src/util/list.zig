const std = @import("std");
const log = std.log.scoped(.DLL);
const assert = @import("debug.zig").assert;

// Generic Doubly-Linked-List, node type T
pub fn DLL(comptime Node: type) type {
    comptime {
        assert(@hasField(Node, "next"), "type needs to have pred");
        assert(@hasField(Node, "prev"), "type needs to have next");
        assert(@FieldType(Node, "next") == ?*Node, "improper pointer type");
        assert(@FieldType(Node, "prev") == ?*Node, "improper pointer type");
    }
    return struct {
        head: ?*Node = null,
        tail: ?*Node = null,
        size: u32 = 0,

        const Self = @This();

        pub fn prepend(self: *Self, node: *Node) void {
            assert(node.next == null and node.prev == null, "node already attached");
            if (self.head == null) {
                assert(self.tail == null, "list with tail but no head");
                self.tail = node;
            } else {
                node.next = self.head;
            }
            self.head = node;
            self.size += 1;
        }

        pub fn append(self: *Self, node: *Node) void {
            assert(node.next == null and node.prev == null, "node already attached");
            if (self.tail == null) {
                assert(self.head == null, "list with head but no tail");
                self.head = node;
            } else {
                self.tail.?.next = node;
            }
            self.tail = node;
            self.size += 1;
        }

        pub fn insert(self: *Self, node: *Node, after: ?*Node) void {
            if (after) |n|
                assert(self.find(n) != null, "must insert into list");
            assert(self.find(node) == null, "node already in list");

            if (after == null)
                return self.prepend(node);
            if (after == self.tail)
                return self.append(node);

            const prev = after.?;
            prev.next.?.prev = node;
            node.next = prev.next;
            prev.next = node;
            node.prev = prev;
        }

        pub fn pop(self: *Self, node: ?*Node) ?*Node {
            const item = node orelse return null;

            assert(self.find(item) != null, "item not in list");

            if (item == self.head.?) {
                assert(item.prev == null, "head is not the first");
                self.head = self.head.?.next;
            } else item.prev.?.next = item.next;

            if (item == self.tail.?) {
                assert(item.next == null, "tail is not the last");
                self.tail = self.tail.?.prev;
            } else item.next.?.prev = item.prev;

            item.next = null;
            item.prev = null;

            self.size -= 1;

            return item;
        }

        pub fn find(self: *Self, item: *Node) ?*Node {
            var cur: ?*Node = self.head;
            return while (cur) |cur_node| : (cur = cur_node.next) {
                if (cur_node == item) break cur;
            } else null;
        }

        pub fn find_field(self: *Self, comptime field: []const u8, value: anytype) ?*Node {
            comptime assert(@hasField(Node, field), "field not present in type");
            comptime assert(@FieldType(Node, field) == @TypeOf(value), "field is wrong type");
            var cur: ?*Node = self.head;
            return while (cur) |cur_node| : (cur = cur_node.next) {
                if (@field(cur_node, field) == value) break cur_node;
            } else null;
        }

        pub fn concat(self: *Self, other: *Self) void {
            const ohead, const otail, const osize = other.displace();
            if (self.tail) |tail| {
                tail.next = ohead;
                if (ohead) |head| {
                    head.prev = self.tail;
                    self.tail = otail;
                }
            } else {
                self.head = ohead;
                self.tail = otail;
            }

            self.size += osize;
        }

        pub fn displace(self: *Self) struct { ?*Node, ?*Node, u32 } {
            defer {
                self.head = null;
                self.tail = null;
                self.size = 0;
            }
            return .{ self.head, self.tail, self.size };
        }
    };
}

pub fn LL(comptime Node: type) type {
    comptime {
        assert(@hasField(Node, "next"), "node must have next pointer");
        assert(@TypeOf(Node.next) == ?*Node, "next must be same type as current");
    }
    return struct {
        head: ?*Node = null,
        tail: ?*Node = null,
        size: u32,

        const Self = @This();

        pub fn prepend(self: *Self, node: *Node) void {
            assert(node.next == null);
            if (self.head) |head| {
                node.next = head;
            } else { self.tail = node; }
            self.head = node;
            self.size += 1;
        }

        pub fn append(self: *Self, node: *Node) void {
            assert(node.next == null);
            if (self.tail) |tail| {
                tail.next = node;
            } else { self.head = node; }
            self.tail = node;
            self.size += 1;
        }

        pub fn find_field(self: *Self, comptime field: []const u8, value: anytype) struct {?*Node, ?*Node} {
            comptime {
                assert(@hasField(Node, field), "LL: search by existing field please!");
                assert(@FieldType(Node, field) == @TypeOf(value), "LL: invalid search query!");
            }

            var cur: ?*Node = self.head;
            var prev: ?*Node = null;

            return while (cur) |cur_node| : ({prev = cur; cur = cur_node.next; }) {
                if (@field(cur_node, field) == value) return .{prev, cur};
            } else .{prev, null};
        }

        pub fn find(self: *Self, node: *Node) ?*Node {
            var cur: ?*Node = self.head;
            var prev: ?*Node = null;
            return while (cur) |cur_node| : ({prev = cur; cur = cur_node.next; }) {
                if (cur_node == node) return .{prev, cur};
            } else .{prev, null};
        }

        pub fn pop(self: *Self, node: ?*Node) ?*Node {
            const item = node orelse return null;
            const prev, const cur = self.find(item);
            assert(cur != null, "node not in LL");
            if (prev) |prev_node| {
                prev_node.next = item.next;
            } else { self.head = item.next; }

            if (item == self.tail.?) self.tail = prev;

            item.next = null;
            self.size -= 1;
            return item;
        }

        pub fn concat(self: *Self, other: *Self) void {
            const ohead, const otail, const osize = other.displace();
            if (self.tail) |tail| {
                tail.next = ohead;
                if (ohead)
                    self.tail = otail;
            } else {
                self.head = ohead;
                self.tail = otail;
            }

            self.size += osize;
        }

        pub fn displace(self: *Self) struct { ?*Node, ?*Node, u32 } {
            defer {
                self.head = null;
                self.tail = null;
                self.size = 0;
            }
            return .{ self.head, self.tail, self.size };
        }
    };
}
