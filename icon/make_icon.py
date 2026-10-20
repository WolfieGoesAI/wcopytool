#!/usr/bin/env python3
"""Generate AppIcon.icns (and icon.png) for wCopyTool — no macOS tools required.
Draws an NFC/contactless-card tile and packs PNGs into an ICNS container."""
import struct, io, math, os
from PIL import Image, ImageDraw

def rounded(draw, box, r, fill):
    draw.rounded_rectangle(box, radius=r, fill=fill)

def lerp(a, b, t): return tuple(int(a[i] + (b[i]-a[i])*t) for i in range(len(a)))

def render(size):
    S = size
    img = Image.new("RGBA", (S, S), (0,0,0,0))
    d = ImageDraw.Draw(img)
    # rounded app tile with vertical gradient (indigo -> teal)
    top = (36, 46, 92); bot = (14, 120, 128)
    tile = Image.new("RGBA", (S, S), (0,0,0,0))
    td = ImageDraw.Draw(tile)
    for y in range(S):
        td.line([(0,y),(S,y)], fill=lerp(top, bot, y/max(1,S-1)))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0,0,S-1,S-1], radius=int(S*0.22), fill=255)
    img.paste(tile, (0,0), mask)
    d = ImageDraw.Draw(img)

    # contactless card: rounded rect, slightly tilted feel via lighter panel
    m = S*0.17
    card = [m, S*0.30, S-m, S*0.80]
    rounded(d, card, int(S*0.06), fill=(238, 242, 248, 255))
    rounded(d, [card[0], card[1], card[2], card[1]+ (card[3]-card[1])*0.28], int(S*0.06), fill=(70,110,170,255))
    # gold chip
    cw = S*0.14; cx = m + S*0.05; cy = S*0.46
    rounded(d, [cx, cy, cx+cw, cy+cw*0.8], int(S*0.02), fill=(214, 178, 74, 255))
    d.line([(cx+cw*0.5, cy),(cx+cw*0.5, cy+cw*0.8)], fill=(150,120,40), width=max(1,int(S*0.004)))
    d.line([(cx, cy+cw*0.4),(cx+cw, cy+cw*0.4)], fill=(150,120,40), width=max(1,int(S*0.004)))

    # contactless waves (top-right), three concentric arcs
    ox, oy = S*0.60, S*0.56
    for i, rad in enumerate([S*0.10, S*0.16, S*0.22]):
        bb = [ox-rad, oy-rad, ox+rad, oy+rad]
        d.arc(bb, start=-55, end=55, fill=(20, 130, 135, 255), width=max(2,int(S*0.022)))
    return img

def png_bytes(img):
    b = io.BytesIO(); img.save(b, format="PNG"); return b.getvalue()

def build_icns(path):
    master = render(1024)
    # (icns type, pixel size)
    types = [(b'ic07',128),(b'ic08',256),(b'ic09',512),(b'ic10',1024),
             (b'ic11',32),(b'ic12',64),(b'ic13',256),(b'ic14',512)]
    chunks = b''
    for t, sz in types:
        im = master.resize((sz, sz), Image.LANCZOS)
        data = png_bytes(im)
        chunks += t + struct.pack('>I', len(data)+8) + data
    body = b'icns' + struct.pack('>I', len(chunks)+8) + chunks
    with open(path, 'wb') as f: f.write(body)
    master.resize((512,512), Image.LANCZOS).save(os.path.join(os.path.dirname(path) or '.', 'icon.png'))

def build_iconset(dirpath):
    """Emit a standard AppIcon.iconset for `iconutil -c icns` (canonical path)."""
    os.makedirs(dirpath, exist_ok=True)
    master = render(1024)
    spec = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
    for base, scale in spec:
        px = base*scale
        name = "icon_%dx%d%s.png" % (base, base, "@2x" if scale==2 else "")
        master.resize((px, px), Image.LANCZOS).save(os.path.join(dirpath, name))

if __name__ == '__main__':
    import sys
    root = os.path.normpath(os.path.join(os.path.dirname(__file__), '..'))
    if '--iconset' in sys.argv:
        d = os.path.join(root, 'build', 'AppIcon.iconset')
        build_iconset(d); print('wrote', d)
    else:
        out = os.path.join(root, 'Resources', 'AppIcon.icns')
        os.makedirs(os.path.dirname(out), exist_ok=True)
        build_icns(out)
        print('wrote', os.path.normpath(out))
