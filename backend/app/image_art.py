"""Small code-drawn representative illustrations; no external image or font dependency."""

import io
from functools import lru_cache

from PIL import Image, ImageDraw


@lru_cache(maxsize=12)
def representative_png(kind):
    image = Image.new("RGB", (256, 256), "#edf5f2")
    d = ImageDraw.Draw(image)
    dark, light = "#25766d", "#fefcf5"
    if kind == "milk":
        d.polygon([(87, 62), (163, 62), (180, 91), (180, 210), (76, 210), (76, 91)], fill=light, outline=dark, width=5)
        d.rectangle((76, 114, 180, 174), fill="#8fc9dd")
        d.line((87, 62, 100, 37, 152, 37, 163, 62), fill=dark, width=5)
    elif kind == "eggs":
        d.rounded_rectangle((35, 137, 221, 217), radius=17, fill="#c7b48d")
        for x in (42, 100, 158):
            d.ellipse((x, 65, x + 55, 163), fill=light, outline="#a9916a", width=3)
    elif kind == "produce":
        d.ellipse((50, 80, 155, 207), fill="#e97563")
        d.ellipse((108, 80, 213, 207), fill="#e97563")
        d.line((129, 94, 141, 43), fill=dark, width=9)
        d.ellipse((142, 35, 195, 63), fill="#6b9c65")
    elif kind == "bread":
        d.rounded_rectangle((44, 61, 212, 207), radius=46, fill="#dfac66", outline="#a77541", width=4)
        for x in (70, 112, 154):
            d.line((x, 96, x + 20, 145), fill=light, width=10)
    elif kind == "drink":
        d.ellipse((155, 87, 222, 161), outline=dark, width=12)
        d.rounded_rectangle((46, 73, 179, 196), radius=22, fill=light, outline=dark, width=5)
        d.ellipse((48, 69, 177, 99), fill="#765548", outline=dark, width=4)
    elif kind == "cleaning":
        d.rounded_rectangle((65, 83, 181, 218), radius=25, fill="#83c8c3", outline=dark, width=4)
        d.rectangle((105, 48, 142, 89), fill=dark)
        d.rounded_rectangle((105, 36, 187, 55), radius=8, fill=dark)
        d.ellipse((100, 127, 149, 180), fill=light)
    elif kind == "cookware":
        d.line((159, 101, 219, 40), fill=dark, width=24)
        d.ellipse((31, 74, 186, 225), fill="#45636b", outline=dark, width=6)
        d.ellipse((48, 90, 169, 207), outline="#91b8b4", width=5)
    elif kind == "electronics":
        d.arc((43, 33, 213, 208), 180, 360, fill=dark, width=18)
        for x in (36, 177):
            d.rounded_rectangle((x, 117, x + 43, 204), radius=17, fill=dark)
    elif kind == "food":
        d.ellipse((47, 88, 209, 143), fill=light, outline=dark, width=4)
        d.pieslice((47, 64, 209, 216), 0, 180, fill="#80bbb0", outline=dark, width=4)
        d.line((83, 210, 173, 210), fill=dark, width=6)
    else:
        d.rounded_rectangle((49, 63, 207, 211), radius=15, fill="#d8b98c", outline=dark, width=4)
        d.rectangle((110, 65, 146, 123), fill=light)
        d.line((81, 171, 122, 171), fill=dark, width=5)
    out = io.BytesIO()
    image.save(out, format="PNG", optimize=True)
    return out.getvalue()
