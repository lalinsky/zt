# Zig Templating

*This is still an experimental project. Feedback is welcome, but use with caution.*

A small HTML templating language that compiles to Zig at build-time.
Inspired by [Templ], [Zeix] and [JSX].

The idea is to invent as little syntax as possible, just enough to make it possible to interweave real Zig code with HTML elements.
Using this approach, the template compiler can stay very simple and delegate Zig code analysis to the real Zig compiler.

Templates are transpiled into Zig source files as part of `zig build`, so you can just import them like any other
source files in your application. Everything is fully type-checked by the Zig compiler, and there is no
overhead at runtime. Output is directly written to a `std.Io.Writer`, so there is no state and no allocations.

[JSX]: https://react.dev/learn#writing-markup-with-jsx
[Zeix]: https://ziex.dev/
[Templ]: https://templ.guide/

## Installation

```bash
zig fetch --save git+https://github.com/lalinsky/zt
```

Configure your `build.zig`:

```zig
const std = @import("std");
const zt = @import("zt");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zt_dep = b.dependency("zt", .{
        .target = target,
        .optimize = optimize,
    });

    // Compile templates (.zt → .zig)
    const templates = zt.addTemplates(b, zt_dep, &.{
        b.path("src/templates/pages.zt"),
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zt", zt_dep.module("zt"));

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = root_module,
    });
    exe.step.dependOn(templates);

    b.installArtifact(exe);
}
```

## Usage

```zig
const std = @import("std");
const pages = @import("templates/pages.zig");

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const w = &stdout.interface;

    try pages.Home.render(.{ "Welcome" }, w);
    try w.flush();
}
```

---

## Example

```zig
const Post = @import("../models.zig").Post;
const User = @import("../models.zig").User;

fn formatDate(ts: i64) []const u8 {
    // ...
}

pub templ Layout(title: []const u8) {
    <!DOCTYPE html>
    <html>
        <head>
            <title>{title}</title>
            <link rel="stylesheet" href="/style.css" />
        </head>
        <body>
            @Nav()
            <main>
                @children
            </main>
        </body>
    </html>
}

pub templ Nav() {
    <nav>
        <a href="/">Home</a>
        <a href="/about">About</a>
    </nav>
}

pub templ PostCard(post: Post) {
    <article class="card">
        <h2><a href="/posts/{post.id}/{post.slug}">{post.title}</a></h2>
        <time>{formatDate(post.created_at)}</time>
        if (post.subtitle) |subtitle| {
            <p class="subtitle">{subtitle}</p>
        }
        <div class="tags">
            {for (post.tags) |tag| <span class="tag">{tag}</span>}
        </div>
    </article>
}

pub templ HomePage(user: ?User, posts: []const Post) {
    @Layout("Home") {
        if (user) |u| {
            <p>Welcome back, {u.name}!</p>
        } else {
            <p>Welcome, guest! <a href="/login">Log in</a></p>
        }
        <section class="posts">
            for (posts) |post| {
                @PostCard(post)
            }
        </section>
    }
}
```

---

## Syntax

### Templates

Templates are defined with `templ` and compile to structs with a `render` method:

```zig
pub templ Greeting(name: []const u8) {
    <h1>Hello, {name}!</h1>
}
```

### Zig Code

Standard Zig code goes at the top of the file and is passed through unchanged:

```zig
const std = @import("std");
const Post = @import("../models.zig").Post;

fn formatDate(ts: i64) []const u8 {
    // ...
}

pub templ Article(post: Post) {
    <article>
        <time>{formatDate(post.created_at)}</time>
        <h1>{post.title}</h1>
    </article>
}
```

---

## Elements

```zig
pub templ Document() {
    <!DOCTYPE html>
    <html>
        <head>
            <title>My Page</title>
            <link rel="stylesheet" href="/style.css" />
        </head>
        <body>
            <div>
                Content
            </div>
            <img src="avatar.png" />
        </body>
    </html>
}
```

All HTML elements must be explicitly closed, but void elements like `<img>` and `<link>` will be rendered correctly without the closing slash.

---

## Attributes

**Static** - quoted string values:

```zig
<div class="container" id="main"></div>
```

**Dynamic** - Zig expressions in braces:

```zig
<div class={className} data-id={item.id}></div>
```

**Interpolated** - mix static and dynamic parts:

```zig
<a href="/posts/{post.id}/{post.slug}">Read more</a>
```

**Boolean** - presence means true:

```zig
<input type="checkbox" checked disabled />
```

**Optional** - attribute omitted when value is null:

```zig
<a href={item.url}>Link</a>
<div class={if (isActive) "active" else null}></div>
```

---

## Expressions

**Escaped output** (default) - safe for user content:

```zig
<span>{comment.text}</span>
```

**Raw output** - for trusted HTML only:

```zig
<div>{!article.html_content}</div>
```

---

## Control Flow

### If/Else

Block-level:

```zig
if (user.is_admin) {
    <span class="badge">Admin</span>
}

if (post.subtitle) |subtitle| {
    <h2>{subtitle}</h2>
}
```

Inline:

```zig
<span>{if (user.premium) "Pro" else "Free"}</span>
{if (error) |msg| <div class="error">{msg}</div>}
```

### For Loops

Block-level:

```zig
<ul>
    for (items) |item| {
        <li>{item.name}</li>
    }
</ul>

for (rows, 0..) |row, i| {
    <tr class={if (i % 2 == 0) "even" else "odd"}>...</tr>
}
```

Inline:

```zig
<nav>{for (links) |link| <a href={link.url}>{link.title}</a>}</nav>
```

### Switch

Block-level:

```zig
switch (order.status) {
    .pending => {
        <span class="yellow">Processing</span>
    },
    .shipped => |tracking| {
        <a href={tracking}>Track package</a>
    },
    else => {
        <span>Unknown</span>
    },
}
```

Inline:

```zig
{switch (user.role) .admin => <b>Admin</b>, .mod => <i>Mod</i>, else => <span>User</span>}
```

---

## Components

Call other templates with `@`:

```zig
pub templ Nav() {
    <nav>...</nav>
}

pub templ Page() {
    @Nav()
    <main>Content</main>
}
```

With imports:

```zig
const ui = @import("ui.zig");

pub templ Page() {
    @ui.Button("Click me")
}
```

### Children

Parent templates use `@children` to render nested content:

```zig
pub templ Card(title: []const u8) {
    <div class="card">
        <h2>{title}</h2>
        <div class="body">
            @children
        </div>
    </div>
}

pub templ Page() {
    @Card("Welcome") {
        <p>This appears inside the card body.</p>
    }
}
```

Nesting works to any depth:

```zig
pub templ Page() {
    @Layout("Home") {
        @Card("News") {
            <p>Latest updates...</p>
        }
    }
}
```

### Components as Parameters

Templates can accept `zt.Component` for dynamic composition:

```zig
pub templ Modal(title: []const u8, body: zt.Component) {
    <div class="modal">
        <h2>{title}</h2>
        @body
    </div>
}
```

Create components with `bind`:

```zig
const args: templates.Alert.Args = .{ "Something went wrong" };
const alert = templates.Alert.bind(&args);
try templates.Modal.render(.{ "Error", alert }, writer);
```

---

## API

Each template generates:

- `render(args, writer) !void` - render to a writer
- `bind(args) zt.Component` - create a type-erased component
- `Args` - the argument tuple type

See `examples/` for a runnable project:

```bash
cd examples
zig build run
```
