"""Resolve Ophar root for editable installs, wheels, and OPHAR_HOME overrides."""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path


def user_data_root() -> Path:
    if home := os.environ.get("OPHAR_HOME"):
        return Path(home).expanduser().resolve()
    xdg = os.environ.get("XDG_DATA_HOME")
    base = Path(xdg).expanduser() if xdg else Path.home() / ".local" / "share"
    return base / "ophar"


def _repo_root() -> Path | None:
    """Editable install / git checkout: harness lives next to the ophar package."""
    repo = Path(__file__).resolve().parent.parent
    if (repo / "harness" / "orchestrate.sh").is_file():
        return repo
    return None


def _wheel_bundle() -> Path | None:
    bundled = Path(__file__).resolve().parent / "_bundle"
    if (bundled / "harness" / "orchestrate.sh").is_file():
        return bundled
    return None


def _needs_bootstrap(root: Path) -> bool:
    return not (root / "harness" / "orchestrate.sh").is_file()


@lru_cache
def get_root() -> Path:
    if repo := _repo_root():
        return repo

    from ophar.bootstrap import bootstrap

    home = user_data_root()
    if _needs_bootstrap(home):
        bootstrap()
    return home


def reset_root_cache() -> None:
    get_root.cache_clear()
