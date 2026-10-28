// SPDX-License-Identifier: MIT
/**
 * Golden raster vectors for the Worker `sharp` shim regression.
 *
 * They are fixed bytes, not generated at test time, so the header facts cannot
 * drift with a generator change:
 *
 *  - `GOLDEN_PNG_1X1`: a canonical 68-byte 1x1 RGBA PNG (8-bit, colour type 6,
 *    fully transparent) with one IDAT and IEND, the smallest ordinary PNG.
 *  - `GOLDEN_GIF_2FRAME`: a 2x2 GIF89a with a 4-entry global palette, the
 *    NETSCAPE looping extension, and two image frames. Both frame descriptors
 *    are 2x2; no graphic-control transparency flag is set.
 *  - `GOLDEN_JPEG_3X2`: a 3x2 baseline JPEG whose APP1 EXIF and APP13
 *    Photoshop segments were removed, so it is a clean single-frame raster for
 *    the byte-identical normalization pass-through.
 *  - `GOLDEN_JPEG_WEBKIT_METADATA`: `GOLDEN_JPEG_3X2` with the APP1
 *    `Exif\0\0` (orientation 6) and APP13 `Photoshop 3.0\0` segments a real
 *    WebKit `OffscreenCanvas` JPEG encode attached in the root WK diagnosis.
 *    It is a structural fixture assembled from the clean vector, not a capture
 *    from WebKit itself; it contains the same marker identifiers and TIFF/IRB
 *    payload shapes the shim's container inspector recognizes.
 *
 * Their dimensions were confirmed with an independent system decoder during
 * generation; the assertions below read them through the shim's pure-TS
 * header inspector.
 * @module @phone-dsh/dsh-plugins/tests/fixtures/golden-images
 */

/** Canonical 68-byte 1x1 RGBA PNG. */
export const GOLDEN_PNG_1X1 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNgAAIAAAUAAen63NgAAAAASUVORK5CYII='

/** 2x2 GIF89a with two frames and no transparency. */
export const GOLDEN_GIF_2FRAME = 'R0lGODlhAgACAIEAAAAAgP8AAP//AAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAACAwSSAgAh+QQACgAAACwAAAAAAgACAAACA5S2AgA7'

/** 3x2 clean baseline JPEG, no EXIF/XMP/IPTC metadata. */
export const GOLDEN_JPEG_3X2 = '/9j/4AAQSkZJRgABAQAASABIAAD/wAARCAACAAMDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9sAQwACAgICAgIDAgIDBAMDAwQFBAQEBAUHBQUFBQUHCAcHBwcHBwgICAgICAgICgoKCgoKCwsLCwsNDQ0NDQ0NDQ0N/9sAQwECAgIDAwMGAwMGDQkHCQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0N/90ABAAB/9oADAMBAAIRAxEAPwDM8IeD/CX/AAjOnf8AEk07/Uj/AJdIfU/7FdJ/wh/hL/oCad/4CQ//ABFJ4Q/5FnTv+uI/ma6Sv7fx/wDvNT/E/wAz9+4V/wCRLg/+vVP/ANIR/9k='

/** Structural WebKit-shaped JPEG: APP1 EXIF orientation 6 and APP13 Photoshop segments. */
export const GOLDEN_JPEG_WEBKIT_METADATA = '/9j/4AAQSkZJRgABAQAASABIAAD/4QAiRXhpZgAASUkqAAgAAAABABIBAwABAAAABgAAAAAAAAD/7QAgUGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAQcAgAA/8AAEQgAAgADAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwQDAwMEBQQEBAQFBwUFBQUFBwgHBwcHBwcICAgICAgICAoKCgoKCgsLCwsLDQ0NDQ0NDQ0NDf/bAEMBAgICAwMDBgMDBg0JBwkNDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDf/dAAQAAf/aAAwDAQACEQMRAD8AzPCHg/wl/wAIzp3/ABJNO/1I/wCXSH1P+xXSf8If4S/6Amnf+AkP/wARSeEP+RZ07/riP5mukr+38f8A7zU/xP8AM/fuFf8AkS4P/r1T/wDSEf/Z'
