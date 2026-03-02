import os
import subprocess
import re
from pathlib import Path
import pytest


def setup_workdir(project_root: Path, workdir: Path):
    """Initialize zig project and build files (called once per session)."""
    env = os.environ.copy()
    env["ZIG_LOCAL_CACHE_DIR"] = str(workdir / ".zig-cache")

    subprocess.run(["zig", "init"], cwd=workdir, check=True, capture_output=True, env=env)

    # Rewrite build.zig
    build_zig = workdir / "build.zig"
    build_zig.write_text('''
const std = @import("std");
const zt = @import("zt");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zt_dep = b.dependency("zt", .{});

    const templates = zt.addTemplates(b, zt_dep, &.{
        b.path("src/tpl.zt"),
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zt", zt_dep.module("zt"));

    const exe = b.addExecutable(.{
        .name = "runner",
        .root_module = root_module,
    });
    exe.step.dependOn(templates);

    const run = b.addRunArtifact(exe);
    b.step("run", "").dependOn(&run.step);
}
''')

    # Extract name and fingerprint, rewrite build.zig.zon
    build_zon = workdir / "build.zig.zon"
    zon_content = build_zon.read_text()
    name = re.search(r'\.name\s*=\s*\.(\w+)', zon_content).group(1)
    fingerprint = re.search(r'\.fingerprint\s*=\s*(0x[0-9a-f]+)', zon_content).group(1)
    zt_path = os.path.relpath(project_root, workdir).replace("\\", "/")
    build_zon.write_text(f'''
.{{
    .name = .{name},
    .version = "0.0.0",
    .fingerprint = {fingerprint},
    .dependencies = .{{
        .zt = .{{ .path = "{zt_path}" }},
    }},
    .paths = .{{ "build.zig", "build.zig.zon", "src" }},
}}
''')


class ZtRunner:
    def __init__(self, workdir: Path):
        self.workdir = workdir

    def run(self, template: str, args: str = ".{}") -> str:
        # Delete generated .zig file to force regeneration (avoids timestamp precision issues)
        zig_file = self.workdir / "src/tpl.zig"
        if zig_file.exists():
            zig_file.unlink()

        # Write template
        zt_file = self.workdir / "src/tpl.zt"
        zt_file.write_text(template)

        # Write test runner
        runner = self.workdir / "src/root.zig"
        runner.write_text(f'''
const std = @import("std");
const tpl = @import("tpl.zig");

pub fn main() !void {{
    var buf: [8192]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const w = &stdout.interface;
    try tpl.run.render({args}, w);
    try w.flush();
}}
''')

        # Build and run
        env = os.environ.copy()
        env["ZIG_LOCAL_CACHE_DIR"] = str(self.workdir / ".zig-cache")
        result = subprocess.run(
            ["zig", "build", "run"],
            capture_output=True,
            text=True,
            cwd=self.workdir,
            env=env,
        )
        if result.returncode != 0:
            generated = ""
            if zig_file.exists():
                generated = f"\n\nGenerated code:\n{zig_file.read_text()}"
            raise RuntimeError(f"zig build run failed:\n{result.stderr}{generated}")

        return result.stdout


@pytest.fixture(scope="session")
def zt_workdir(tmp_path_factory):
    project_root = Path(__file__).parent.parent
    workdir = tmp_path_factory.mktemp("zt")
    setup_workdir(project_root, workdir)
    return workdir


@pytest.fixture
def zt(zt_workdir):
    return ZtRunner(zt_workdir)
