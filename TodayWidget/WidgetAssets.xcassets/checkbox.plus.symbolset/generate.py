"""Regenerate checkbox.plus.svg — the Add To-Do control's icon.

The icon is a custom SF Symbol rather than a drawn SwiftUI view because Control
Center renders a control's icon by flattening it to a single-colour template
mask; an arbitrary view does not survive that (a stroked box with a badge came
through as a bare checkmark, a Canvas as nothing at all), while a symbol set is
what that pipeline is built to consume.

It is generated rather than hand-authored because an SF Symbol template is a
fixed structure of three interpolation masters with exact per-slot metrics. This
script takes a stock Apple template, reads each slot's advance width and cap
band off its own guides, and substitutes a glyph fitted to them: the app's
rounded checkbox with the tick punched out (even-odd), plus a badge clear of its
corner. Editing the SVG by hand means editing 27 coordinate sets in step, so
change the numbers here and re-run instead:

    python3 generate.py    # rewrites checkbox.plus.svg in place

Requires SF Symbols.app, for the template it borrows metrics and structure from.
"""

import re, math

TEMPLATE = '/Applications/SF Symbols.app/Contents/Resources/badge.plus.svg'
src = open(TEMPLATE).read()
slots = re.findall(r'<g id="([A-Za-z]+-[SML])" transform="matrix\(([^)]*)\)">(.*?)</g>', src, re.S)

WEIGHT_STROKE = {
 "Ultralight":5.0,"Thin":6.0,"Light":7.5,"Regular":9.0,"Medium":10.5,
 "Semibold":12.0,"Bold":13.5,"Heavy":15.0,"Black":16.5,
}
# Advance width and cap-height band, read off the template's own guides. The
# glyph is fitted to these rather than to a guessed cap height — a glyph drawn
# narrower than its advance renders squashed, which is what a mismatched box did.
SLOT_ADVANCE = {"Ultralight":103.22, "Regular":107.08, "Black":111.14}
CAP_BAND = 119.34
# Leave the design box a little narrower than the advance so the symbol has the
# side bearings every other symbol has, and is not flush against its neighbours.
# The design box is scaled by the slot advance, then trimmed by this so the
# glyph sits inside the cap band rather than overrunning it — a glyph taller
# than the band is rejected at load time, which is what an untrimmed fit did.
FIT = 0.78

def rounded_rect(x, y, w, h, r, X, Y, ccw):
    """Rounded rect in glyph coords, emitted through X/Y mappers.

    `ccw` selects the arc sweep that makes corners bulge OUTWARD once the
    y-axis has been flipped into SF Symbol space.
    """
    s = 1 if ccw else 0
    return (
      f"M{X(x+r):.3f},{Y(y):.3f} "
      f"L{X(x+w-r):.3f},{Y(y):.3f} "
      f"A{abs(X(r)-X(0)):.3f},{abs(Y(r)-Y(0)):.3f} 0 0 {s} {X(x+w):.3f},{Y(y+r):.3f} "
      f"L{X(x+w):.3f},{Y(y+h-r):.3f} "
      f"A{abs(X(r)-X(0)):.3f},{abs(Y(r)-Y(0)):.3f} 0 0 {s} {X(x+w-r):.3f},{Y(y+h):.3f} "
      f"L{X(x+r):.3f},{Y(y+h):.3f} "
      f"A{abs(X(r)-X(0)):.3f},{abs(Y(r)-Y(0)):.3f} 0 0 {s} {X(x):.3f},{Y(y+h-r):.3f} "
      f"L{X(x):.3f},{Y(y+r):.3f} "
      f"A{abs(X(r)-X(0)):.3f},{abs(Y(r)-Y(0)):.3f} 0 0 {s} {X(x+r):.3f},{Y(y):.3f} Z")

def tick_outline(pts, w):
    """A stroked polyline as ONE closed outline: up one side, back the other,
    with the ends squared off. One subpath, so even-odd punches it cleanly
    instead of self-cancelling where round caps overlapped."""
    def norm(a, b):
        dx, dy = b[0]-a[0], b[1]-a[1]
        L = math.hypot(dx, dy)
        return -dy/L*w, dx/L*w
    def inter(p1, d1, p2, d2):
        # intersect p1+t*d1 with p2+u*d2
        det = d1[0]*(-d2[1]) - (-d2[0])*d1[1]
        if abs(det) < 1e-9:
            return p2
        rx, ry = p2[0]-p1[0], p2[1]-p1[1]
        t = (rx*(-d2[1]) - (-d2[0])*ry) / det
        return (p1[0]+t*d1[0], p1[1]+t*d1[1])

    left, right = [], []
    segs = list(zip(pts, pts[1:]))
    for i, (a, b) in enumerate(segs):
        nx, ny = norm(a, b)
        d = (b[0]-a[0], b[1]-a[1])
        la, lb = (a[0]+nx, a[1]+ny), (b[0]+nx, b[1]+ny)
        ra, rb = (a[0]-nx, a[1]-ny), (b[0]-nx, b[1]-ny)
        if i == 0:
            left.append(la); right.append(ra)
        else:
            # miter against the previous segment
            pa, pb = segs[i-1]
            pnx, pny = norm(pa, pb)
            pd = (pb[0]-pa[0], pb[1]-pa[1])
            left[-1] = inter((pa[0]+pnx, pa[1]+pny), pd, la, d)
            right[-1] = inter((pa[0]-pnx, pa[1]-pny), pd, ra, d)
        left.append(lb); right.append(rb)
    return left + right[::-1]

def glyph(advance, stroke):
    """The glyph, drawn in a 100-unit square and scaled to fill the slot.

    Scaled by the slot's own advance rather than by a guessed cap height: the
    design box is 100 units wide, so anything narrower than the advance renders
    the box as a tall rectangle instead of a square. Uniform on both axes, and
    anchored at the origin, which is where the template expects the glyph to
    start — offsetting it there is what made the symbol fail to load.
    """
    s = advance / 100.0 * FIT
    ASPECT = 1.15   # advance:cap correction, so the box reads square
    X = lambda v: v * s * ASPECT
    Y = lambda v: -(100.0 - v) * s     # y-down glyph space -> y-up symbol space

    parts = []
    bx, by, bw, bh = 2, 36, 64, 64
    r = bw / 19.0 * 5.0
    # ccw=True: with y flipped, this is the sweep that bulges corners outward.
    parts.append(rounded_rect(bx, by, bw, bh, r, X, Y, ccw=True))

    poly = tick_outline([(17,69),(29,82),(51,55)], stroke/2.0)
    parts.append("M" + " L".join(f"{X(px):.3f},{Y(py):.3f}" for px,py in poly) + " Z")

    arm, th = 30.0, stroke
    cx, cy = 79.0, 19.0
    half, stem = arm/2.0, th/2.0
    c = [(cx-stem,cy-half),(cx+stem,cy-half),(cx+stem,cy-stem),(cx+half,cy-stem),
         (cx+half,cy+stem),(cx+stem,cy+stem),(cx+stem,cy+half),(cx-stem,cy+half),
         (cx-stem,cy+stem),(cx-half,cy+stem),(cx-half,cy-stem),(cx-stem,cy-stem)]
    parts.append("M" + " L".join(f"{X(px):.3f},{Y(py):.3f}" for px,py in c) + " Z")
    return " ".join(parts)

out = src
for name, matrix, body in slots:
    weight, scale = name.rsplit("-", 1)
    d = glyph(SLOT_ADVANCE[weight], WEIGHT_STROKE[weight])
    new_body = ('\n   <path class="monochrome-1 multicolor-1:systemGreenColor '
                'hierarchical-1:primary SFSymbolsPreview28CD41" fill-rule="evenodd" '
                f'd="{d}"/>\n  ')
    old = f'<g id="{name}" transform="matrix({matrix})">{body}</g>'
    out = out.replace(old, f'<g id="{name}" transform="matrix({matrix})">{new_body}</g>')

open('checkbox.plus.svg','w').write(out)
print('wrote checkbox.plus.svg')
