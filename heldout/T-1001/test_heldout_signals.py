"""Held-out checks for T-1001 (§9). Trusted-side only — never shown to the executor.

Same acceptance criterion as the visible tests (median(numbers) = middle element for
odd-length, average of the two middle elements for even-length) but from a DIFFERENT
ANGLE so a solution overfit to the visible cases is caught:
  - random/unseen inputs instead of the fixed visible lists;
  - order-invariance (median ignores input order);
  - the even-length defining property 2*median == sum of the two middle sorted values;
  - the bounding property min <= median <= max.
The original lower-middle bug AND any hardcode to the visible cases break these.
"""

from __future__ import annotations

import random

import pytest

from src.stats import median


def test_heldout_two_element_average() -> None:
    rng = random.Random(20260614)
    for _ in range(100):
        a = rng.uniform(-1000, 1000)
        b = rng.uniform(-1000, 1000)
        assert median([a, b]) == pytest.approx((a + b) / 2)


def test_heldout_order_invariant() -> None:
    rng = random.Random(777)
    for _ in range(100):
        xs = [rng.uniform(-50, 50) for _ in range(rng.randint(1, 8))]
        shuffled = xs[:]
        rng.shuffle(shuffled)
        assert median(xs) == pytest.approx(median(shuffled))


def test_heldout_even_defining_property() -> None:
    # For an even-length list the median must be the average of the two middle
    # sorted values: 2*median == ordered[mid-1] + ordered[mid].
    rng = random.Random(4242)
    for _ in range(100):
        n = rng.randrange(2, 12, 2)  # even length only
        xs = [rng.uniform(-100, 100) for _ in range(n)]
        ordered = sorted(xs)
        mid = n // 2
        assert 2 * median(xs) == pytest.approx(ordered[mid - 1] + ordered[mid])


def test_heldout_within_bounds() -> None:
    rng = random.Random(9001)
    for _ in range(100):
        xs = [rng.uniform(-100, 100) for _ in range(rng.randint(1, 10))]
        assert min(xs) <= median(xs) <= max(xs)
