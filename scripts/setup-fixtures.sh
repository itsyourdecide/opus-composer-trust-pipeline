#!/usr/bin/env bash
#
# setup-fixtures.sh — materialize the two toy target repositories the gate suite
# dispatches against. They are deliberately NOT committed (each is its own git repo,
# and the harness does git-worktree surgery on them), so a fresh clone regenerates
# them here. Idempotent: re-running rebuilds them from scratch.
#
#   sandbox/     — a tiny Node project with a bug in multiply()
#   sandbox-py/  — a tiny Python project with a bug in normalize_probability()
#
# Each is seeded buggy on `master`; the gates verify that Composer's accepted fix
# lands on a branch without ever mutating master.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

seed_repo() {  # <dir>
  local dir="$ROOT/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "fixture@local"
  git -C "$dir" config user.name "Fixture"
}

commit_repo() {  # <dir> <msg>
  local dir="$ROOT/$1"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "$2"
  # Normalize the default branch name to 'master' (the gates reference it).
  git -C "$dir" branch -M master
}

# ── sandbox/ (Node) ───────────────────────────────────────────────────────────
seed_repo sandbox
mkdir -p "$ROOT/sandbox/src" "$ROOT/sandbox/test"

cat > "$ROOT/sandbox/package.json" <<'EOF'
{
  "name": "sandbox",
  "version": "0.0.0",
  "private": true,
  "scripts": {
    "test": "node test/math.test.js"
  }
}
EOF

cat > "$ROOT/sandbox/src/math.js" <<'EOF'
function add(a, b) {
  return a + b;
}

function multiply(a, b) {
  return a + b; // BUG: should be a * b
}

module.exports = { add, multiply };
EOF

cat > "$ROOT/sandbox/test/math.test.js" <<'EOF'
const assert = require('node:assert');
const { add, multiply } = require('../src/math');

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log('ok - ' + name);
  } catch (e) {
    failures++;
    console.error('FAIL - ' + name + ': ' + e.message);
  }
}

check('add', () => assert.strictEqual(add(2, 3), 5));
check('multiply', () => assert.strictEqual(multiply(3, 4), 12));

if (failures > 0) {
  console.error(failures + ' test(s) failed');
  process.exit(1);
}
console.log('all passed');
EOF

commit_repo sandbox "Initial: arithmetic helpers (multiply has a bug)"

# ── sandbox-py/ (Python) ──────────────────────────────────────────────────────
seed_repo sandbox-py
mkdir -p "$ROOT/sandbox-py/src" "$ROOT/sandbox-py/tests"
: > "$ROOT/sandbox-py/src/__init__.py"
: > "$ROOT/sandbox-py/tests/__init__.py"

cat > "$ROOT/sandbox-py/pytest.ini" <<'EOF'
[pytest]
pythonpath = .
EOF

cat > "$ROOT/sandbox-py/src/signals.py" <<'EOF'
"""Binary market signal helpers."""

from __future__ import annotations


def normalize_probability(up_price: float, down_price: float) -> float | None:
    """UP-side probability from binary market ask prices.

    In a binary market the two sides must resolve to 1 together, so the
    implied probability of the UP side is its ask price divided by the sum
    of both ask prices.

    Returns None if the denominator is zero or negative.
    """
    denom = up_price + down_price
    if denom <= 0:
        return None
    return down_price / denom  # BUG: should be up_price / denom


def spread(bid: float, ask: float) -> float:
    """Bid-ask spread."""
    return ask - bid


def mid(bid: float, ask: float) -> float:
    """Mid price."""
    return (bid + ask) / 2.0
EOF

cat > "$ROOT/sandbox-py/tests/test_signals.py" <<'EOF'
"""Tests for signal helpers."""

from __future__ import annotations

import pytest

from src.signals import mid, normalize_probability, spread


def test_normalize_probability_basic() -> None:
    # UP=0.61, DOWN=0.39 -> p_up = 0.61 / 1.00 = 0.61
    result = normalize_probability(0.61, 0.39)
    assert result == pytest.approx(0.61)


def test_normalize_probability_equal_prices() -> None:
    # 50/50 market
    assert normalize_probability(0.50, 0.50) == pytest.approx(0.50)


def test_normalize_probability_high_confidence() -> None:
    # UP strongly favoured: 0.85 / (0.85 + 0.15) = 0.85
    assert normalize_probability(0.85, 0.15) == pytest.approx(0.85)


def test_normalize_probability_returns_none_for_zero() -> None:
    assert normalize_probability(0.0, 0.0) is None


def test_spread_and_mid() -> None:
    assert spread(0.59, 0.61) == pytest.approx(0.02)
    assert mid(0.59, 0.61) == pytest.approx(0.60)
EOF

commit_repo sandbox-py "Initial: binary market signal helpers (normalize_probability has a bug)"

echo "Fixtures ready:"
echo "  sandbox/     @ $(git -C "$ROOT/sandbox" rev-parse --short HEAD) [master]"
echo "  sandbox-py/  @ $(git -C "$ROOT/sandbox-py" rev-parse --short HEAD) [master]"
