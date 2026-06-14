"""Reserved held-out pool (§9.5 `reserve`). Trusted-side only, NEVER mixed during the
refine loop — it is copied in only at the FINAL gate (phase=final).

Same acceptance criterion (calc.f(x) == x * 10) but on inputs the iteration pool never
touched. A solution overfit to the visible inputs (1, 2) fails here; a generally correct
solution passes. This is the clean final-acceptance measurement of §9.5.
"""

from __future__ import annotations

from src.calc import f


def test_reserve_unseen_inputs() -> None:
    for x in (3, 4, 5, 7, 11):
        assert f(x) == x * 10
