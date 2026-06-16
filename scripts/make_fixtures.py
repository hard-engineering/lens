"""Synthesize §11.2 fixtures: shadow_doc.jpg and angled_doc.jpg.

Both fixtures are 2000x2800 (≈A4 ratio). The "document" is white paper with
black text. shadow_doc.jpg overlays a directional shadow gradient; angled_doc.jpg
warps the document onto a tilted quad with a textured background.

Run from repo root:
    python3 scripts/make_fixtures.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "test_inputs"
OUT.mkdir(exist_ok=True)

DOC_W, DOC_H = 1600, 2240  # A4 ratio


def _load_font(size: int) -> ImageFont.FreeTypeFont:
    candidates = [
        "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/SFNS.ttf",
    ]
    for path in candidates:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def render_document(width: int = DOC_W, height: int = DOC_H) -> Image.Image:
    doc = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(doc)
    title_font = _load_font(64)
    body_font = _load_font(40)

    margin = 130
    y = margin
    draw.text((margin, y), "Lens Test Document", font=title_font, fill="black")
    y += 110
    paragraphs = [
        "This is a synthetic fixture for the Lens iOS scanner.",
        "It exercises the binarization (B&W document filter) and",
        "perspective rectification routes described in spec §11.",
        "",
        "The document contains several lines of black text on a",
        "white background. The text below provides ample material",
        "for OCR validation:",
        "",
        "The quick brown fox jumps over the lazy dog.",
        "Pack my box with five dozen liquor jugs.",
        "Sphinx of black quartz, judge my vow.",
        "",
        "Output PDFs are validated by extracting `string` from a",
        "PDFDocument and asserting against keywords above.",
    ]
    for line in paragraphs:
        draw.text((margin, y), line, font=body_font, fill="black")
        y += 60

    # subtle texture border so edge detection has something to lock onto
    draw.rectangle([(8, 8), (width - 8, height - 8)], outline="black", width=4)
    return doc


def make_shadow(doc: Image.Image, out: Path) -> None:
    canvas_w, canvas_h = 2000, 2800
    bg = Image.new("RGB", (canvas_w, canvas_h), (230, 228, 220))
    # paste doc centered with a small offset
    pad_x = (canvas_w - doc.width) // 2
    pad_y = (canvas_h - doc.height) // 2
    bg.paste(doc, (pad_x, pad_y))

    # directional shadow gradient on the right half
    shadow = Image.new("L", (canvas_w, canvas_h), 0)
    sdraw = ImageDraw.Draw(shadow)
    for x in range(canvas_w):
        # gradient peaks at 60% darkness on the right side, 0 on the left
        if x < canvas_w * 0.45:
            alpha = 0
        else:
            t = (x - canvas_w * 0.45) / (canvas_w * 0.55)
            alpha = int(150 * t)
        sdraw.line([(x, 0), (x, canvas_h)], fill=alpha)
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=80))
    black = Image.new("RGB", (canvas_w, canvas_h), (0, 0, 0))
    bg = Image.composite(black, bg, shadow)
    bg.save(out, "JPEG", quality=92)


def make_angled(doc: Image.Image, out: Path) -> None:
    canvas_w, canvas_h = 2000, 2800
    # textured background
    bg = Image.new("RGB", (canvas_w, canvas_h), (90, 78, 64))
    noise = Image.effect_noise((canvas_w, canvas_h), 18).convert("L")
    noise_rgb = Image.merge("RGB", (noise, noise, noise))
    bg = Image.blend(bg, noise_rgb, 0.3)

    # perspective-warp the document onto an oblique quad
    src = [(0, 0), (doc.width, 0), (doc.width, doc.height), (0, doc.height)]
    dst = [(280, 380), (1760, 220), (1820, 2540), (240, 2400)]

    def find_coeffs(src_pts, dst_pts):
        import numpy as np

        A = []
        B = []
        for (xs, ys), (xd, yd) in zip(dst_pts, src_pts):
            A.append([xs, ys, 1, 0, 0, 0, -xd * xs, -xd * ys])
            A.append([0, 0, 0, xs, ys, 1, -yd * xs, -yd * ys])
            B.extend([xd, yd])
        A = np.asarray(A, dtype=np.float64)
        B = np.asarray(B, dtype=np.float64)
        res = np.linalg.solve(A, B)
        return tuple(res)

    coeffs = find_coeffs(src, dst)
    warped = doc.transform(
        (canvas_w, canvas_h),
        Image.PERSPECTIVE,
        coeffs,
        Image.BICUBIC,
        fillcolor=(0, 0, 0, 0),
    )
    # composite: only where the warped doc has content (not pure background)
    mask = Image.new("L", (canvas_w, canvas_h), 0)
    mdraw = ImageDraw.Draw(mask)
    mdraw.polygon(dst, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(radius=2))
    bg.paste(warped, (0, 0), mask)
    bg.save(out, "JPEG", quality=92)


def main() -> None:
    doc = render_document()
    make_shadow(doc, OUT / "shadow_doc.jpg")
    make_angled(doc, OUT / "angled_doc.jpg")
    print(f"wrote {OUT/'shadow_doc.jpg'}")
    print(f"wrote {OUT/'angled_doc.jpg'}")


if __name__ == "__main__":
    main()
