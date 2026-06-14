"""Copy bundled pipeline assets into the user data directory (wheel installs)."""

from __future__ import annotations

import os
import shutil
import stat
from pathlib import Path

from ophar.paths import _wheel_bundle, user_data_root

_BUNDLE_DIRS = ("harness", "tasks", "heldout")
_BUNDLE_FILES = (
    "CLAUDE.md",
    "AGENTS.md",
    "orchestrator-pipeline-plan.md",
    "state/STATE.md",
)
_RUNTIME_DIRS = (
    "runs",
    "state/history",
    "state/specs",
    "state/server",
    "state/server/logs",
)


def _copy_tree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def _ensure_executable_scripts(tree: Path) -> None:
    for path in tree.rglob("*.sh"):
        mode = path.stat().st_mode
        path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def ensure_runtime_dirs(root: Path) -> None:
    for rel in _RUNTIME_DIRS:
        (root / rel).mkdir(parents=True, exist_ok=True)
    (root / "state" / "ledger.jsonl").touch(exist_ok=True)


def bootstrap(*, force: bool = False) -> Path:
    """Prepare Ophar data directory: repo checkout, OPHAR_HOME, or wheel bundle copy."""
    from ophar.paths import _repo_root

    if repo := _repo_root():
        ensure_runtime_dirs(repo)
        return repo

    source = _wheel_bundle()
    if source is None:
        raise RuntimeError(
            "Ophar bundle not found. Reinstall with: pip install ophar"
        )

    dest = user_data_root()
    dest.mkdir(parents=True, exist_ok=True)

    for name in _BUNDLE_DIRS:
        src = source / name
        if not src.is_dir():
            raise RuntimeError(f"Missing bundle directory: {name}")
        target = dest / name
        if force or not target.exists():
            _copy_tree(src, target)
        _ensure_executable_scripts(dest / name)

    for rel in _BUNDLE_FILES:
        src = source / rel
        if not src.is_file():
            raise RuntimeError(f"Missing bundle file: {rel}")
        target = dest / rel
        if force or not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, target)

    ensure_runtime_dirs(dest)

    os.environ.setdefault("OPHAR_HOME", str(dest))
    return dest
