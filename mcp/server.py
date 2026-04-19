#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["fastmcp>=2.0"]
# ///
import os
import subprocess
from pathlib import Path

from fastmcp import FastMCP

PROJECT_ROOT = Path(os.environ.get("REAL_PWD") or Path(__file__).resolve().parent.parent)
IOS_PROJECT = "vcdr-ios/vcdr-ios.xcodeproj"
MAX_OUTPUT = 20_000
DEFAULT_TIMEOUT = 900

mcp = FastMCP("vcdr")


def _run(args: list[str], timeout: int = DEFAULT_TIMEOUT) -> str:
    try:
        result = subprocess.run(
            args,
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        return f"exit=timeout after {timeout}s\ncmd={' '.join(args)}"

    combined = (result.stdout or "") + (result.stderr or "")
    if len(combined) > MAX_OUTPUT:
        combined = "...[truncated head]...\n" + combined[-MAX_OUTPUT:]
    return f"exit={result.returncode}\ncmd={' '.join(args)}\ncwd={PROJECT_ROOT}\n\n{combined}"


@mcp.tool
def build_mac() -> str:
    """Build the macOS app (vcdr-mac scheme, platform=macOS)."""
    return _run([
        "xcodebuild",
        "-scheme", "vcdr-mac",
        "-destination", "platform=macOS",
        "build",
    ])


@mcp.tool
def build_ios() -> str:
    """Compile-only build of the iOS app (generic iOS device, no simulator)."""
    return _run([
        "xcodebuild",
        "-project", IOS_PROJECT,
        "-scheme", "vcdr-ios",
        "-destination", "generic/platform=iOS",
        "build",
    ])


@mcp.tool
def test_mac() -> str:
    """Run the macOS test suite (vcdr-mac scheme, platform=macOS)."""
    return _run([
        "xcodebuild", "test",
        "-scheme", "vcdr-mac",
        "-destination", "platform=macOS",
        "-quiet",
    ])


if __name__ == "__main__":
    mcp.run()
