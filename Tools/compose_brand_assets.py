#!/usr/bin/env python3
"""Composes the HTML/SVG sources that Tools/render_brand_assets.sh renders with headless Chrome.

Input:  App/Resources/Brand/CameraBridgeOutline.svg (the primary logo: amber house outline, white camera, 100x100).
Output (into the directory given as argv[2]):
  icon_<px>.html          the macOS app icon at <px> pixels (one file per pixel size; heavier stroke at small sizes)
  menubar.html            the menu bar template mark (black, alpha only), 18pt at the given scale
  brandmark.html          the in-app vector mark (rendered to PDF, so the asset stays vector)
and Brand/CameraBridgeMenuBarMark.svg (the template mark as a standalone SVG, kept in the repo).

Usage: compose_brand_assets.py <brand dir> <out dir>
"""
import math
import re
import sys

brand, out = sys.argv[1], sys.argv[2]
source = open(f"{brand}/CameraBridgeOutline.svg").read()

# The mark is the <g> that holds the house outline and the camera.
mark_match = re.search(r'(<g transform="translate\(50 50\) scale\(0\.93\).*</g>)\s*</svg>', source, re.S)
assert mark_match, "CameraBridgeOutline.svg changed shape: update compose_brand_assets.py"
MARK = mark_match.group(1)
HOUSE = re.search(r'<path d="([^"]+)" fill="none"', MARK).group(1)
CAMERA = re.search(r'<path d="([^"]+)" fill="#FFFFFF"', MARK).group(1)
CAMERA_GROUP = re.search(r'<g transform="(translate\(50 55\.3\)[^"]+)">', MARK).group(1)
HOUSE_GROUP = re.search(r'<g transform="(translate\(50 50\) scale\(0\.93\)[^"]+)">', MARK).group(1)
AMBER = "#FFA700"


def squircle(size: float, radius: float, smoothing: float = 0.6) -> str:
    """A continuous-corner rounded square (the macOS icon shape): circular arcs blended into the straight edges with
    cubic Beziers (the Figma corner-smoothing construction), top-right corner rotated into the other three."""
    p = min((1 + smoothing) * radius, size / 2)
    smoothing = min(smoothing, size / 2 / radius - 1)
    arc_measure = 90 * (1 - smoothing)
    arc_len = math.sin(math.radians(arc_measure / 2)) * radius * math.sqrt(2)
    alpha = (90 - arc_measure) / 2
    p3p4 = radius * math.tan(math.radians(alpha / 2))
    beta = 45 * smoothing
    c = p3p4 * math.cos(math.radians(beta))
    d = c * math.tan(math.radians(beta))
    b = (p - arc_len - c - d) / 3
    a = 2 * b

    def corner(k: int) -> str:
        # Relative segments of the top-right corner, rotated by k * 90 degrees clockwise.
        segs = [("c", [(a, 0), (a + b, 0), (a + b + c, d)]),
                ("a", [(arc_len, arc_len)]),
                ("c", [(d, c), (d, b + c), (d, a + b + c)])]
        parts = []
        for kind, pts in segs:
            rot = []
            for x, y in pts:
                for _ in range(k):
                    x, y = -y, x
                rot.append((x, y))
            if kind == "c":
                parts.append("c " + " ".join(f"{x:.3f} {y:.3f}" for x, y in rot))
            else:
                parts.append(f"a {radius} {radius} 0 0 1 {rot[0][0]:.3f} {rot[0][1]:.3f}")
        return " ".join(parts)

    s = size
    return (f"M {s - p:.3f} 0 {corner(0)} L {s:.3f} {s - p:.3f} {corner(1)} L {p:.3f} {s:.3f} {corner(2)} "
            f"L 0 {p:.3f} {corner(3)} Z")


def mark_svg(stroke: float, camera_scale: float = 0.86) -> str:
    camera_group = CAMERA_GROUP.replace("scale(0.86)", f"scale({camera_scale})")
    return (f'<g transform="{HOUSE_GROUP}">'
            f'<path d="{HOUSE}" fill="none" stroke="{AMBER}" stroke-width="{stroke}" stroke-linejoin="round"/>'
            f'<g transform="{camera_group}"><path d="{CAMERA}" fill="#FFFFFF"/></g></g>')


def page(svg: str) -> str:
    return (f'<!doctype html><html><head><meta charset="utf-8"><style>html,body{{margin:0;background:transparent}}'
            f'svg{{display:block}}</style></head><body>{svg}</body></html>')


# MARK: App icon

TILE = 824          # Apple's macOS icon grid: an 824 pt tile centred in the 1024 canvas (100 pt margin for the shadow)
RADIUS = 185


def icon_variant(px: int) -> dict:
    """Stroke width (in mark units, 100-unit box) and mark size (fraction of the tile) for an icon of `px` pixels:
    the stroke gets relatively thicker, and the mark a little bigger, as the icon gets smaller."""
    if px <= 32:
        return dict(stroke=10.0, mark=0.72, detail=False)
    if px <= 64:
        return dict(stroke=7.5, mark=0.68, detail=False)
    if px <= 128:
        return dict(stroke=5.5, mark=0.64, detail=True)
    return dict(stroke=4.0, mark=0.62, detail=True)


def icon_svg(px: int) -> str:
    v = icon_variant(px)
    tile = squircle(TILE, RADIUS)
    # The house outline's bounding box is about 91 units wide and centred in the 100-unit box.
    k = v["mark"] * TILE / 91.2
    mark = mark_svg(v["stroke"])
    shadow = ('<filter id="shadow" x="-10%" y="-10%" width="120%" height="130%">'
              '<feDropShadow dx="0" dy="10" stdDeviation="11" flood-color="#000" flood-opacity="0.32"/></filter>'
              if v["detail"] else "")
    highlight = (f'<clipPath id="clip"><path d="{tile}"/></clipPath>'
                 '<linearGradient id="hl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.20"/>'
                 '<stop offset="0.35" stop-color="#fff" stop-opacity="0.04"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>'
                 if v["detail"] else "")
    hl_stroke = (f'<path d="{tile}" fill="none" stroke="url(#hl)" stroke-width="2" clip-path="url(#clip)"/>' if v["detail"] else "")
    tile_filter = ' filter="url(#shadow)"' if v["detail"] else ""
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{px}" height="{px}" viewBox="0 0 1024 1024">'
           f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2A2A2D"/>'
           f'<stop offset="1" stop-color="#1C1C1E"/></linearGradient>{shadow}{highlight}</defs>'
           f'<g transform="translate({(1024 - TILE) / 2} {(1024 - TILE) / 2})">'
           f'<path d="{tile}" fill="url(#bg)"{tile_filter}/>{hl_stroke}</g>'
           f'<g transform="translate(512 512) scale({k:.4f}) translate(-50 -50)">{mark}</g></svg>')
    return svg


for px in (16, 32, 64, 128, 256, 512, 1024):
    open(f"{out}/icon_{px}.html", "w").write(page(icon_svg(px)))

# MARK: Menu bar template mark: black house outline + filled camera, alpha only. A thicker stroke than the in-app mark, so
# it holds up at 18 pt (about 1.6 pt of stroke).
MB_STROKE = 9.0
menubar_inner = (f'<g transform="{HOUSE_GROUP}">'
                 f'<path d="{HOUSE}" fill="none" stroke="#000" stroke-width="{MB_STROKE}" stroke-linejoin="round"/>'
                 f'<g transform="{CAMERA_GROUP.replace("scale(0.86)", "scale(0.84)")}"><path d="{CAMERA}" fill="#000"/></g></g>')
menubar_svg = (f'<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">\n'
               f'  <!-- Derived from CameraBridgeOutline.svg by Tools/compose_brand_assets.py: house outline + filled camera, black, for template rendering -->\n'
               f'  {menubar_inner}\n</svg>\n')
open(f"{brand}/CameraBridgeMenuBarMark.svg", "w").write(menubar_svg)
for px in (18, 36, 54, 216):
    svg = menubar_svg.split("\n", 1)[1].replace('viewBox="0 0 100 100"', f'width="{px}" height="{px}" viewBox="0 0 100 100"', 1)
    open(f"{out}/menubar_{px}.html", "w").write(page(svg))

# MARK: In-app vector mark (PDF): the outline logo as authored, on a transparent 100 x 100 page.
brandmark = (f'<!doctype html><html><head><meta charset="utf-8"><style>@page{{size:100px 100px;margin:0}}'
             f'html,body{{margin:0;background:transparent}}svg{{display:block}}</style></head><body>'
             f'<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">{MARK}</svg></body></html>')
open(f"{out}/brandmark.html", "w").write(brandmark)
