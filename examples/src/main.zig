const std = @import("std");
const templates = @import("templates/hello.zig");
const User = @import("models.zig").User;

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const w = &stdout.interface;

    const user = User{
        .name = "Alice",
        .email = "alice@example.com",
        .is_admin = true,
    };

    // Demo the hello template
    try w.writeAll("=== hello ===\n");
    try templates.hello.render(.{"World"}, w);
    try w.writeAll("\n\n");

    // Demo the list template
    try w.writeAll("=== list ===\n");
    const items = [_][]const u8{ "Apple", "Banana", "Cherry" };
    try templates.list.render(.{&items}, w);
    try w.writeAll("\n\n");

    // Demo the userCard template with imported type
    try w.writeAll("=== userCard ===\n");
    try templates.userCard.render(.{user}, w);
    try w.writeAll("\n\n");

    // Demo bind: type-erase a template + args into a Component
    try w.writeAll("=== bind ===\n");
    const args: templates.hello.Args = .{"World"};
    const component = templates.hello.bind(&args);
    try component.render(w);
    try w.writeAll("\n\n");

    // Demo component inheritance: page wraps content in layout
    try w.writeAll("=== page (inheritance) ===\n");
    try templates.page.render(.{ "My Page", user }, w);
    try w.writeAll("\n\n");

    // Demo passing a zt.Component as a template parameter
    try w.writeAll("=== sidebar (component param) ===\n");
    const card_args: templates.userCard.Args = .{user};
    const card = templates.userCard.bind(&card_args);
    try templates.sidebar.render(.{ "User Info", card }, w);
    try w.writeAll("\n");

    try w.flush();
}
