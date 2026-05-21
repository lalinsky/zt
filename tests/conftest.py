import inspect
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


GRAMMAR_DIR = Path(__file__).parent.parent / "editor" / "tree-sitter-zt"
CORPUS_FILE = GRAMMAR_DIR / "test" / "corpus" / "generated.txt"

_POS_RE = re.compile(r' \[\d+, \d+\] - \[\d+, \d+\]')


def _current_test_name() -> str:
    for frame_info in inspect.stack():
        if frame_info.function.startswith("test_"):
            return frame_info.function
    return "unknown"


def _append_corpus_entry(test_name: str, template: str, tree: str) -> None:
    CORPUS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with CORPUS_FILE.open("a") as f:
        f.write(f"{'=' * 60}\n{test_name}\n{'=' * 60}\n{template}\n---\n{tree.strip()}\n\n")


def _parse_zt(path: Path) -> str:
    """Run tree-sitter parse and return the sexp with positions stripped."""
    result = subprocess.run(
        ["npx", "--no", "tree-sitter", "parse", str(path)],
        capture_output=True,
        text=True,
        cwd=GRAMMAR_DIR,
    )
    return _POS_RE.sub("", result.stdout)


def _parse_sexp(s: str) -> list:
    tokens = re.findall(r'[()]|[^\s()]+', s)
    pos = [0]

    def parse():
        assert tokens[pos[0]] == '('
        pos[0] += 1
        name = tokens[pos[0]]
        pos[0] += 1
        result = [name]
        while tokens[pos[0]] != ')':
            if tokens[pos[0]].endswith(':'):  # skip field names like name: type:
                pos[0] += 1
                continue
            result.append(parse())
        pos[0] += 1
        return result

    return parse()


class ZtRunner:
    def __init__(self, workdir: Path):
        self.workdir = workdir

    def run(self, template: str, args: str = ".{}", expected_ast: str = None) -> str:
        # Delete generated .zig file to force regeneration (avoids timestamp precision issues)
        zig_file = self.workdir / "src/tpl.zig"
        if zig_file.exists():
            zig_file.unlink()

        # Write template
        zt_file = self.workdir / "src/tpl.zt"
        zt_file.write_text(template)

        # Validate grammar
        tree = _parse_zt(zt_file)
        has_error = any(
            l.strip().startswith("(ERROR") or "(MISSING" in l
            for l in tree.splitlines()
        )
        if expected_ast is not None:
            actual = _parse_sexp(tree)
            expected = _parse_sexp(expected_ast)
            assert actual == expected, f"AST mismatch for template:\n{template}"
            _append_corpus_entry(_current_test_name(), template, tree)
        elif has_error:
            raise AssertionError(
                f"Grammar parse error for template:\n{template}\n\n"
                f"Parse tree:\n{tree}"
            )

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


@pytest.fixture(scope="session", autouse=True)
def clear_corpus():
    if CORPUS_FILE.exists():
        CORPUS_FILE.unlink()


@pytest.fixture(scope="session")
def zt_workdir(tmp_path_factory):
    project_root = Path(__file__).parent.parent
    workdir = tmp_path_factory.mktemp("zt")
    setup_workdir(project_root, workdir)
    return workdir


@pytest.fixture
def zt(zt_workdir):
    return ZtRunner(zt_workdir)
