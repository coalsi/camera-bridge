#!/usr/bin/env python3
"""Writes the shared test vectors of Straighten the picture (docs/superpowers/specs/2026-10-18-straighten-the-picture-design.md)."""
import json, sys
def clamp(v, lo, hi): return min(hi, max(lo, v))
def source(a, b, across, down):
    u = 2 * across - 1
    h = clamp(0.5 + a * (1 - u * u) + b * u, 0.03, 0.97)
    t = clamp(0.5 + 2 / 3 * a, 0.03, 0.97)
    fs = down * h / t if down <= t else h + (down - t) * (1 - h) / (1 - t)
    return clamp(fs, 0, 1)
settings = [(0, 0), (0.40, 0.15), (-0.40, -0.15), (0.60, 0.40), (-0.60, -0.40), (0.60, -0.40), (0, 0.40), (0.25, 0)]
points = [0, 0.001, 0.1, 0.25, 0.5, 0.75, 0.9, 0.999, 1]
vectors = [dict(straighten=a, level=b, across=x, down=y, source=round(source(a, b, x, y), 12))
           for a, b in settings for x in points for y in points]
for a, b in settings[1:]:   # the landing row itself, where the two pieces meet
    t = clamp(0.5 + 2 / 3 * a, 0.03, 0.97)
    vectors += [dict(straighten=a, level=b, across=x, down=t, source=round(source(a, b, x, t), 12)) for x in (0, 0.3, 0.5, 1)]
json.dump({"vectors": vectors}, sys.stdout, indent=1)
print()
