# zt - Zig Templating

A compile-time templating system for Zig that compiles `.zt` files to Zig code.

## Features

- **Compile-time** - Templates are compiled to Zig code at build time
- **Type-safe** - Full Zig type checking on template parameters and expressions
- **Familiar syntax** - HTML with embedded Zig expressions
- **Components** - Call other templates with `@Component(args)`
- **Control flow** - `if`/`for` both block-level and inline
- **Auto-escaping** - HTML entities escaped by default, `{!expr}` for raw output
- **Optional attributes** - Attributes with `null` values are omitted entirely

## Syntax

### Templates

```zig
const User = @import("../models.zig").User;

pub templ UserCard(user: User) {
    <div class="card">
        <h2>{user.name}</h2>
        <p>{user.email}</p>
    </div>
}
```

### Expressions

```zig
// Escaped output (default)
<span>{user.name}</span>
<span>{formatDate(post.created_at)}</span>

// Raw/unescaped output
<div>{!trustedHtml}</div>
```

### Attributes

```zig
// Static
<div class="card" id="main"></div>

// Dynamic
<div class={className} data-id={item.id}></div>

// Boolean
<input type="checkbox" checked disabled />

// Optional (omitted if null)
<div class={if (active) "active" else null}></div>
<a href={maybeUrl}>Link</a>
```

### Control Flow

Block-level:

```zig
if (user.is_admin) {
    <span class="badge">Admin</span>
}

for (items) |item| {
    <li>{item.name}</li>
}

for (items, 0..) |item, idx| {
    <li>{idx}: {item.name}</li>
}

switch (status) {
    .active => {
        <span class="green">Active</span>
    },
    .pending => |msg| {
        <span class="yellow">{msg}</span>
    },
    else => {
        <span>Unknown</span>
    },
}
```

Inline:

```zig
{if (user.admin) <span>Admin</span> else <span>User</span>}
{if (user.nickname) |nick| nick else user.name}
{for (tags) |tag| <span class="tag">{tag}</span>}
{switch (role) .admin => <span>Admin</span>, .user => <span>User</span>, else => <span>Guest</span>}
```

### Component Calls

```zig
pub templ Page(user: User, posts: []const Post) {
    <html>
        <body>
            @Header()
            @UserCard(user)
            for (posts) |post| {
                @PostCard(post)
            }
            @Footer()
        </body>
    </html>
}

// With module prefix
const components = @import("components.zig");

pub templ Page() {
    @components.Header()
    @components.Footer()
}
```

### Zig Functions

You can define regular Zig functions alongside templates:

```zig
const std = @import("std");

pub fn formatPrice(cents: i64) []const u8 {
    // ...
}

pub templ Product(item: Item) {
    <div class="price">{formatPrice(item.price)}</div>
}
```

## Build Integration

In your `build.zig`:

```zig
const zt = @import("zt");

pub fn build(b: *std.Build) void {
    const zt_dep = b.dependency("zt", .{
        .target = target,
        .optimize = optimize,
    });

    // Compile templates
    const templates = zt.addTemplates(b, zt_dep, &.{
        "src/templates/Page.zt",
        "src/templates/UserCard.zt",
    });

    const exe = b.addExecutable(.{ ... });
    exe.root_module.addImport("zt", zt_dep.module("zt"));
    exe.step.dependOn(templates);
}
```

## Usage

```zig
const templates = @import("templates/Page.zig");

pub fn handleRequest(writer: anytype) !void {
    const user = getUser();
    try templates.Page(user, writer);
}
```

## Generated Output

Templates compile to regular Zig functions:

```zig
// hello.zt
pub templ Hello(name: []const u8) {
    <div class="greeting">
        <h1>Hello, {name}!</h1>
    </div>
}

// hello.zig (generated)
pub fn Hello(name: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("<div class=\"greeting\">");
    try writer.writeAll("<h1>");
    try writer.writeAll("Hello, ");
    try zt.writeEscaped(writer, name);
    try writer.writeAll("!");
    try writer.writeAll("</h1>");
    try writer.writeAll("</div>");
}
```

## License

MIT
