#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Pixel comparison for the PDSH Android screenshot baselines.

This tool implements the *stated* threshold, not a vibe:

  * a pixel differs when ANY RGBA channel differs by more than
    ``CHANNEL_DELTA`` (default 2/255);
  * an image fails when the differing pixels exceed ``MAX_DIFF_RATIO``
    (default 0.1 %) of all pixels;
  * a size mismatch is always a failure (the fixed capture conditions or the
    layout size changed, so the images are not comparable at all).

Why those numbers is documented in ``android/lib/src/androidTest/README.md``
and in the report. Short version: PNG is lossless and two captures on the same
emulator were byte-identical (0 differing pixels over 11 images), so the delta
tolerance is defensive headroom against rasterizer dithering, not a licence to
drift. 2/255 is below the smallest gap between any two declared colour tokens in
``spec/ui/v1/tokens.json``; a token edit therefore always registers. 0.1 % is
~298 px on the smallest frame (945x315) and ~2592 px on a full page
(1080x2400): one moved glyph or one shifted 1 px card border exceeds it.

Usage:
    python3 android/tools/test_screenshot_compare.py compare \
        --baseline android/lib/src/test/resources/screenshots \
        --actual android/build/screenshots-work/fs-1.0
    python3 android/tools/test_screenshot_compare.py ink --image probe.png

The module also exposes the comparison functions so pytest can unit-test the
threshold itself (the ``test_*`` functions at the bottom).
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import zlib

# ---------------------------------------------------------------------------
# The stated threshold
# ---------------------------------------------------------------------------

#: A pixel counts as different only when a channel moves by more than this.
CHANNEL_DELTA = 2

#: Differing pixels above this fraction of the image fail the comparison.
MAX_DIFF_RATIO = 0.001

#: A channel below this value counts as ink for the font-scale probe.
INK_THRESHOLD = 240

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class PngError(Exception):
    """The file is not an 8-bit, non-interlaced PNG this tool can read."""


class Image:
    """A decoded RGBA image: width, height and a flat bytes buffer."""

    __slots__ = ("width", "height", "rgba")

    def __init__(self, width: int, height: int, rgba: bytes) -> None:
        self.width = width
        self.height = height
        self.rgba = rgba

    @property
    def pixels(self) -> int:
        return self.width * self.height

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"Image({self.width}x{self.height})"


# ---------------------------------------------------------------------------
# Decoding
# ---------------------------------------------------------------------------


def _decode_with_pil(path: str):
    """Return an Image through Pillow, or None when Pillow is unavailable."""
    try:
        from PIL import Image as PilImage  # type: ignore
    except Exception:
        return None
    with PilImage.open(path) as src:
        src.load()
        rgba = src.convert("RGBA")
        return Image(rgba.width, rgba.height, rgba.tobytes())


def read_png(path: str) -> Image:
    """Decodes a PNG to RGBA.

    Pillow is used when present because it is C-fast and handles every valid
    PNG; the pure-stdlib decoder below exists so the gate still runs on a host
    that has no third-party packages (it is slower but exact).
    """
    image = _decode_with_pil(path)
    if image is not None:
        return image
    return _read_png_stdlib(path)


def _read_png_stdlib(path: str) -> Image:
    with open(path, "rb") as handle:
        data = handle.read()
    if not data.startswith(PNG_SIGNATURE):
        raise PngError(f"{path}: not a PNG")
    pos = len(PNG_SIGNATURE)
    width = height = depth = color_type = interlace = None
    idat = bytearray()
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        chunk_type = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if chunk_type == b"IHDR":
            width, height, depth, color_type, _comp, _filt, interlace = struct.unpack(
                ">IIBBBBB", chunk
            )
        elif chunk_type == b"IDAT":
            idat += chunk
        elif chunk_type == b"IEND":
            break
    if None in (width, height, depth, color_type):
        raise PngError(f"{path}: missing IHDR")
    if depth != 8 or color_type not in (2, 6) or interlace != 0:
        raise PngError(
            f"{path}: unsupported PNG (depth={depth}, colour type={color_type}, "
            f"interlace={interlace}); install Pillow or re-encode as 8-bit RGBA"
        )
    channels = 3 if color_type == 2 else 4
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    expected = height * (stride + 1)
    if len(raw) != expected:
        raise PngError(f"{path}: IDAT is {len(raw)} bytes, expected {expected}")

    out = bytearray(height * stride)
    previous = bytearray(stride)
    src = 0
    for row in range(height):
        filter_type = raw[src]
        src += 1
        line = bytearray(raw[src : src + stride])
        src += stride
        if filter_type == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                up = previous[i]
                upleft = previous[i - channels] if i >= channels else 0
                estimate = left + up - upleft
                pa = abs(estimate - left)
                pb = abs(estimate - up)
                pc = abs(estimate - upleft)
                predictor = left if (pa <= pb and pa <= pc) else (up if pb <= pc else upleft)
                line[i] = (line[i] + predictor) & 0xFF
        elif filter_type != 0:
            raise PngError(f"{path}: unknown filter type {filter_type}")

        out[row * stride : (row + 1) * stride] = line
        previous = line

    if channels == 3:
        rgba = bytearray(width * height * 4)
        rgba[0::4] = out[0::3]
        rgba[1::4] = out[1::3]
        rgba[2::4] = out[2::3]
        rgba[3::4] = b"\xff" * (width * height)
        out = rgba
    return Image(width, height, bytes(out))


# ---------------------------------------------------------------------------
# Encoding (diff images and the unit tests' fixtures)
# ---------------------------------------------------------------------------


def write_png_rgba(path: str, image: Image) -> None:
    """Writes an 8-bit RGBA PNG with filter 0 (small and dependency-free)."""
    stride = image.width * 4
    raw = bytearray()
    for row in range(image.height):
        raw.append(0)
        raw += image.rgba[row * stride : (row + 1) * stride]

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", image.width, image.height, 8, 6, 0, 0, 0)
    with open(path, "wb") as handle:
        handle.write(PNG_SIGNATURE)
        handle.write(chunk(b"IHDR", ihdr))
        handle.write(chunk(b"IDAT", zlib.compress(bytes(raw), 6)))
        handle.write(chunk(b"IEND", b""))


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------


class CompareResult:
    """Outcome for one image pair."""

    __slots__ = ("name", "ok", "reason", "diff_pixels", "ratio", "width", "height")

    def __init__(self, name, ok, reason, diff_pixels, ratio, width, height):
        self.name = name
        self.ok = ok
        self.reason = reason
        self.diff_pixels = diff_pixels
        self.ratio = ratio
        self.width = width
        self.height = height

    def line(self, limit_ratio: float) -> str:
        if self.reason == "size":
            return (
                f"FAIL {self.name:<34s} size mismatch "
                f"{self.width}x{self.height} vs baseline (fixed conditions changed)"
            )
        verdict = "OK  " if self.ok else "FAIL"
        return (
            f"{verdict} {self.name:<34s} {self.diff_pixels:7d} diff px "
            f"({self.ratio * 100:.4f}% / limit {limit_ratio * 100:.4f}%)"
        )


def diff_images(
    baseline: Image,
    actual: Image,
    channel_delta: int = CHANNEL_DELTA,
) -> tuple[int, bytes]:
    """Returns (differing pixels, one-byte-per-pixel mask).

    A pixel is different when any of its four channels differs by more than
    ``channel_delta``. Alpha is included: a newly transparent fill is a visual
    regression even when the RGB values happen to match.
    """
    if (baseline.width, baseline.height) != (actual.width, actual.height):
        raise ValueError("diff_images requires equal sizes")
    total = baseline.pixels
    mask = bytearray(total)
    left = baseline.rgba
    right = actual.rgba
    delta = channel_delta
    count = 0
    for index in range(total):
        offset = index * 4
        if (
            abs(left[offset] - right[offset]) > delta
            or abs(left[offset + 1] - right[offset + 1]) > delta
            or abs(left[offset + 2] - right[offset + 2]) > delta
            or abs(left[offset + 3] - right[offset + 3]) > delta
        ):
            mask[index] = 1
            count += 1
    return count, bytes(mask)


def diff_with_pil(
    baseline_path: str,
    actual_path: str,
    channel_delta: int = CHANNEL_DELTA,
):
    """Fast path: the same rule (any channel > delta) computed by Pillow.

    Returns ``(count, mask_bytes)`` or ``None`` when Pillow is unavailable.
    """
    try:
        from PIL import Image as PilImage, ImageChops  # type: ignore
    except Exception:
        return None
    with PilImage.open(baseline_path) as baseline_src:
        baseline = baseline_src.convert("RGBA")
    with PilImage.open(actual_path) as actual_src:
        actual = actual_src.convert("RGBA")
    if baseline.size != actual.size:
        raise ValueError("diff_with_pil requires equal sizes")
    difference = ImageChops.difference(baseline, actual)
    thresholded = [
        band.point(lambda value: 255 if value > channel_delta else 0)
        for band in difference.split()
    ]
    mask_image = ImageChops.lighter(
        ImageChops.lighter(thresholded[0], thresholded[1]),
        ImageChops.lighter(thresholded[2], thresholded[3]),
    )
    histogram = mask_image.histogram()
    count = histogram[255]
    if count == 0:
        return 0, bytes(baseline.width * baseline.height)
    return count, bytes(255 if value else 0 for value in mask_image.tobytes())


def compare_image(
    baseline_path: str,
    actual_path: str,
    channel_delta: int = CHANNEL_DELTA,
    max_diff_ratio: float = MAX_DIFF_RATIO,
) -> tuple[CompareResult, bytes | None]:
    """Compares one pair and returns (result, mask or None)."""
    name = os.path.basename(actual_path)
    baseline = read_png(baseline_path)
    actual = read_png(actual_path)
    if (baseline.width, baseline.height) != (actual.width, actual.height):
        return (
            CompareResult(
                name,
                False,
                "size",
                0,
                0.0,
                actual.width,
                actual.height,
            ),
            None,
        )
    fast = diff_with_pil(baseline_path, actual_path, channel_delta)
    if fast is not None:
        count, mask = fast
        # No diff: keep the mask None instead of expanding a full-size zero mask.
        mask = None if count == 0 else bytes(1 if value else 0 for value in mask)
    else:
        count, mask = diff_images(baseline, actual, channel_delta)
    ratio = count / baseline.pixels if baseline.pixels else 0.0
    result = CompareResult(
        name=name,
        ok=ratio <= max_diff_ratio,
        reason="pixels",
        diff_pixels=count,
        ratio=ratio,
        width=baseline.width,
        height=baseline.height,
    )
    return result, mask


def compare_directories(
    baseline_dir: str,
    actual_dir: str,
    channel_delta: int = CHANNEL_DELTA,
    max_diff_ratio: float = MAX_DIFF_RATIO,
    diff_dir: str | None = None,
) -> tuple[list[CompareResult], list[str]]:
    """Compares every baseline PNG against the actual capture set.

    Returns (results, errors). Missing or extra captures are errors: a
    disappeared baseline must not silently shrink the gate.
    """
    errors: list[str] = []
    baseline_names = sorted(
        name for name in os.listdir(baseline_dir) if name.endswith(".png")
    )
    actual_names = sorted(
        name for name in os.listdir(actual_dir) if name.endswith(".png")
    )
    if not baseline_names:
        errors.append(f"no baseline PNGs in {baseline_dir}")
    missing = [name for name in baseline_names if name not in actual_names]
    extra = [name for name in actual_names if name not in baseline_names]
    for name in missing:
        errors.append(f"missing capture: {name} (the test did not write it)")
    for name in extra:
        errors.append(f"extra capture: {name} (no baseline; update baselines if intended)")

    results: list[CompareResult] = []
    for name in baseline_names:
        if name not in actual_names:
            continue
        result, mask = compare_image(
            os.path.join(baseline_dir, name),
            os.path.join(actual_dir, name),
            channel_delta=channel_delta,
            max_diff_ratio=max_diff_ratio,
        )
        results.append(result)
        if diff_dir and mask is not None and not result.ok:
            _write_diff_image(
                os.path.join(diff_dir, name),
                os.path.join(baseline_dir, name),
                os.path.join(actual_dir, name),
                mask,
            )
    return results, errors


def _write_diff_image(path, baseline_path, actual_path, mask: bytes) -> None:
    """Writes a red-on-white mask so a failure is diagnosable by eye."""
    base = read_png(baseline_path)
    width, height = base.width, base.height
    rgba = bytearray(width * height * 4)
    for index in range(width * height):
        offset = index * 4
        if mask[index]:
            rgba[offset : offset + 4] = b"\xff\x00\x00\xff"
        else:
            # A faint grey of the baseline keeps the layout legible.
            grey = (base.rgba[offset] + base.rgba[offset + 1] + base.rgba[offset + 2]) // 3
            faint = 255 - (255 - grey) // 6
            rgba[offset : offset + 4] = bytes((faint, faint, faint, 255))
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    write_png_rgba(path, Image(width, height, bytes(rgba)))


# ---------------------------------------------------------------------------
# Ink measurement (the font-scale proof)
# ---------------------------------------------------------------------------


def ink_bbox(image: Image, threshold: int = INK_THRESHOLD):
    """Returns the bounding box of non-background ink, or None.

    "Ink" is any pixel whose red, green or blue channel is below ``threshold``
    (the capture backdrop is pure white, so AA fringes count from 240 down).
    Returns ``(x0, y0, x1, y1)`` with inclusive coordinates, or ``None``.
    """
    width, height = image.width, image.height
    rgba = image.rgba
    min_x, min_y = width, height
    max_x, max_y = -1, -1
    for y in range(height):
        row = y * width * 4
        for x in range(width):
            offset = row + x * 4
            if (
                rgba[offset] < threshold
                or rgba[offset + 1] < threshold
                or rgba[offset + 2] < threshold
            ):
                if x < min_x:
                    min_x = x
                if x > max_x:
                    max_x = x
                if y < min_y:
                    min_y = y
                if y > max_y:
                    max_y = y
    if max_x < 0:
        return None
    return (min_x, min_y, max_x, max_y)


def ink_bbox_fast(path: str, threshold: int = INK_THRESHOLD):
    """Pillow path for :func:`ink_bbox`; None when Pillow is unavailable."""
    try:
        from PIL import Image as PilImage, ImageChops  # type: ignore
    except Exception:
        return None
    with PilImage.open(path) as src:
        rgb = src.convert("RGB")
    masks = [
        band.point(lambda value: 255 if value < threshold else 0)
        for band in rgb.split()
    ]
    mask = ImageChops.lighter(ImageChops.lighter(masks[0], masks[1]), masks[2])
    return mask.getbbox()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _cmd_compare(args) -> int:
    baseline_dir = os.path.abspath(args.baseline)
    actual_dir = os.path.abspath(args.actual)
    for label, path in (("baseline", baseline_dir), ("actual", actual_dir)):
        if not os.path.isdir(path):
            print(f"ERROR: {label} directory not found: {path}", file=sys.stderr)
            return 2
    if args.diff_dir:
        os.makedirs(args.diff_dir, exist_ok=True)

    results, errors = compare_directories(
        baseline_dir,
        actual_dir,
        channel_delta=args.channel_delta,
        max_diff_ratio=args.max_ratio,
        diff_dir=args.diff_dir,
    )

    failed = [result for result in results if not result.ok]
    limit = args.max_ratio
    print(f"baseline: {baseline_dir}")
    print(f"actual:   {actual_dir}")
    print(
        f"rule:     any RGBA channel delta > {args.channel_delta} counts a pixel; "
        f"fail when diff pixels > {limit * 100:.4f}% of the image"
    )
    for result in results:
        print(result.line(limit))
    for error in errors:
        print(f"FAIL {error}")
    if results:
        smallest = min(results, key=lambda result: result.width * result.height)
        page_pixels = 1080 * 2400
        print(
            f"note:     {limit * 100:.4f}% = "
            f"{int(smallest.width * smallest.height * limit)} px on the smallest "
            f"frame ({smallest.width}x{smallest.height}), "
            f"{int(page_pixels * limit)} px on a full page (1080x2400)"
        )

    ok = not failed and not errors
    print(f"RESULT={'pass' if ok else 'fail'} images={len(results)} failed={len(failed)}")
    if args.summary:
        with open(args.summary, "w", encoding="utf-8") as handle:
            handle.write(f"RESULT={'pass' if ok else 'fail'}\n")
            for result in results:
                handle.write(result.line(limit) + "\n")
            for error in errors:
                handle.write(f"FAIL {error}\n")
    return 0 if ok else 1


def _cmd_ink(args) -> int:
    path = os.path.abspath(args.image)
    if not os.path.isfile(path):
        print(f"ERROR: image not found: {path}", file=sys.stderr)
        return 2
    image = read_png(path)
    bbox = ink_bbox_fast(path, args.threshold)
    if bbox is None:
        bbox = ink_bbox(image, args.threshold)
    if bbox is None:
        print(f"ERROR: no ink below threshold {args.threshold} in {path}", file=sys.stderr)
        return 1
    x0, y0, x1, y1 = bbox
    print(
        f"image={os.path.basename(path)} size={image.width}x{image.height} "
        f"ink_bbox={x0},{y0},{x1},{y1} "
        f"ink_width={x1 - x0 + 1} ink_height={y1 - y0 + 1} "
        f"threshold={args.threshold}"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    compare = sub.add_parser("compare", help="compare a capture directory with baselines")
    compare.add_argument("--baseline", required=True)
    compare.add_argument("--actual", required=True)
    compare.add_argument("--diff-dir", default=None)
    compare.add_argument("--channel-delta", type=int, default=CHANNEL_DELTA)
    compare.add_argument("--max-ratio", type=float, default=MAX_DIFF_RATIO)
    compare.add_argument("--summary", default=None)
    compare.set_defaults(func=_cmd_compare)

    ink = sub.add_parser("ink", help="print the ink bounding box of a capture")
    ink.add_argument("--image", required=True)
    ink.add_argument("--threshold", type=int, default=INK_THRESHOLD)
    ink.set_defaults(func=_cmd_ink)

    return parser


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


# ---------------------------------------------------------------------------
# Unit tests for the threshold itself (pytest collects these)
# ---------------------------------------------------------------------------


def _solid_image(width: int, height: int, rgba=(255, 255, 255, 255)) -> Image:
    return Image(width, height, bytes(rgba) * (width * height))


def _write(path, image: Image) -> str:
    write_png_rgba(str(path), image)
    return str(path)


def test_identical_images_pass(tmp_path):
    baseline = _write(tmp_path / "a.png", _solid_image(20, 20))
    actual = _write(tmp_path / "b.png", _solid_image(20, 20))
    result, _ = compare_image(baseline, actual)
    assert result.ok
    assert result.diff_pixels == 0


def test_channel_delta_at_threshold_is_ignored(tmp_path):
    baseline = _write(tmp_path / "a.png", _solid_image(20, 20))
    # 2/255 is exactly the tolerance: not a difference.
    actual = _write(tmp_path / "b.png", _solid_image(20, 20, (253, 255, 255, 255)))
    result, _ = compare_image(baseline, actual)
    assert result.ok
    assert result.diff_pixels == 0


def test_channel_delta_above_threshold_fails(tmp_path):
    baseline = _write(tmp_path / "a.png", _solid_image(20, 20))
    actual = _write(tmp_path / "b.png", _solid_image(20, 20, (252, 255, 255, 255)))
    result, _ = compare_image(baseline, actual)
    assert not result.ok
    assert result.diff_pixels == 400


def test_ratio_threshold_is_respected(tmp_path):
    # 10x10 = 100 px; 0.1 % would allow 0.1 px, so one changed pixel fails.
    baseline = _write(tmp_path / "a.png", _solid_image(10, 10))
    rgba = bytearray(_solid_image(10, 10).rgba)
    rgba[0:4] = b"\x00\x00\x00\x00"
    actual = _write(tmp_path / "b.png", Image(10, 10, bytes(rgba)))
    result, _ = compare_image(baseline, actual)
    assert not result.ok
    assert result.diff_pixels == 1


def test_size_mismatch_fails(tmp_path):
    baseline = _write(tmp_path / "a.png", _solid_image(20, 20))
    actual = _write(tmp_path / "b.png", _solid_image(20, 21))
    result, _ = compare_image(baseline, actual)
    assert not result.ok
    assert result.reason == "size"


def test_missing_capture_is_an_error(tmp_path):
    baseline_dir = tmp_path / "baseline"
    actual_dir = tmp_path / "actual"
    baseline_dir.mkdir()
    actual_dir.mkdir()
    _write(baseline_dir / "a.png", _solid_image(4, 4))
    results, errors = compare_directories(str(baseline_dir), str(actual_dir))
    assert results == []
    assert any("missing capture" in error for error in errors)


def test_ink_bbox_finds_the_black_square(tmp_path):
    image = _solid_image(10, 10)
    rgba = bytearray(image.rgba)
    for y in (3, 4):
        for x in (2, 3, 4):
            offset = (y * 10 + x) * 4
            rgba[offset : offset + 4] = b"\x00\x00\x00\xff"
    path = _write(tmp_path / "ink.png", Image(10, 10, bytes(rgba)))
    bbox = ink_bbox(read_png(path))
    assert bbox == (2, 3, 4, 4)


def test_stdlib_decoder_matches_pillow_when_available(tmp_path):
    try:
        from PIL import Image as PilImage
    except Exception:
        return  # nothing to compare against on a Pillow-less host
    path = str(tmp_path / "gradient.png")
    source = PilImage.new("RGBA", (64, 32))
    pixels = source.load()
    for y in range(32):
        for x in range(64):
            pixels[x, y] = (x * 4 % 256, y * 8 % 256, (x + y) % 256, 255)
    source.save(path)
    stdlib = _read_png_stdlib(path)
    pillow = read_png(path)
    assert (stdlib.width, stdlib.height) == (pillow.width, pillow.height)
    assert stdlib.rgba == pillow.rgba


if __name__ == "__main__":
    sys.exit(main())
