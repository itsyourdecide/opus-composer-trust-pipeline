"""Iteration-visible held-out pool (§9.5 `place`). Trusted-side only.

Checks the acceptance criterion (calc.f(x) == x * 10) on the SAME inputs the visible
suite would exercise. A solution that overfits to these exact inputs still passes here —
which is exactly why a separate, never-shown `reserve` pool exists for the final gate.
"""

from __future__ import annotations

from src.calc import f


def test_place_visible_inputs() -> None:
    assert f(1) == 10
    assert f(2) == 20
