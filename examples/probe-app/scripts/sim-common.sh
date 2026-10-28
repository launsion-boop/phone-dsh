#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Shared iOS Simulator flow for the phone-DSH gates.
#
# Sourced by `scripts/ci/sim.sh` (the W3-SIM gate) and by
# `scripts/ci/scenarios.sh --run-on sim` (the G2 catalog scenario runner
# on the simulator). It owns the one copy of: tool checks, the wall-clock
# watchdog, simulator selection/boot, XcodeGen project generation, staging the
# Worker assets into the probe app, app install and app-container lookup.
#
# No absolute local path is written here: every path is derived from the probe
# project directory or passed in by the caller.

# Bundle identifier of the probe app (`examples/probe-app/project.yml`).
SIM_PROBE_BUNDLE_ID="dev.phone-dsh.probe"

# Fails when one of the tools the simulator flow needs is missing.
sim_require_tools() {
  local tool
  for tool in xcrun xcodebuild xcodegen python3; do
    command -v "$tool" >/dev/null 2>&1 || {
      echo "sim: $tool is not installed" >&2
      return 1
    }
  done
}

# Same-source asset audit shared by the simulator gate.
#
# The complete Web page and the Worker image must both name the canonical
# repository pin *and* the DSH source selected for this run, and the page's
# recorded hashes must match the bytes on disk. `copy-bundle-assets.sh` can
# synthesize a `web-build.json` for a raw `--web-dist`; that is acceptable only
# for a caller that supplied no record, never for this gate, so a prebuilt page
# is checked *before* the copy and the staged bundle is checked again
# afterwards. A missing or stale record fails loudly instead of being stamped
# with the current pin. `sim.sh` passes both pairs through
# PDSH_SIM_AUDIT_CANONICAL_* / PDSH_SIM_AUDIT_EXPECTED_*; without the latter a
# direct call keeps the canonical-pin-only behaviour.
sim_verify_web_dist() { # <web-dir> <pin-file> <label>
  sim_verify_assets web "$1" "$2" "$3"
}

sim_verify_image_metadata() { # <image-dir> <pin-file> <label> <image-file>
  sim_verify_assets image "$1" "$2" "$3" "$4"
}

sim_verify_worker_metadata() { # <worker-dir> <pin-file> <label>
  sim_verify_assets worker "$1" "$2" "$3" "$1/image.tar.gz"
}

sim_verify_assets() { # <mode> <directory> <pin-file> <label> [image-file]
  python3 - "$@" <<'PY'
import hashlib
import json
import os
import sys

mode, directory, pin_file, label = sys.argv[1:5]
image_path = sys.argv[5] if len(sys.argv) > 5 else None


def fail(message):
    print(f"sim: {label}: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as error:
        fail(f"cannot read {path}: {error}")


def sha256(path):
    try:
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError as error:
        fail(f"cannot hash {path}: {error}")


pin = read_json(pin_file)
pin_commit = pin.get("commit")
pin_version = pin.get("version")
if not isinstance(pin_commit, str) or not pin_commit:
    fail(f"{pin_file} has no commit")
if not isinstance(pin_version, str) or not pin_version:
    fail(f"{pin_file} has no version")

# The canonical pin and the selected source are caller inputs, not values read
# back from the Web/image records being audited. sim.sh exports both; a direct
# call without PDSH_SIM_AUDIT_EXPECTED_* behaves like the original canonical
# pin gate.
canonical_commit = os.environ.get("PDSH_SIM_AUDIT_CANONICAL_COMMIT") or pin_commit
canonical_version = os.environ.get("PDSH_SIM_AUDIT_CANONICAL_VERSION") or pin_version
expected_commit = os.environ.get("PDSH_SIM_AUDIT_EXPECTED_COMMIT") or ""
expected_version = os.environ.get("PDSH_SIM_AUDIT_EXPECTED_VERSION") or ""
if bool(expected_commit) != bool(expected_version):
    fail("the selected source audit needs both expected commit and version")
if not expected_commit:
    expected_commit = canonical_commit
    expected_version = canonical_version


def full_commit(value):
    return isinstance(value, str) and len(value) == 40 and all(
        character in "0123456789abcdef" for character in value)


if not full_commit(canonical_commit):
    fail(f"canonical source commit {canonical_commit!r} is not a full 40-character lowercase hex sha")
if not isinstance(canonical_version, str) or not canonical_version:
    fail("canonical source version is empty")
if pin_commit != canonical_commit or pin_version != canonical_version:
    fail(f"{pin_file} does not name the supplied canonical source "
         f"{canonical_commit} ({canonical_version})")
if not full_commit(expected_commit):
    fail(f"selected source commit {expected_commit!r} is not a full 40-character lowercase hex sha")
if not isinstance(expected_version, str) or not expected_version:
    fail("selected source version is empty")
expected_overridden = (expected_commit != canonical_commit
                       or expected_version != canonical_version)


def safe_relative(value, what):
    if not isinstance(value, str) or value == "" or os.path.isabs(value):
        fail(f"web-build.json has no valid {what} path: {value!r}")
    normalized = os.path.normpath(value)
    if normalized == ".." or normalized.startswith(".." + os.sep):
        fail(f"web-build.json {what} escapes the Web directory: {value!r}")
    return normalized


def check_web(web_dir):
    build_path = os.path.join(web_dir, "web-build.json")
    if not os.path.isfile(build_path):
        fail(f"{web_dir} has no web-build.json; refusing to synthesize a same-source record "
             "for a prebuilt/stale Web dist")
    build = read_json(build_path)
    if build.get("dsh_pin_commit") != canonical_commit:
        fail(f"{build_path} dsh_pin_commit {build.get('dsh_pin_commit')!r} "
             f"!= canonical {canonical_commit!r}")
    if build.get("dsh_pin_version") != canonical_version:
        fail(f"{build_path} dsh_pin_version {build.get('dsh_pin_version')!r} "
             f"!= canonical {canonical_version!r}")
    if build.get("commit") != expected_commit:
        fail(f"{build_path} commit {build.get('commit')!r} "
             f"!= selected {expected_commit!r}")
    if build.get("dsh_version") != expected_version:
        fail(f"{build_path} dsh_version {build.get('dsh_version')!r} "
             f"!= selected {expected_version!r}")
    if build.get("version") != expected_version:
        fail(f"{build_path} version {build.get('version')!r} "
             f"!= selected {expected_version!r}")
    if build.get("dsh_checkout_overridden") is not expected_overridden:
        fail(f"{build_path} dsh_checkout_overridden "
             f"{build.get('dsh_checkout_overridden')!r} != {expected_overridden!r} "
             "for the canonical/selected pair")
    index = os.path.join(web_dir, safe_relative(build.get("index", "index.html"), "index"))
    entry = os.path.join(web_dir, safe_relative(build.get("entry"), "entry"))
    if not os.path.isfile(index):
        fail(f"Web index is missing: {index}")
    if not os.path.isfile(entry):
        fail(f"Web Vite entry is missing: {entry}")
    actual_index = sha256(index)
    actual_entry = sha256(entry)
    if build.get("index_sha256") != actual_index:
        fail(f"{build_path} index_sha256 does not match {index}")
    if build.get("entry_sha256") != actual_entry:
        fail(f"{build_path} entry_sha256 does not match {entry}")
    return build


def check_image(image_dir, image):
    sizes_path = os.path.join(image_dir, "sizes.json")
    if not os.path.isfile(sizes_path):
        fail(f"{image_dir} has no sizes.json; the Worker image has no source record")
    sizes = read_json(sizes_path)
    if sizes.get("dsh_pin_commit") != canonical_commit:
        fail(f"{sizes_path} dsh_pin_commit {sizes.get('dsh_pin_commit')!r} "
             f"!= canonical {canonical_commit!r}")
    if sizes.get("dsh_pin_version") != canonical_version:
        fail(f"{sizes_path} dsh_pin_version {sizes.get('dsh_pin_version')!r} "
             f"!= canonical {canonical_version!r}")
    if sizes.get("dsh_expected_commit") != expected_commit:
        fail(f"{sizes_path} dsh_expected_commit {sizes.get('dsh_expected_commit')!r} "
             f"!= selected {expected_commit!r}")
    if sizes.get("dsh_expected_version") != expected_version:
        fail(f"{sizes_path} dsh_expected_version {sizes.get('dsh_expected_version')!r} "
             f"!= selected {expected_version!r}")
    if sizes.get("dsh_commit") != expected_commit:
        fail(f"{sizes_path} dsh_commit {sizes.get('dsh_commit')!r} "
             f"!= selected {expected_commit!r}")
    if sizes.get("dsh_version") != expected_version:
        fail(f"{sizes_path} dsh_version {sizes.get('dsh_version')!r} "
             f"!= selected {expected_version!r}")
    if sizes.get("dsh_checkout_overridden") is not expected_overridden:
        fail(f"{sizes_path} dsh_checkout_overridden "
             f"{sizes.get('dsh_checkout_overridden')!r} != {expected_overridden!r} "
             "for the canonical/selected pair")
    if not isinstance(image, str) or not os.path.isfile(image):
        fail(f"Worker image is missing: {image}")
    gzip_bytes = sizes.get("gzip_bytes")
    if not isinstance(gzip_bytes, int) or gzip_bytes <= 0:
        fail(f"{sizes_path} has no positive gzip_bytes")
    actual_bytes = os.path.getsize(image)
    if actual_bytes != gzip_bytes:
        fail(f"{image} is {actual_bytes} bytes but sizes.json records {gzip_bytes}")
    return sizes


if mode == "web":
    check_web(directory)
elif mode == "image":
    if image_path is None:
        fail("image verification needs the image path")
    check_image(directory, image_path)
elif mode == "worker":
    web = check_web(os.path.join(directory, "web"))
    sizes = check_image(directory, image_path or os.path.join(directory, "image.tar.gz"))
    if web.get("commit") != sizes.get("dsh_commit"):
        fail("the Web page and Worker image name different source commits")
    if web.get("version") != sizes.get("dsh_version"):
        fail("the Web page and Worker image name different source versions")
    if web.get("dsh_version") != sizes.get("dsh_version"):
        fail("the Web page and Worker image name different DSH versions")
    probe_path = os.path.join(directory, "probe-bundle.json")
    if not os.path.isfile(probe_path):
        fail(f"missing {probe_path}")
    probe = read_json(probe_path)
    if probe.get("source") != "plugins/scripts/pack-image.mjs":
        fail(f"{probe_path} does not name the pack-image source")
    if probe.get("jsc_prelude") is not True:
        fail(f"{probe_path} does not record the JavaScriptCore prelude")
    probe_web = probe.get("web") if isinstance(probe.get("web"), dict) else {}
    probe_image = probe.get("image") if isinstance(probe.get("image"), dict) else {}
    if probe_web.get("commit") != expected_commit \
       or probe_web.get("dsh_version") != expected_version:
        fail(f"{probe_path} does not describe the selected Web source "
             f"{expected_commit} ({expected_version})")
    if probe_image.get("commit") != expected_commit \
       or probe_image.get("dsh_version") != expected_version:
        fail(f"{probe_path} does not describe the selected image source "
             f"{expected_commit} ({expected_version})")
    if probe_image.get("pin_commit") != canonical_commit \
       or probe_image.get("pin_version") != canonical_version:
        fail(f"{probe_path} does not record the canonical pin "
             f"{canonical_commit} ({canonical_version})")
    for required in ("worker-entry.js", "tool-worker-python.js",
                     "workflow-isolate.js", "web/web-boot.js", "image.tar.gz"):
        path = os.path.join(directory, required)
        if not os.path.isfile(path):
            fail(f"missing staged Worker asset: {path}")
else:
    fail(f"unknown verification mode: {mode}")

print(f"sim: {label}: same-source assets verified at selected {expected_commit} "
      f"({expected_version}); canonical pin {canonical_commit} ({canonical_version})")
PY
}

# Runs a command with an overall wall-clock deadline while keeping the
# caller's stdout pipe closed in background processes.
sim_run_with_timeout() { # <seconds> <label> <command...>
  local seconds="$1"
  local label="$2"
  shift 2
  "$@" 3>&- &
  local pid=$!
  (
    exec 3>&-
    local waited=0
    while [ "$waited" -lt "$seconds" ]; do
      kill -0 "$pid" 2>/dev/null || exit 0
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "sim: timeout: $label exceeded ${seconds}s; terminating pid $pid"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 5
      kill -KILL "$pid" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  local watchdog=$!
  local rc=0
  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

# Selects an available simulator by name, preferring one already booted, boots
# it when needed, and prints `<udid>|<name>|<runtime>|<previous state>`.
sim_resolve_device() { # <device-name>
  local name="$1"
  local selection
  selection="$(
    xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
found = []
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("name") != name or not device.get("isAvailable", True):
            continue
        found.append((device.get("state") == "Booted", runtime, device))
if not found:
    sys.exit(1)
found.sort(key=lambda item: (not item[0], item[1]))
booted, runtime, device = found[0]
print("|".join([
    device["udid"], device["name"], runtime, device["state"],
]))
' "$name"
  )" || return 1
  local udid="${selection%%|*}"
  local rest="${selection#*|}"
  local state="${rest##*|}"
  if [ "$state" != "Booted" ]; then
    echo "sim: booting $name ($udid)" >&2
    xcrun simctl boot "$udid" 2>/dev/null || true
  fi
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  printf '%s\n' "$selection"
}

# Selects a simulator from an `xcodebuild -destination` value. Accepts
# `id=<udid>`, `name=<name>` (with optional OS=) and falls back to the
# `PDSH_SIM_DEVICE` name. Prints `<udid>|<name>|<runtime>|<state>`. The caller
# builds the xcodebuild destination string from the id.
sim_resolve_destination() { # <destination-or-empty> [default-name]
  local destination="${1:-}"
  local default_name="${2:-${PDSH_SIM_DEVICE:-iPhone 17 Pro}}"
  local id="" name=""
  if [ -n "$destination" ]; then
    case "$destination" in
      *Simulator*|*simulator*) ;;
      *)
        echo "sim: destination '$destination' is not an iOS Simulator destination" >&2
        return 3
        ;;
    esac
    local parsed
    parsed="$(python3 - "$destination" <<'PYDEST'
import sys
for part in sys.argv[1].split(","):
    if part.startswith("id="):
        print("id=" + part[3:])
    elif part.startswith("name="):
        print("name=" + part[5:])
PYDEST
)"
    id="$(printf '%s\n' "$parsed" | sed -n 's/^id=//p' | head -n 1)"
    name="$(printf '%s\n' "$parsed" | sed -n 's/^name=//p' | head -n 1)"
  fi
  if [ -n "$id" ]; then
    local selection
    selection="$(
      xcrun simctl list devices available -j | python3 -c '
import json, sys
wanted = sys.argv[1]
data = json.load(sys.stdin)
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("udid") != wanted or not device.get("isAvailable", True):
            continue
        print("|".join([device["udid"], device["name"], runtime, device.get("state", "")]))
        raise SystemExit(0)
raise SystemExit(1)
' "$id"
    )" || {
      echo "sim: no available iOS Simulator with id $id" >&2
      return 1
    }
    local udid="${selection%%|*}"
    local state="${selection##*|}"
    if [ "$state" != "Booted" ]; then
      xcrun simctl boot "$udid" 2>/dev/null || true
    fi
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
    printf '%s\n' "$selection"
    return 0
  fi
  local resolved
  resolved="$(sim_resolve_device "${name:-$default_name}")" || return 1
  local udid="${resolved%%|*}"
  local resolved_name
  resolved_name="$(printf '%s\n' "$resolved" | cut -d'|' -f2)"
  printf '%s\n' "$resolved"
}

# Generates the Xcode project from project.yml (the .xcodeproj is not tracked).
sim_generate_project() { # <example-dir>
  ( cd "$1" && xcodegen generate >/dev/null )
}

# Stages the built Worker assets into the probe app's Bundle/worker through the
# documented copy script. A prebuilt PDSH_DSH_WWW/PDSH_DSH_IMAGE pair is reused;
# otherwise the copy script builds both from the pinned checkout.
sim_prepare_worker_assets() { # <example-dir> <staging-dir> <www> <image>
  local example="$1"
  local bundle="$2"
  local www="${3:-}"
  local image="${4:-}"
  local image_dir=""
  local copy_assets="$example/scripts/copy-bundle-assets.sh"
  if [ -n "$www" ] && [ -n "$image" ] && [ -f "$image" ] \
     && [ -f "$www/worker-entry.js" ] && [ -f "$www/index.html" ] \
     && [ -f "$www/boot.js" ] && [ -f "$www/web-boot.js" ]; then
    image_dir="$(cd "$(dirname "$image")" && pwd -P)"
    if [ ! -f "$www/tool-worker-python.js" ]; then
      echo "sim: the prebuilt Worker bundle has no tool-worker-python.js: $www" >&2
      echo "sim: python3 cannot start in the probe app; rebuild with worker-entry/build.mjs --out <dir>" >&2
      return 1
    fi
    if [ ! -f "$www/workflow-isolate.js" ]; then
      echo "sim: the prebuilt Worker bundle has no workflow-isolate.js: $www" >&2
      echo "sim: standard-preset workflows cannot start; rebuild with worker-entry/build.mjs --out <dir>" >&2
      return 1
    fi
    # The copy step now requires the real pack-image sizes.json beside the
    # image so Web and image metadata can be proven to name the same commit.
    if [ ! -f "$image_dir/sizes.json" ]; then
      echo "sim: the prebuilt image has no sizes.json beside it: $image" >&2
      echo "sim: point PDSH_DSH_IMAGE at a pack-image output's image.tar.gz, or rebuild the image" >&2
      return 1
    fi
    rm -rf "$bundle"
    mkdir -p "$bundle/worker/www" "$bundle/image/lazy"
    # A prebuilt Worker tree may carry the complete DSH Web page beside the
    # static www (`<www>/web/index.html`). Stage it into the copy script's
    # worker-out and pass it explicitly as --web-dist; otherwise the copy step
    # would only see Bundle/worker/web and could silently drop this run's page.
    local web_dist=""
    if [ -d "$www/web" ] && [ -f "$www/web/index.html" ]; then
      mkdir -p "$bundle/worker/web"
      cp -R "$www/web/." "$bundle/worker/web/"
      web_dist="$bundle/worker/web"
    fi
    cp "$www/worker-entry.js" "$bundle/worker/worker-entry.js"
    cp "$www/worker-entry.js.map" "$bundle/worker/" 2>/dev/null || true
    # The python runtime spawns this beside worker-entry.js. Reusing a prebuilt
    # pair that lacks it would leave python3 hanging on a 404 nested Worker, so
    # the copy script requires it and fails loud before the app is built.
    cp "$www/tool-worker-python.js" "$bundle/worker/tool-worker-python.js"
    cp "$www/tool-worker-python.js.map" "$bundle/worker/" 2>/dev/null || true
    # The generic WASI worker hosts the jq engine; the copy is optional only
    # for a pre-jq bundle whose shell retains the shim.
    cp "$www/tool-worker.js" "$bundle/worker/tool-worker.js" 2>/dev/null || true
    cp "$www/tool-worker.js.map" "$bundle/worker/" 2>/dev/null || true
    # Provenance is written by the image packer; a legacy prebuilt bundle may
    # predate it, so stage it only when present.
    if [ -f "$www/phone-dsh-provenance.json" ]; then
      cp "$www/phone-dsh-provenance.json" "$bundle/worker/phone-dsh-provenance.json"
    fi
    # The Worker workflow bridge creates its isolate beside worker-entry.js.
    cp "$www/workflow-isolate.js" "$bundle/worker/workflow-isolate.js"
    cp "$www/workflow-isolate.js.map" "$bundle/worker/" 2>/dev/null || true
    # The full Web page's boot module is built beside the Worker entry and is
    # injected from web/index.html as ./web-boot.js.
    cp "$www/web-boot.js" "$bundle/worker/web-boot.js"
    cp "$www/web-boot.js.map" "$bundle/worker/" 2>/dev/null || true
    cp "$www/index.html" "$bundle/worker/www/index.html"
    cp "$www/boot.js" "$bundle/worker/www/boot.js"
    cp "$image" "$bundle/image/image.tar.gz"
    # Keep the pack-image source record and its runtime files beside the
    # copied archive: the copy step reads sizes.json from --image-out, and the
    # gate below compares it with the Web page's web-build.json. Without this
    # a prebuilt image would lose the very metadata the gate must audit.
    local extra
    for extra in worker.js client.js manifest.json sizes.json; do
      if [ -f "$image_dir/$extra" ]; then
        cp "$image_dir/$extra" "$bundle/image/$extra"
      fi
    done
    if [ -d "$www/lazy" ]; then
      cp -R "$www/lazy/." "$bundle/image/lazy/"
    fi
    # Keep this array nonempty: bash 3.2 + nounset treats an empty array as unset.
    local copy_args=(--worker-out "$bundle/worker" --image-out "$bundle/image" --force)
    if [ -n "$web_dist" ]; then
      copy_args+=(--web-dist "$web_dist")
    fi
    if [ -f "$www/sizes.json" ] \
       && ! node -e "const r=require('node:fs').readFileSync(process.argv[1],'utf8');process.exit(JSON.parse(r).jq?0:1)" "$www/sizes.json" 2>/dev/null; then
      # A prebuilt bundle from before the jq engine stays reusable; the shell
      # command keeps its fail-loud shim and the capability manifest omits jq.
      copy_args+=(--without-jq)
    fi
    bash "$copy_assets" "${copy_args[@]}"
  else
    if [ -n "$www" ] || [ -n "$image" ]; then
      echo "sim: supplied prebuilt Worker assets are incomplete or failed provenance verification" >&2
      return 1
    fi
    bash "$copy_assets" --force
  fi
}

# Installs (or reinstalls) the probe app and prints its data container path.
sim_install_probe_app() { # <udid> <app-path>
  local udid="$1"
  local app="$2"
  xcrun simctl uninstall "$udid" "$SIM_PROBE_BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$udid" "$app" || return 1
  sim_app_container "$udid"
}

# Prints the probe app data container path for the selected simulator.
sim_app_container() { # <udid>
  local udid="$1"
  local container
  container="$(xcrun simctl get_app_container "$udid" "$SIM_PROBE_BUNDLE_ID" data 2>/dev/null || true)"
  [ -n "$container" ] || return 1
  printf '%s\n' "$container"
}

# Runs a command inside the selected simulator (host paths are visible; this is
# how container writes bypass the CI shell's own file sandbox).
sim_spawn() { # <udid> <command...>
  local udid="$1"
  shift
  xcrun simctl spawn "$udid" "$@"
}

# Copies one host file into the app container.
sim_stage_file() { # <udid> <source> <destination>
  sim_spawn "$1" /bin/cp "$2" "$3"
}

# Writes a small text payload into the app container without exposing it on the
# command line (the payload is read from a host file).
sim_stage_payload() { # <udid> <host-payload> <destination>
  sim_stage_file "$1" "$2" "$3"
}
