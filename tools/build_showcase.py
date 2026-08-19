#!/usr/bin/env python3
"""Build the GitHub Pages Varde documentation showcase.

This is deliberately deployment orchestration, not part of Varde's runtime.
Each catalog entry is rendered as its own self-contained Varde site, then the
catalog links to that site under one Pages artifact.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "showcase" / "catalog"


@dataclass(frozen=True)
class Repository:
    slug: str
    url: str
    commit: str


# Pin showcase inputs. Updating an entry is an explicit content change rather
# than an unreviewed change to the published reference site.
ODIN = Repository(
    "odin",
    "https://github.com/odin-lang/Odin.git",
    "819fdc7a80667498b8b365999f1475a66c358640",
)
KARL2D = Repository(
    "karl2d",
    "https://github.com/karl-zylinski/karl2d.git",
    "9455eefd29f04c65869497dc89755d7897d5a66b",
)
MUNINN = Repository(
    "muninn",
    "https://github.com/GuilHartt/muninn.git",
    "7f11f779b54f8cfa8a78b7f2a01abc374e249af5",
)
SOKOL_ODIN = Repository(
    "sokol-odin",
    "https://github.com/floooh/sokol-odin.git",
    "2b504f453c8ab0c0d1cd746ba6eace08e5ad9bac",
)
VARDE_REPOSITORY_URL = "https://github.com/Skytrias/varde.git"


def run(command: list[str], *, cwd: Path | None = None) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def clone_at(repo: Repository, destination: Path) -> Path:
    """Fetch just the reviewed commit; never follow a repository's moving tip."""
    run(["git", "init", "--quiet", str(destination)])
    run(["git", "-C", str(destination), "remote", "add", "origin", repo.url])
    run(["git", "-C", str(destination), "fetch", "--depth", "1", "origin", repo.commit])
    run(["git", "-C", str(destination), "checkout", "--quiet", "--detach", "FETCH_HEAD"])
    actual = subprocess.check_output(
        ["git", "-C", str(destination), "rev-parse", "HEAD"], text=True
    ).strip()
    if actual != repo.commit:
        raise RuntimeError(f"{repo.slug}: expected {repo.commit}, got {actual}")
    return destination


def checked_out_commit(workspace: Path) -> str:
    return subprocess.check_output(["git", "-C", str(workspace), "rev-parse", "HEAD"], text=True).strip()


def blob_prefix(repo: Repository) -> str:
    return f"{repo.url.removesuffix('.git')}/blob/{repo.commit}"


def build_source_site(varde: Path, workspace: Path, destination: Path) -> None:
    """Build one showcase entry exclusively through Varde source mode."""
    relative_output = ".varde-showcase"
    generated = workspace / relative_output
    if generated.exists():
        raise RuntimeError(f"refusing to replace existing generated site: {generated}")
    # The public showcase intentionally demonstrates Varde's compiler-free,
    # incomplete source path. It must not invoke `odin doc` or depend on a
    # project's native build prerequisites.
    command = [str(varde), "build", "--source", ".", "--allow-incomplete", "--out", relative_output]
    run(command, cwd=workspace)
    shutil.copytree(generated, destination)


def configure_site(workspace: Path, name: str, repo: Repository, *, workspace_packages_only: bool = False) -> None:
    config_path = workspace / "varde.json"
    if config_path.exists():
        raise RuntimeError(f"refusing to replace project configuration: {config_path}")
    title = f"{name[:1].upper()}{name[1:]} Documentation"
    config_path.write_text(json.dumps({
        "schema_version": 5,
        "title": title,
        "workspace_packages_only": workspace_packages_only,
        "include_source_links": True,
        "source_url_prefix": blob_prefix(repo),
    }) + "\n", encoding="utf-8")


def build_odin(varde: Path, source: Path, destination: Path) -> None:
    configure_site(source, "odin", ODIN)
    build_source_site(varde, source, destination)


def build_varde(varde: Path, workspace: Path, destination: Path, repository: Repository) -> None:
    """Build from a disposable copy so running the helper never touches the checkout."""
    shutil.copytree(
        ROOT,
        workspace,
        ignore=shutil.ignore_patterns(".git", ".varde-*", "dist", "docs", "__pycache__", ".DS_Store"),
    )
    configure_site(workspace, "varde", repository)
    build_source_site(varde, workspace, destination)


def build_karl2d(varde: Path, source: Path, destination: Path) -> None:
    configure_site(source, "karl2d", KARL2D, workspace_packages_only=True)
    build_source_site(varde, source, destination)


def build_muninn(varde: Path, source: Path, destination: Path) -> None:
    configure_site(source, "muninn", MUNINN, workspace_packages_only=True)
    build_source_site(varde, source, destination)


def build_sokol_odin(varde: Path, source: Path, destination: Path) -> None:
    configure_site(source, "sokol-odin", SOKOL_ODIN, workspace_packages_only=True)
    build_source_site(varde, source, destination)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--varde", type=Path, help="Path to the built Varde executable")
    parser.add_argument("--output", required=True, type=Path, help="Pages artifact directory")
    parser.add_argument(
        "--catalog-only",
        action="store_true",
        help="Refresh catalog assets in an existing complete artifact without rebuilding project sites",
    )
    args = parser.parse_args()

    output = args.output.resolve()
    if not CATALOG.is_dir():
        parser.error(f"catalog assets are missing: {CATALOG}")

    if args.catalog_only:
        if not output.is_dir():
            parser.error("--catalog-only requires an existing showcase output directory")
        required = [
            output / "projects" / project / "index.html"
            for project in ("varde", "odin", "karl2d", "muninn", "sokol-odin")
        ]
        missing = [str(path) for path in required if not path.is_file()]
        if missing:
            raise RuntimeError(
                "catalog-only refresh requires a complete existing showcase: "
                + ", ".join(missing)
            )
        shutil.copytree(CATALOG, output, dirs_exist_ok=True)
        print(f"Refreshed Varde showcase catalog at {output}")
        return 0

    if args.varde is None:
        parser.error("--varde is required unless --catalog-only is used")
    varde = args.varde.resolve()
    if not varde.is_file():
        parser.error(f"Varde executable does not exist: {varde}")
    if output.exists():
        parser.error(f"output directory already exists: {output}")

    varde_repository = Repository("varde", VARDE_REPOSITORY_URL, checked_out_commit(ROOT))

    output.mkdir(parents=True)
    shutil.copytree(CATALOG, output, dirs_exist_ok=True)
    projects = output / "projects"
    projects.mkdir()

    with tempfile.TemporaryDirectory(prefix="varde-showcase-") as temporary:
        work = Path(temporary)

        build_varde(varde, work / "varde", projects / "varde", varde_repository)
        odin_source = clone_at(ODIN, work / ODIN.slug)
        build_odin(varde, odin_source, projects / ODIN.slug)
        build_karl2d(varde, clone_at(KARL2D, work / KARL2D.slug), projects / KARL2D.slug)
        build_muninn(varde, clone_at(MUNINN, work / MUNINN.slug), projects / MUNINN.slug)
        build_sokol_odin(varde, clone_at(SOKOL_ODIN, work / SOKOL_ODIN.slug), projects / SOKOL_ODIN.slug)

    required = [output / "index.html"] + [projects / project / "index.html" for project in ("varde", "odin", "karl2d", "muninn", "sokol-odin")]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise RuntimeError(f"showcase output is incomplete: {', '.join(missing)}")
    print(f"Built Varde showcase at {output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"showcase build failed: {error}", file=sys.stderr)
        raise SystemExit(1)
