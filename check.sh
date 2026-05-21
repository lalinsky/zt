#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

# Default values
CI_MODE=false
VERBOSE=false
RELEASE_MODE=false
FULL_MODE=false
TEST_FILTER=""

# Parse arguments
usage() {
  echo "Usage: $0 [--filter \"test name\"] [--ci] [--release] [--verbose] [--full]"
}
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --filter)
            [[ $# -ge 2 ]] || { echo "--filter requires an argument"; usage; exit 1; }
            TEST_FILTER="$2"; shift 2
            ;;
        --ci)
            CI_MODE=true
            shift
            ;;
        --release)
            RELEASE_MODE=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --full)
            FULL_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

echo "=== Formatting code ==="
if [ "$CI_MODE" = true ]; then
    echo "Checking formatting (CI mode)..."
    zig fmt --check .
else
    echo "Formatting code..."
    zig fmt .
fi

echo "=== Running unit tests ==="
BUILD_ARGS="test"
if [ -n "$TEST_FILTER" ]; then
    echo "Filter: $TEST_FILTER"
    BUILD_ARGS="$BUILD_ARGS -Dtest-filter=\"$TEST_FILTER\""
fi
if [ "$RELEASE_MODE" = true ]; then
    echo "Build mode: ReleaseFast"
    BUILD_ARGS="$BUILD_ARGS -Doptimize=ReleaseFast"
fi
if [ "$VERBOSE" = true ]; then
    export TEST_VERBOSE=true
fi
eval zig build $BUILD_ARGS --summary all

echo "=== Building examples ==="
(cd examples && eval zig build run > /dev/null)

if [ "$FULL_MODE" = true ]; then
    echo "=== Rebuilding tree-sitter grammar ==="
    (cd editor/tree-sitter-zt && npx --no tree-sitter generate && npx --no tree-sitter build)

    echo "=== Running integration tests ==="
    python -m pytest tests/ -v

    echo "=== Running tree-sitter tests ==="
    (cd editor/tree-sitter-zt && npx --no tree-sitter test)
fi

echo "=== All checks passed! ==="
