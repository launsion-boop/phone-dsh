# TonoLink board phone-control interface, v1

Status: `implemented` (iOS consumer only). Owner: P07. This registers an existing
boundary; it adds no wire format of its own.

A TonoLink board (`tonolink.m21r4`, firmware `agent_s3`) plugs into an iPhone's
USB-C port. It is the phone's **hands** (Bluetooth HID keyboard and absolute mouse)
and its **eyes** (an AirPlay receiver that the phone mirrors its screen to). Phone
DSH on the same phone runs the UI-Venus agent against it, with no computer.

The producer is the board firmware, outside this repository:
`tonolink-m21-r4-firmware` at `9ff0260` (`main/http/route_v1.c`, `main/link_tools.c`).
The consumer is `Sources/PhoneDSHBLE/TonoLink*.swift` plus
`Sources/PhoneDSHVenus/IPhoneAgent*.swift`. Android and HarmonyOS have no consumer.

## 1. Which channel carries what

| Need | Channel | Contract |
| --- | --- | --- |
| LED, Home HTTP | BLE Link Tools profile (`light.set`, `light.get`, `home.http`) | [ble-link.md](ble-link.md); reached by the agent through native MCP `ble_link_call` ([native-mcp.md](../../v1/native-mcp.md)) |
| Taps, swipes, typing | Board HTTP over USB NCM (§2) | this document |
| Screen | APV1 stream over USB NCM (§3) | this document |
| Pairing, console, BLE OTA (DEBUG) | TonoLink ctrl GATT service (§4) | this document |

Phone control does not use the Link Tools profile in v1: that profile excludes HID
([ble-link.md](ble-link.md)), and a screen frame cannot fit its 4096-byte RPC. Moving
HID actions into Link tools is a separate, not yet frozen change (phase 2); until it
is frozen, no end may send HID through Link.

## 2. Board HTTP over USB NCM

The board serves `http://192.168.247.1:8767` on the USB network it presents to
the phone (the phone takes `192.168.247.2`). Requests use `Connection: close`;
`auth` is `none` on these routes (the USB cable is the trust boundary).

| Route | Consumer use |
| --- | --- |
| `GET /v1/info` | `model`, `fw.version`, `features` (display only) |
| `GET /v1/phone/status` | `hid.{keyboard,absolute,input_mode}` must all be true before input; `airplay.{mirror_active,viewer_connected}` |
| `POST /v1/hid/enable {"on":true}` | Re-attaches HID; the consumer waits ≥6 s before asking again |
| `POST /v1/hid/batch {"steps":[…],"wait":true}` | One gesture per batch; the consumer's HTTP timeout is 15 s plus the batch's planned duration |
| `POST /v1/usb {"action":"enable"}` | Brings NCM and the AirPlay receiver up (RAM-only on the board) |

A batch that times out or fails is reported to the model as "not executed: …" and
is **not retried**: the outcome on the phone is unknown. The agent re-observes the
screen before the next step.

## 3. Screen stream (APV1)

The phone keeps one TCP connection to `192.168.247.1:8769`. The board sends the
mirrored screen as APV1 records (H.264 or HEVC), which `TonoLinkScreen` decodes in
software so it keeps working with the app in the background. iOS sends a keyframe
only when mirroring starts; the board caches the last GOP and replays it to a new
viewer, so the consumer may connect lazily. Each agent step observes a frame
decoded after the previous step's frame (`snapshot(newerThan:)`), never a stale one.

## 4. Ctrl GATT service

Service `5DBD66EC-9E78-42D4-854F-DE5EBBFFA363`: `cmd` `2D0EA61C-DCAC-48A2-816C-8DFF5022E6DE`
(write), `status` `4DF6DE7E-42FA-4F5E-92DE-BAD8AC1DE887` (notify, requires
encryption), optional `audio` `7A1C9E52-3B6D-4F08-9C2E-5D4B8A61F0A3`. Console lines
and BLE OTA framing are defined by `TonoLinkBLEDebugProtocol.swift` and
`TonoLinkUSBOTAProtocol.swift`, matching the firmware's `pa_ctrl_core.c`.

## 5. DEBUG relay (developer builds only)

DEBUG builds can serve `TonoLinkRelay` on the phone's Wi-Fi at `:8780` and forward
`:8767` and `:8769`, so a computer can reach the board through the phone. The relay
has **no authentication**: anyone on that Wi-Fi can drive the phone and flash the
board while it is on. It is compiled only under `#if DEBUG`, listens only after a
user (or the `PDSH_TONOLINK_USB_OTA=relay` launch variable) turns it on, and is never
part of a release build.

## 6. Agent

`iphone_agent_run` ([native-mcp.md](../../v1/native-mcp.md)) runs one UI-Venus task:
screen in, one action out, executed through §2, up to the step limit. The model
endpoint, model name and key come from the app's UI-Venus settings (key in the
Keychain service `dev.phone-dsh.ui-venus`, never in preferences). The task result is
the model's assessment, not proof; `finished=false` must not be reported as success.
