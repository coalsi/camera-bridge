#!/usr/bin/env python3
"""Composes the HTML/SVG sources that Tools/render_brand_assets.sh renders with headless Chrome.

Input (App/Resources/Brand): CameraBridgeLogo.svg (the primary logo: the Golden Gate seen through a camera lens, 200 x 200),
CameraBridgeLogoSmall.svg (the simplified variant for 64 px and below) and CameraBridgeMenuBarMark.svg (the single-colour
menu bar template). The older CameraBridgeOutline.svg and CameraBridgeMark.svg stay in the repo but are no longer used.
Output (into the directory given as argv[2]):
  icon_<px>.html          the macOS app icon at <px> pixels (full logo from 128 px up, the simplified one below)
  menubar_<px>.html       the menu bar template mark at <px> pixels
  brandmark.html          the in-app vector mark (rendered to PDF, so the asset stays vector)

Usage: compose_brand_assets.py <brand dir> <out dir>   (env CB_ICON=dark|red picks the tile style; default dark: the lens logo on a black tile)
"""
import math
import os
import re
import sys

brand, out = sys.argv[1], sys.argv[2]


def inner(name: str) -> str:
    """The drawing of a 200 x 200 brand SVG without its <svg> wrapper, <title> and comments."""
    text = open(f"{brand}/{name}").read()
    body = re.search(r"<svg[^>]*>(.*)</svg>", text, re.S).group(1)
    body = re.sub(r"<title.*?</title>|<!--.*?-->", "", body, flags=re.S)
    return body.strip()


LOGO, LOGO_SMALL, MENUBAR = inner("CameraBridgeLogo.svg"), inner("CameraBridgeLogoSmall.svg"), inner("CameraBridgeMenuBarMark.svg")
RED, LENS = "#9E2B20", "#151517"


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


def page(svg: str) -> str:
    return (f'<!doctype html><html><head><meta charset="utf-8"><style>html,body{{margin:0;background:transparent}}'
            f'svg{{display:block}}</style></head><body>{svg}</body></html>')


# MARK: App icon

TILE = 824          # Apple's macOS icon grid: an 824 pt tile centred in the 1024 canvas (100 pt margin for the shadow)
RADIUS = 185
STYLE = os.environ.get("CB_ICON", "dark")


def icon_svg(px: int) -> str:
    detail = px >= 128
    logo = LOGO if detail else LOGO_SMALL
    tile = squircle(TILE, RADIUS)
    if STYLE == "dark":
        # The whole logo (red ring included) on a dark tile.
        top, bottom, k = "#2A2A2D", "#1C1C1E", (0.74 if detail else 0.82) * TILE / 188
    else:
        # The logo fills a bridge-red tile: the red ring becomes the tile's own colour, the lens a black disc on it.
        top, bottom, k = "#A92F23", "#8C251B", (0.79 if detail else 0.84) * TILE / 148
        logo = re.sub(r'<circle cx="100" cy="100" r="94"[^>]*/>', "", logo)  # the ring is the tile itself
    shadow = ('<filter id="shadow" x="-10%" y="-10%" width="120%" height="130%">'
              '<feDropShadow dx="0" dy="10" stdDeviation="11" flood-color="#000" flood-opacity="0.32"/></filter>' if detail else "")
    highlight = (f'<clipPath id="clip"><path d="{tile}"/></clipPath>'
                 '<linearGradient id="hl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.22"/>'
                 '<stop offset="0.35" stop-color="#fff" stop-opacity="0.04"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>'
                 if detail else "")
    hl_stroke = f'<path d="{tile}" fill="none" stroke="url(#hl)" stroke-width="3" clip-path="url(#clip)"/>' if detail else ""
    tile_filter = ' filter="url(#shadow)"' if detail else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{px}" height="{px}" viewBox="0 0 1024 1024">'
            f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/>'
            f'<stop offset="1" stop-color="{bottom}"/></linearGradient>{shadow}{highlight}</defs>'
            f'<g transform="translate({(1024 - TILE) / 2} {(1024 - TILE) / 2})">'
            f'<path d="{tile}" fill="url(#bg)"{tile_filter}/>{hl_stroke}</g>'
            f'<g transform="translate(512 512) scale({k:.4f}) translate(-100 -100)">{logo}</g></svg>')


for px in (16, 32, 64, 128, 256, 512, 1024):
    open(f"{out}/icon_{px}.html", "w").write(page(icon_svg(px)))

# MARK: Menu bar template mark: single colour, alpha only.
for px in (18, 36, 54, 216):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{px}" height="{px}" viewBox="0 0 200 200">{MENUBAR}</svg>')
    open(f"{out}/menubar_{px}.html", "w").write(page(svg))

# MARK: In-app vector mark (PDF): the primary logo as authored, on a transparent 100 x 100 page.
brandmark = (f'<!doctype html><html><head><meta charset="utf-8"><style>@page{{size:100px 100px;margin:0}}'
             f'html,body{{margin:0;background:transparent}}svg{{display:block}}</style></head><body>'
             f'<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 200 200">{LOGO}</svg></body></html>')
open(f"{out}/brandmark.html", "w").write(brandmark)
