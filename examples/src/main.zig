const std = @import("std");
const templates = @import("templates/hello.zig");
const User = @import("models.zig").User;
const Post = @import("models.zig").Post;

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const w = &stdout.interface;

    const user = User{
        .name = "Alice",
        .email = "alice@example.com",
    };

    const posts = [_]Post{
        .{
            .id = 1,
            .slug = "hello-world",
            .title = "Hello World",
            .subtitle = "My first post",
            .tags = &.{ "intro", "welcome" },
            .created_at = 1705312800,
        },
        .{
            .id = 2,
            .slug = "zig-templates",
            .title = "Building Templates in Zig",
            .subtitle = null,
            .tags = &.{ "zig", "templates", "tutorial" },
            .created_at = 1705399200,
        },
    };

    try templates.HomePage.render(.{ user, &posts }, w);
    try w.writeAll("\n");
    try w.flush();
}
