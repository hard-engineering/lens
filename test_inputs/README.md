# Test inputs

Place two fixture images here for spec §11 visual verification:

- `shadow_doc.jpg` — a photo of a printed document with directional lighting
  creating a visible shadow band across part of the page. Resolution ≥ 1500px
  on the short side.
- `angled_doc.jpg` — a document photographed at an oblique angle (~30° tilt) so
  the document quad is visibly non-rectangular.

If real photos aren't available, synthesize them:

1. Take any public-domain document image (e.g. Project Gutenberg text rendered
   to an image, a Wikimedia Commons scan).
2. For `shadow_doc.jpg`: composite a black→transparent linear gradient over one
   half of the page in any image editor.
3. For `angled_doc.jpg`: apply a perspective transform that tilts the document.

Load them into the booted simulator's Photos library with:

```
xcrun simctl addmedia booted test_inputs/shadow_doc.jpg test_inputs/angled_doc.jpg
```

The fixtures are gitignored by default (`*.jpg` below) — add them locally only.
