
pub const context = struct {
    s: [12]u64,
    ra: *anyopaque,
    sp: *anyopaque
};

pub const thread = struct {

};

pub const condition = struct {
    name: []const u8,

};
