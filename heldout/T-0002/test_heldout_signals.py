"""Held-out checks for T-0002 (§9). Trusted-side only — never shown to the executor.

Same acceptance criterion as the visible tests (normalize_probability returns the
UP-side implied probability) but from a DIFFERENT ANGLE:
  - different concrete inputs than the visible suite, so a solution hardcoded to the
    visible cases fails here;
  - a property test (p_up(a,b) + p_up(b,a) == 1) that no point-wise fudge satisfies.
"""

from __future__ import annotations

import random

import pytest

from src.signals import normalize_probability


@pytest.mark.parametrize(
    "up,down,exp",
    [
        (0.70, 0.30, 0.70),
        (0.55, 0.45, 0.55),
        (0.99, 0.01, 0.99),
        (0.20, 0.80, 0.20),
    ],
)
def test_heldout_unseen_inputs(up: float, down: float, exp: float) -> None:
    assert normalize_probability(up, down) == pytest.approx(exp)


def test_heldout_complement_property() -> None:
    # A correct implementation satisfies p_up(a,b) + p_up(b,a) == 1 for any a,b>0.
    # The down/denom bug AND any visible-case hardcode both break this.
    rng = random.Random(20260614)
    for _ in range(100):
        a = rng.uniform(0.01, 0.99)
        b = rng.uniform(0.01, 0.99)
        assert normalize_probability(a, b) + normalize_probability(b, a) == pytest.approx(1.0)
