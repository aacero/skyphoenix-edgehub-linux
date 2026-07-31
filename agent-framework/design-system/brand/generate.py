#!/usr/bin/env python3
"""Generate every derived SKYPhoenix brand asset from the two vector masters.

Masters (hand-authored, never generated — the only files here you may edit by hand):
    logo/skyphoenix-logo-color.svg   full lockup: phoenix mark + "SKY PHOENIX IT" wordmark
    mark/skyphoenix-mark-color.svg   phoenix mark alone (no wordmark)

Everything else in this directory is OUTPUT. Re-run this script after changing a master;
do not edit derived files, they will be overwritten.

    python3 agent-framework/design-system/brand/generate.py

Provenance: the colour masters are the artwork shipped on skyphoenix-it.com
(www/assets/logos/{skyphoenix-logo,favicon}.svg). The brand owner supplied matching
PNG exports (colour/black/white) on 2026-07-20; those were verified against the vector
masters before this pipeline was written — identical content aspect ratio to 3 decimal
places (1.5080 vs 1.5077) and an alpha-mask difference of 1.24%, entirely edge
anti-aliasing. The vectors are therefore treated as authoritative and the mono variants
are derived from them rather than traced from the PNGs, which keeps them scalable.

Brand colours (extracted, see ../tokens/base.json):
    #231815 logo-ink     wordmark near-black
    #b92d26 logo-red     phoenix body
    #ed6d1f logo-orange  phoenix accents

Requires: rsvg-convert (librsvg) and Pillow. Both are build-time only — the generated
assets are committed, so consuming projects need neither.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

BRAND = Path(__file__).resolve().parent

LOGO_MASTER = BRAND / "logo" / "skyphoenix-logo-color.svg"
MARK_MASTER = BRAND / "mark" / "skyphoenix-mark-color.svg"

INK, RED, ORANGE = "#231815", "#b92d26", "#ed6d1f"
BRAND_HEXES = (INK, RED, ORANGE)

# Navy is the primary structural/trust colour (tokens/base.json brand.color.primary).
# Used as the opaque backdrop for icons that may not carry transparency (iOS) and for
# the social preview image.
NAVY = "#1e3a5f"

# --------------------------------------------------------------------------------------
# SVG recolouring
# --------------------------------------------------------------------------------------


def recolour(svg: str, replacement: str) -> str:
    """Replace every brand hex with one colour, producing a single-colour variant.

    Operates on the whole document rather than only the <style> block so that any
    presentation attribute (fill="#b92d26") is caught too. Case-insensitive because SVG
    hex casing is not normalised.
    """
    out = svg
    for hexval in BRAND_HEXES:
        out = re.sub(re.escape(hexval), replacement, out, flags=re.IGNORECASE)
    return out


def add_a11y_title(svg: str, title: str) -> str:
    """Insert <title> as the first child of <svg> so assistive tech has an accessible name.

    Only applied to the standalone files; when inlined the consuming page should supply
    its own accessible name and mark the graphic aria-hidden if decorative.
    """
    if "<title>" in svg:
        return svg
    return re.sub(
        r"(<svg\b[^>]*>)",
        r"\1\n  <title>" + title + "</title>",
        svg,
        count=1,
    )


def write_variants(master: Path, stem: str, label: str) -> None:
    svg = master.read_text()
    variants = {
        "black": "#000000",
        "white": "#ffffff",
        # currentColor inherits the CSS `color` property of the host element, so one
        # file themes itself in light mode, dark mode and forced-colors without any
        # JS or duplicate assets. This is the variant to prefer when inlining.
        "mono": "currentColor",
    }
    master.write_text(add_a11y_title(svg, f"SKYPhoenix IT — {label}"))
    for name, colour in variants.items():
        out = master.parent / f"{stem}-{name}.svg"
        out.write_text(add_a11y_title(recolour(svg, colour), f"SKYPhoenix IT — {label}"))
        print(f"  svg  {out.relative_to(BRAND)}")


# --------------------------------------------------------------------------------------
# Rasterisation
# --------------------------------------------------------------------------------------


def render(svg: Path, out: Path, width: int | None = None, height: int | None = None) -> Path:
    cmd = ["rsvg-convert", str(svg), "-o", str(out)]
    if width:
        cmd += ["-w", str(width)]
    if height:
        cmd += ["-h", str(height)]
    subprocess.run(cmd, check=True, capture_output=True)
    return out


def trimmed(path: Path) -> Image.Image:
    """Load a PNG cropped to its non-transparent content.

    The masters carry asymmetric padding (the logo master has ~23px of empty column on
    the left). Trimming first is what makes the centring below actually optical rather
    than nominal.
    """
    im = Image.open(path).convert("RGBA")
    bbox = im.split()[3].getbbox()
    return im.crop(bbox) if bbox else im


def square_icon(
    art: Image.Image,
    size: int,
    coverage: float,
    background: str | None = None,
) -> Image.Image:
    """Centre `art` on a square canvas, scaled so its longest side is `coverage` of it.

    coverage < 1 leaves breathing room. Platform minimums differ sharply:
      * browser favicon    ~0.90 — wants to fill the tab space
      * iOS touch icon     ~0.72 — the OS adds its own corner radius and expects margin
      * Android maskable   ~0.60 — outer 20% on every edge can be cropped by any mask
                                   shape, so all content must sit inside the safe zone
    """
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if background:
        canvas = Image.new("RGBA", (size, size), background)

    target = int(size * coverage)
    w, h = art.size
    scale = target / max(w, h)
    new = art.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
    canvas.alpha_composite(new, ((size - new.width) // 2, (size - new.height) // 2))
    return canvas


def content_bbox_units(svg: Path) -> tuple[float, float, float, float]:
    """Exact drawing bounding box in SVG user units, via Inkscape's geometry query.

    The masters are not tight to their viewBox — the mark declares 183x331.71 but draws
    only 172.4 wide starting at x=5.78. Centring on the viewBox instead of on the ink
    would leave the phoenix visibly off-centre in every square icon, which is precisely
    the defect the old 183x331 favicon had when used as a square.
    """
    out = subprocess.run(
        ["inkscape", "--query-x", "--query-y", "--query-width", "--query-height", str(svg)],
        check=True, capture_output=True, text=True,
    ).stdout.split()
    x, y, w, h = (float(v) for v in out[:4])
    return x, y, w, h


def build_favicon_svg(dest: Path) -> None:
    """Square, self-contained, theme-aware SVG favicon built from the mark master.

    Shipped in full brand colour rather than as a mono silhouette: the mark contains no
    near-black ink (only #b92d26 and #ed6d1f), so it stays legible on both light and dark
    browser chrome without needing a theme switch. The prefers-color-scheme block is
    therefore a deliberate no-op placeholder documenting that decision rather than an
    oversight — if a future mark revision introduces ink, that is where it gets handled.
    """
    svg = MARK_MASTER.read_text()
    x, y, w, h = content_bbox_units(MARK_MASTER)

    size, coverage = 512.0, 0.90
    scale = (size * coverage) / max(w, h)
    tx = (size - w * scale) / 2 - x * scale
    ty = (size - h * scale) / 2 - y * scale

    body = re.sub(r"^.*?<svg\b[^>]*>", "", svg, count=1, flags=re.S)
    body = re.sub(r"</svg>\s*$", "", body, flags=re.S)

    dest.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size:.0f} {size:.0f}" '
        f'width="{size:.0f}" height="{size:.0f}">\n'
        "  <title>SKYPhoenix IT</title>\n"
        f'  <g transform="translate({tx:.4f} {ty:.4f}) scale({scale:.6f})">'
        f"{body}</g>\n"
        "</svg>\n"
    )
    print(f"  svg  {dest.relative_to(BRAND)} (square, ink-centred)")


def main() -> int:
    for tool in ("rsvg-convert",):
        if not shutil.which(tool):
            print(f"error: {tool} not found (install librsvg)", file=sys.stderr)
            return 1
    for master in (LOGO_MASTER, MARK_MASTER):
        if not master.exists():
            print(f"error: master missing: {master}", file=sys.stderr)
            return 1

    tmp = BRAND / ".tmp"
    tmp.mkdir(exist_ok=True)

    print("vector variants")
    write_variants(LOGO_MASTER, "skyphoenix-logo", "full logo")
    write_variants(MARK_MASTER, "skyphoenix-mark", "phoenix mark")

    # ---- raster logo exports -----------------------------------------------------
    # Fixed widths rather than @1x/@2x names: consumers pick by pixel budget, and the
    # SVG remains the right answer for anything that can take it.
    #
    # Deliberately capped at 1024w. This directory is copied verbatim into every repo
    # that adopts the framework, so each tier costs disk in N repos forever; a 2084w
    # tier added ~325 KB per adopter to reproduce something the vector master already
    # contains. Need print resolution? Run this script with a wider tier locally, or
    # render the SVG directly — do not commit the output.
    print("raster logo exports")
    raster = BRAND / "raster"
    for variant in ("color", "black", "white"):
        src = LOGO_MASTER.parent / f"skyphoenix-logo-{variant}.svg"
        for width in (256, 512, 1024):
            out = raster / f"skyphoenix-logo-{variant}-{width}w.png"
            render(src, out, width=width)
        print(f"  png  skyphoenix-logo-{variant}-*.png (256/512/1024w)")

    # ---- icons -------------------------------------------------------------------
    print("icons")
    icons = BRAND / "icons"
    mark_hi = render(MARK_MASTER, tmp / "mark-color-2048.png", height=2048)
    mark_white_hi = render(
        MARK_MASTER.parent / "skyphoenix-mark-white.svg", tmp / "mark-white-2048.png", height=2048
    )
    art_color = trimmed(mark_hi)
    art_white = trimmed(mark_white_hi)

    build_favicon_svg(icons / "favicon.svg")

    # Browser favicon PNGs — transparent, tight crop.
    for size in (16, 32, 48, 64, 128, 256):
        square_icon(art_color, size, 0.90).save(icons / f"favicon-{size}.png")
    print("  png  favicon-{16,32,48,64,128,256}.png")

    # Multi-resolution .ico. Still worth shipping: some Windows surfaces, older
    # browsers and link-preview crawlers only look for /favicon.ico.
    ico_sizes = [(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    square_icon(art_color, 256, 0.90).save(icons / "favicon.ico", sizes=ico_sizes)
    print("  ico  favicon.ico (16–256, 6 sizes)")

    # apple-touch-icon: iOS ignores transparency and composites onto black, which would
    # frame the mark in a dark box on the home screen. Ship it opaque and pre-padded;
    # iOS applies its own corner radius, so none is baked in.
    square_icon(art_color, 180, 0.72, background="#ffffff").convert("RGB").save(
        icons / "apple-touch-icon-180.png"
    )
    print("  png  apple-touch-icon-180.png (opaque white, no baked corners)")

    # PWA / Android. "any" keeps transparency; "maskable" must be opaque and must keep
    # all content inside the central 80% safe zone.
    for size in (192, 512):
        square_icon(art_color, size, 0.90).save(icons / f"icon-{size}.png")
        square_icon(art_color, size, 0.60, background="#ffffff").convert("RGB").save(
            icons / f"icon-maskable-{size}.png"
        )
    print("  png  icon-{192,512}.png + icon-maskable-{192,512}.png (60% safe zone)")

    # Monochrome icon for Android themed icons / notification tinting.
    square_icon(art_white, 512, 0.60).save(icons / "icon-monochrome-512.png")
    print("  png  icon-monochrome-512.png")

    # ---- social preview ----------------------------------------------------------
    # The site currently ships no OG image (TODO at www/partials/header.php:46-47), so
    # every share renders as a bare text link. 1200x630 is the ratio both Open Graph and
    # Twitter/X summary_large_image agree on.
    og = Image.new("RGBA", (1200, 630), NAVY)
    logo_white = trimmed(render(
        LOGO_MASTER.parent / "skyphoenix-logo-white.svg", tmp / "logo-white-2048.png", width=2048
    ))
    scale = (1200 * 0.62) / logo_white.width
    placed = logo_white.resize(
        (round(logo_white.width * scale), round(logo_white.height * scale)), Image.LANCZOS
    )
    og.alpha_composite(placed, ((1200 - placed.width) // 2, (630 - placed.height) // 2))
    og.convert("RGB").save(BRAND / "social" / "og-image-1200x630.png", quality=95)
    print("  png  social/og-image-1200x630.png")

    shutil.rmtree(tmp, ignore_errors=True)
    print("\ndone.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
