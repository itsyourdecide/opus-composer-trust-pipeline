"""Minimal setup hook: bundle harness assets into the installed ophar package."""

from __future__ import annotations

import shutil
from pathlib import Path

from setuptools import setup
from setuptools.command.build_py import build_py as _build_py

REPO_ROOT = Path(__file__).resolve().parent
BUNDLE_DIRS = ("harness", "tasks", "heldout")
BUNDLE_FILES = (
    "CLAUDE.md",
    "AGENTS.md",
    "orchestrator-pipeline-plan.md",
    "state/STATE.md",
)


class build_py(_build_py):
    def run(self) -> None:
        super().run()
        bundle_dest = Path(self.build_lib) / "ophar" / "_bundle"
        bundle_dest.mkdir(parents=True, exist_ok=True)

        for name in BUNDLE_DIRS:
            src = REPO_ROOT / name
            dst = bundle_dest / name
            if not src.is_dir():
                raise FileNotFoundError(f"Bundle source missing: {src}")
            if dst.exists():
                shutil.rmtree(dst)
            shutil.copytree(src, dst)

        for rel in BUNDLE_FILES:
            src = REPO_ROOT / rel
            dst = bundle_dest / rel
            if not src.is_file():
                raise FileNotFoundError(f"Bundle source missing: {src}")
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)


setup(cmdclass={"build_py": build_py})
