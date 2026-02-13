const std = @import("std");
const templates = @import("templates/hello.zig");
const User = @import("models.zig").User;

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const w = &stdout.interface;

    // Demo the hello template
    try templates.hello.render("World", w);
    try w.writeAll("\n\n");

    // Demo the list template
    const items = [_][]const u8{ "Apple", "Banana", "Cherry" };
    try templates.list.render(&items, w);
    try w.writeAll("\n\n");

    // Demo the userCard template with imported type
    const user = User{
        .name = "Alice",
        .email = "alice@example.com",
        .is_admin = true,
    };
    try templates.userCard.render(user, w);
    try w.writeAll("\n");

    try w.flush();
}
