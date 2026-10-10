#!/usr/bin/env python3
"""Bring each pinned dependency checkout to exactly <pinned commit + patches>.

The expected tree is computed in a throwaway git index (`git apply --cached`
applies the stacked patches in order without touching the checkout), then
compared with the checkout. Only paths that differ are rewritten, so an
already-patched checkout is left untouched (no timestamp churn, no rebuild),
and a half-applied or locally edited one is repaired without a full reset.
Untracked files the patches don't create (build output, helper symlinks) are
never touched.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def git(repo: Path, *args: str, index: Path | None = None, capture: bool = True) -> str:
    env = dict(os.environ)
    if index is not None:
        env["GIT_INDEX_FILE"] = str(index)
    result = subprocess.run(["git", "-C", str(repo), *args], env=env, check=True,
                            capture_output=capture, text=True)
    return result.stdout.strip() if capture else ""


def created_paths(patch: Path) -> list[str]:
    """Paths a patch adds (`--- /dev/null`)."""
    paths, previous = [], ""
    for line in patch.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("+++ b/") and previous == "--- /dev/null":
            paths.append(line[len("+++ b/"):])
        previous = line
    return paths


def sync_dependency(repo: Path, patches: list[Path]) -> str:
    """Returns 'unchanged' or 'updated'."""
    with tempfile.TemporaryDirectory() as scratch:
        expected_index = Path(scratch) / "expected"
        current_index = Path(scratch) / "current"

        git(repo, "read-tree", "HEAD", index=expected_index)
        for patch in patches:
            git(repo, "apply", "--cached", str(patch), index=expected_index)
        expected = git(repo, "write-tree", index=expected_index)

        new_files = sorted({p for patch in patches for p in created_paths(patch)})
        git(repo, "read-tree", "HEAD", index=current_index)
        git(repo, "add", "-u", index=current_index)
        present = [p for p in new_files if (repo / p).exists()]
        if present:
            git(repo, "add", "-f", "--", *present, index=current_index)
        current = git(repo, "write-tree", index=current_index)

        if current == expected:
            return "unchanged"

        changed = git(repo, "diff", "--name-only", "--no-renames", "-z", current, expected)
        paths = [p for p in changed.split("\0") if p]
        in_expected = set(git(repo, "ls-tree", "-r", "-z", "--name-only", expected,
                              "--", *paths).split("\0")) if paths else set()
        for path in paths:
            if path not in in_expected:
                (repo / path).unlink(missing_ok=True)
        restore = [p for p in paths if p in in_expected]
        if restore:
            git(repo, "checkout-index", "-f", "--", *restore, index=expected_index, capture=False)
        return "updated"


def apply_manifest(root: Path, manifest_path: Path) -> int:
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    if data.get("schemaVersion") != 1:
        raise SystemExit("Unsupported patch manifest schema")

    for dependency in data["dependencies"]:
        name = dependency["name"]
        repo = root / dependency["repositoryPath"]
        # A submodule or worktree has a .git *file*, a clone a .git directory.
        if not (repo / ".git").exists():
            print(f"[SKIP] {name}: checkout not present at {repo}")
            continue
        commit = git(repo, "rev-parse", "HEAD")
        if commit != dependency["expectedCommit"]:
            raise SystemExit(f"{name} commit mismatch: expected {dependency['expectedCommit']}, got {commit}")

        patches = []
        for entry in dependency["patches"]:
            patch = root / entry["path"]
            if hashlib.sha256(patch.read_bytes()).hexdigest() != entry["sha256"]:
                raise SystemExit(f"Patch checksum mismatch: {entry['path']}")
            patches.append(patch)

        state = sync_dependency(repo, patches) if patches else "unchanged"
        print(f"[OK] {name}: {len(patches)} patch(es) {'already applied' if state == 'unchanged' else 'applied'}")
    return 0


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=root)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    return apply_manifest(args.root, args.manifest or args.root / "patches" / "manifest.json")


if __name__ == "__main__":
    sys.exit(main())
