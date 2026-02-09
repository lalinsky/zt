# Zig Templating

Small HTML templating language that compiles to Zig at build-time.
Inspired by [JSX], [Zeix] and [Templ].

[JSX]: https://react.dev/learn#writing-markup-with-jsx
[Zeix]: https://ziex.dev/
[Templ]: https://templ.guide/

## Syntax

### Templates

```zig
const User = @import("../models.zig").User;

pub templ UserDetails(user: User) {
    <div class="card">
        <h2>{user.name}</h2>
        <p>{user.email}</p>
    </div>
}

pub templ UserList(users: []const User) {
    <h1>Users</h1>
    <div>
        for (users) |user| {
            @UserDetails(user)
        }
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
