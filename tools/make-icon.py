#!/usr/bin/env python3
"""Génère les trois variantes d'icône d'Eudes et une planche de comparaison.

Dessin procédural : chaque icône est reproductible, sans fichier source externe.
Sortie : 1024×1024 sRGB, sans transparence, plus une planche avec les tailles réelles
utilisées par iOS (180, 120, 87, 60, 40 px).
"""
from __future__ import annotations

import os

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

RESAMPLE = getattr(Image, "Resampling", Image).LANCZOS

S = 4096
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "brand")
FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

CHARCOAL_TOP = (26, 28, 33)
CHARCOAL_BOTTOM = (11, 12, 15)
AMBER = (242, 169, 59)
TEAL = (64, 186, 170)
IVORY = (243, 240, 234)


def background(top=CHARCOAL_TOP, bottom=CHARCOAL_BOTTOM) -> Image.Image:
    ramp = np.linspace(0.0, 1.0, S)[:, None]
    top_arr = np.array(top, dtype=float)
    bottom_arr = np.array(bottom, dtype=float)
    field = top_arr + (bottom_arr - top_arr) * ramp
    rgb = np.repeat(field[:, None, :], S, axis=1)
    # vignettage doux : assombrit les coins de 12 %
    yy, xx = np.mgrid[0:S, 0:S] / (S - 1) - 0.5
    radius = np.sqrt(xx * xx + yy * yy) / 0.7071
    rgb = rgb * (1.0 - 0.12 * np.clip(radius, 0, 1) ** 2)[:, :, None]
    return Image.fromarray(rgb.clip(0, 255).astype(np.uint8), "RGB")


def glow(layer: Image.Image, radius: int, strength: float) -> Image.Image:
    blurred = layer.filter(ImageFilter.GaussianBlur(radius))
    return Image.fromarray(
        (np.array(blurred, dtype=float) * strength).clip(0, 255).astype(np.uint8), "RGBA"
    )


def e_strokes(draw: ImageDraw.ImageDraw, color, scale=1.0, cx=0.5, cy=0.5):
    """Un E géométrique : un montant et trois barres, angles arrondis."""
    def box(x0, y0, x1, y1):
        return [
            (cx + (x0 - 0.5) * scale) * S, (cy + (y0 - 0.5) * scale) * S,
            (cx + (x1 - 0.5) * scale) * S, (cy + (y1 - 0.5) * scale) * S,
        ]

    thick = 0.078
    radius = thick / 2 * S
    draw.rounded_rectangle(box(0.302, 0.278, 0.302 + thick, 0.722), radius=radius, fill=color)
    draw.rounded_rectangle(box(0.302, 0.278, 0.690, 0.278 + thick), radius=radius, fill=color)
    draw.rounded_rectangle(box(0.302, 0.461, 0.612, 0.461 + thick), radius=radius, fill=color)
    draw.rounded_rectangle(box(0.302, 0.722 - thick, 0.690, 0.722), radius=radius, fill=color)


def icon_ember() -> Image.Image:
    """Variante 1 : un E plein, ambre, sur fond charbon."""
    image = background().convert("RGBA")
    marks = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    e_strokes(ImageDraw.Draw(marks), AMBER + (255,), scale=0.96)
    halo = glow(marks, radius=70, strength=0.85)
    image = Image.alpha_composite(image, halo)
    image = Image.alpha_composite(image, marks)
    return image.convert("RGB")


def icon_bubble() -> Image.Image:
    """Variante 2 : la bulle de dialogue, E en réserve."""
    image = background().convert("RGBA")
    bubble = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw = ImageDraw.Draw(bubble)
    x0, y0, x1, y1 = 0.175 * S, 0.215 * S, 0.825 * S, 0.715 * S
    draw.rounded_rectangle((x0, y0, x1, y1), radius=0.135 * S, fill=TEAL + (255,))
    # Queue courbe : deux courbes de Bézier échantillonnées, pas une pointe anguleuse
    def bezier(points, steps=120):
        pts = []
        for step in range(steps + 1):
            t = step / steps
            left = [((1 - t) * a[0] + t * b[0], (1 - t) * a[1] + t * b[1]) for a, b in zip(points, points[1:])]
            while len(left) > 1:
                left = [((1 - t) * a[0] + t * b[0], (1 - t) * a[1] + t * b[1]) for a, b in zip(left, left[1:])]
            pts.append(left[0])
        return pts

    start = (0.300 * S, y1 - 10)
    tail = bezier([
        (0.300 * S, y1 - 10),
        (0.300 * S, 0.800 * S),
        (0.368 * S, 0.838 * S),
        (0.500 * S, y1 - 10),
    ])
    draw.polygon(tail, fill=TEAL + (255,))
    # E en réserve dans la bulle, décalé vers la droite pour compenser le poids de la queue
    knockout = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    e_strokes(ImageDraw.Draw(knockout), (13, 14, 17, 255), scale=0.52, cx=0.545, cy=0.455)
    bubble = Image.alpha_composite(bubble, knockout)
    image = Image.alpha_composite(image, glow(bubble, radius=90, strength=0.35))
    image = Image.alpha_composite(image, bubble)
    return image.convert("RGB")


def icon_halo() -> Image.Image:
    """Variante 3 : trois arcs concentriques, l'héritage lumineux de Lueur."""
    image = background().convert("RGBA")
    marks = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw = ImageDraw.Draw(marks)
    centre = S / 2
    for index, (radius, span) in enumerate(((0.150, 232), (0.268, 232))):
        half = span / 2
        start = -90 - half + index * 16
        width = int(0.068 * S)
        draw.arc([centre - radius * S, centre - radius * S, centre + radius * S, centre + radius * S],
                 start=start, end=start + span, fill=IVORY + (255,), width=width)
    draw.ellipse([centre - 0.072 * S, centre - 0.072 * S, centre + 0.072 * S, centre + 0.072 * S],
                 fill=AMBER + (255,))
    halo = ImageChops.add(glow(marks, radius=55, strength=0.55), marks)
    image = Image.alpha_composite(image, halo)
    return image.convert("RGB")


def contact_sheet(icons: dict[str, Image.Image], path: str) -> None:
    font = ImageFont.truetype(FONT_PATH, 34) if os.path.exists(FONT_PATH) else None
    small = ImageFont.truetype(FONT_PATH, 22) if os.path.exists(FONT_PATH) else None
    width, row_height = 1240, 300
    height = 70 + row_height * len(icons)
    sheet = Image.new("RGB", (width, height), (18, 19, 22))
    draw = ImageDraw.Draw(sheet)
    for row, (name, icon) in enumerate(icons.items()):
        top = 70 + row * row_height
        baseline = top + row_height // 2
        draw.text((40, top + 8), name, fill=(235, 235, 235), font=font)
        big = icon.resize((230, 230), RESAMPLE)
        sheet.paste(big, (40, top + 45))
        x = 400
        for size in (180, 120, 87, 60, 40):
            sheet.paste(icon.resize((size, size), RESAMPLE), (x, baseline - size // 2))
            draw.text((x, baseline + 100), f"{size}", fill=(150, 152, 158), font=small)
            x += size + 45
    sheet.save(path, quality=95)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    icons = {
        "1 · Braise": icon_ember(),
        "2 · Bulle": icon_bubble(),
        "3 · Halo": icon_halo(),
    }
    for index, (name, icon) in enumerate(icons.items(), 1):
        icon.resize((1024, 1024), RESAMPLE).save(os.path.join(OUT, f"variante-{index}.png"))
    contact_sheet(icons, os.path.join(OUT, "planche.png"))
    print("écrit dans", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
