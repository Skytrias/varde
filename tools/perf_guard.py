#!/usr/bin/env python3
"""Record or verify byte-identical Varde performance outputs."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys


SCHEMA_VERSION = 1


def file_record(path: Path) -> dict[str, object]:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"size": path.stat().st_size, "sha256": digest.hexdigest()}


def site_records(root: Path) -> dict[str, dict[str, object]]:
    if not root.is_dir():
        raise ValueError(f"site directory does not exist: {root}")
    records: dict[str, dict[str, object]] = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"site contains an unsupported symlink: {path}")
        if path.is_file():
            records[path.relative_to(root).as_posix()] = file_record(path)
    return records


def snapshot(artifact: Path, site: Path) -> dict[str, object]:
    if not artifact.is_file():
        raise ValueError(f"artifact does not exist: {artifact}")
    return {
        "schema_version": SCHEMA_VERSION,
        "artifact": file_record(artifact),
        "site": site_records(site),
    }


def snapshot_digest(value: dict[str, object]) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def record(args: argparse.Namespace) -> int:
    value = snapshot(args.artifact, args.site)
    args.baseline.parent.mkdir(parents=True, exist_ok=True)
    args.baseline.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    print(
        f"recorded {len(value['site'])} site files and one artifact "
        f"with digest {snapshot_digest(value)}"
    )
    return 0


def describe_changes(
    baseline: dict[str, dict[str, object]],
    candidate: dict[str, dict[str, object]],
) -> list[str]:
    baseline_paths = set(baseline)
    candidate_paths = set(candidate)
    changes = [f"removed site file: {path}" for path in sorted(baseline_paths - candidate_paths)]
    changes.extend(f"added site file: {path}" for path in sorted(candidate_paths - baseline_paths))
    changes.extend(
        f"changed site file: {path}"
        for path in sorted(baseline_paths & candidate_paths)
        if baseline[path] != candidate[path]
    )
    return changes


def check(args: argparse.Namespace) -> int:
    baseline = json.loads(args.baseline.read_text())
    if baseline.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"unsupported baseline schema in {args.baseline}")
    candidate = snapshot(args.artifact, args.site)
    changes: list[str] = []
    if baseline.get("artifact") != candidate["artifact"]:
        changes.append("changed .odin-doc artifact")
    changes.extend(describe_changes(baseline.get("site", {}), candidate["site"]))
    if changes:
        print(f"performance output guard failed with {len(changes)} difference(s)", file=sys.stderr)
        for change in changes[:50]:
            print(f"- {change}", file=sys.stderr)
        if len(changes) > 50:
            print(f"- ... {len(changes) - 50} more", file=sys.stderr)
        return 1
    print(
        f"performance output guard passed for {len(candidate['site'])} site files "
        f"and artifact digest {snapshot_digest(candidate)}"
    )
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    for name, handler in (("record", record), ("check", check)):
        command = subparsers.add_parser(name)
        command.add_argument("--artifact", type=Path, required=True)
        command.add_argument("--site", type=Path, required=True)
        command.add_argument("--baseline", type=Path, required=True)
        command.set_defaults(handler=handler)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        return args.handler(args)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"performance output guard error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
