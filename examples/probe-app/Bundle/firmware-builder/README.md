# Firmware builder pack (untracked)

The DEBUG "Firmware builder" page builds the TonoLink ESP32-S3 firmware on the
iPhone. Its page code is tracked in `../../FirmwareBuilder/`; the large inputs
live here and are **not** committed:

| File | What it is |
| --- | --- |
| `cc1.wasm`, `as.wasm`, `ar.wasm`, `ld.wasm` | Espressif GCC 15.2.0 `cc1` and binutils esp-2.45.0 `as`/`ar`/`ld`, built for `wasm32-wasip1` with the ESP32-S3 overlay compiled in |
| `sdk.bin` | Prebuilt ESP-IDF archives, linker scripts, the archive plan and the exact `ld` arguments of one IDF build |
| `project.bin` | The project's sources and headers and the exact `cc1`/`as` arguments per source |
| `manifest.json` | Byte count and SHA-256 of each file, plus the ELF and image digests of the reference build the pack was captured from |

Stage a pack with `scripts/stage-firmware-builder.sh <directory-or-rsync-source>`.
The script copies the files and refuses a pack whose digests do not match its
manifest. Without a pack the app still builds and the page reports that the
pack is missing.

The pack is produced on a computer from one ESP-IDF build of the project; the
phone never contacts that computer. The pack fixes the target, the list of
sources and every flag: editing existing sources is supported, adding or
removing a source needs a new pack.
