pub const User = struct {
    name: []const u8,
    email: []const u8,
};

pub const Post = struct {
    id: u32,
    slug: []const u8,
    title: []const u8,
    subtitle: ?[]const u8,
    tags: []const []const u8,
    created_at: i64,
};
