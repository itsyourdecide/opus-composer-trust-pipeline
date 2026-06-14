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


def bootstrap(*, force: bool = False) -> Path:
    """Materialize ~/.local/share/ophar (or OPHAR_HOME) from the wheel bundle."""
    source = _wheel_bundle()
    if source is None:
        raise RuntimeError(
            "Ophar bundle not found. Use a git checkout (pip install -e .) "
            "or reinstall the ophar package."
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

    for rel in _RUNTIME_DIRS:
        (dest / rel).mkdir(parents=True, exist_ok=True)

    ledger = dest / "state" / "ledger.jsonl"
    ledger.touch(exist_ok=True)

    os.environ.setdefault("OPHAR_HOME", str(dest))
    return dest
