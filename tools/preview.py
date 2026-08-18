#!/usr/bin/env python3
"""Temporary Python preview server and polling rebuild loop for Varde development.

This is deliberately a development helper, not part of the Varde runtime or
CLI. It uses only the Python standard library until Odin has suitable HTTP
support for a native preview command.
"""

from __future__ import annotations

import argparse
import functools
import http.server
import os
from pathlib import Path
import subprocess
import sys
import threading
import time


WATCHED_SUFFIXES = {".odin", ".json", ".css", ".html", ".py"}
SKIPPED_DIRECTORIES = {
    ".cache",
    ".git",
    ".varde-preview",
    "__pycache__",
    "build",
    "dist",
    "docs",
    "out",
    "target",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Rebuild and serve a local Varde preview site.",
    )
    parser.add_argument("--make", default="make", help="make executable")
    parser.add_argument("--source", default=".", help="Varde source root")
    parser.add_argument("--out", default=".varde-preview/site", help="workspace-relative output directory")
    parser.add_argument("--port", type=int, default=1314, help="loopback server port")
    parser.add_argument("--bind", default="127.0.0.1", help="server bind address")
    parser.add_argument("--interval", type=float, default=0.75, help="polling interval in seconds")
    parser.add_argument("--odin-bin", default="odin", help="Odin compiler executable")
    parser.add_argument("--odin-build-flags", default="-o:speed", help="flags passed to odin build")
    return parser.parse_args()


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def snapshot(root: Path, output: Path) -> dict[str, tuple[int, int]]:
    result: dict[str, tuple[int, int]] = {}
    for current, directories, filenames in os.walk(root):
        current_path = Path(current)
        directories[:] = [
            directory
            for directory in directories
            if directory not in SKIPPED_DIRECTORIES
            and not is_within(current_path / directory, output)
        ]
        for filename in filenames:
            path = current_path / filename
            if filename == "Makefile" or path.suffix in WATCHED_SUFFIXES:
                try:
                    metadata = path.stat()
                except OSError:
                    continue
                result[str(path)] = (metadata.st_mtime_ns, metadata.st_size)
    return result


def build_site(args: argparse.Namespace) -> bool:
    command = [
        args.make,
        "preview-build",
        f"SOURCE={args.source}",
        f"PREVIEW_OUT={args.out}",
        f"ODIN_BIN={args.odin_bin}",
        f"ODIN_BUILD_FLAGS={args.odin_build_flags}",
    ]
    print("\nRebuilding preview site…", flush=True)
    return subprocess.run(command, check=False).returncode == 0


def main() -> int:
    args = parse_args()
    if args.interval <= 0:
        print("--interval must be positive", file=sys.stderr)
        return 2

    repository_root = Path(__file__).resolve().parent.parent
    source_root = Path(args.source).resolve()
    output = (source_root / args.out).resolve()
    if not source_root.is_dir():
        print(f"Source directory does not exist: {source_root}", file=sys.stderr)
        return 2
    if not build_site(args):
        return 1

    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(output))
    server = http.server.ThreadingHTTPServer((args.bind, args.port), handler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    print(f"Serving {output} at http://{args.bind}:{args.port}", flush=True)
    print("Watching source changes; press Ctrl+C to stop.", flush=True)

    roots = [repository_root]
    if source_root != repository_root:
        roots.append(source_root)
    previous = {str(root): snapshot(root, output) for root in roots}

    try:
        while True:
            time.sleep(args.interval)
            current = {str(root): snapshot(root, output) for root in roots}
            if current == previous:
                continue
            previous = current
            if build_site(args):
                print("Preview rebuilt.", flush=True)
            else:
                print("Preview rebuild failed; keeping the last successful site.", file=sys.stderr, flush=True)
    except KeyboardInterrupt:
        print("\nStopping preview server.", flush=True)
    finally:
        server.shutdown()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
