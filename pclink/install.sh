#!/bin/sh
# PCLink v1 one-command installer (macOS / Linux).
#
# Intended entry point:
#   curl -fsSL https://raw.githubusercontent.com/launsion-boop/phone-dsh/main/pclink/install.sh | bash
#
# When stdin is the curl pipe, every interactive prompt is read from /dev/tty.
# Pairing is scan-only: the script prints the QR, the phone scans/codes it, and
# the PC approves automatically. The script never reads a fingerprint. The only
# Y/n question is the upgrade restart; the out-of-range-dsh and foreground
# restart prompts are "press Enter" confirmations.
#
# Environment (all optional):
#   PCLINK_REF          git ref in the default GitHub spec (default: main)
#   PCLINK_PLUGIN_SPEC  full `dsh plugin add` package spec (mirror/self-hosted/local test)
#   PCLINK_RELAY_URL    relay override read by the plugin process (default: hosted relay)
#   DSH_BIN             dsh executable when it is not on PATH
#   DSH_HOME            DSH home (default: ${HOME}/.dsh)
#
# The script is POSIX sh; it is normally executed by bash from the URL above.

set -eu

DEFAULT_RELAY='https://pclink.tonoai.cn'
PROFILE_NAME='web'
LAUNCHD_LABEL='ai.deepseek.dsh'

info() {
  printf '%s\n' "$*"
}

warn() {
  printf '警告：%s\n' "$*" >&2
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

cleanup() {
  status=$?
  if [ "${status}" -ne 0 ]; then
    printf '\n安装未完成（退出码 %s）。可以重新运行同一条命令；已完成的步骤会自动跳过或升级。\n' "${status}" >&2
  fi
}
trap cleanup EXIT

# ------------------------------------------------------------------ platform
uname_s=$(uname -s 2>/dev/null || printf 'unknown')
case "${uname_s}" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    die 'Windows 不在 PCLink v1 范围内。请在 macOS 或 Linux 上运行这条命令。'
    ;;
  Darwin|Linux)
    ;;
  *)
    warn "未在 ${uname_s} 上验证过；脚本会继续，但失败时请改用 macOS 或 Linux。"
    ;;
esac

# ----------------------------------------------------------------------- TTY
# `curl | bash` makes stdin the script pipe. Open the controlling terminal
# once and use fd 3 for every question. The installer still needs a terminal
# for the restart question and the QR, but pairing itself takes no input.
if ! { : </dev/tty; } 2>/dev/null; then
  die '安装需要终端（TTY）：请在终端里运行这条命令，不要接管道重定向或放到 CI。配对本身只扫码，不需要输入指纹，但升级重启的确认需要终端。'
fi
exec 3</dev/tty
if ! printf '' >&3 2>/dev/null; then
  die '不能写入终端（/dev/tty）：请直接在交互式终端运行这条命令。'
fi

ask() {
  printf '%s' "$1" >&3
  REPLY=''
  IFS= read -r REPLY <&3 || REPLY=''
}

# ---------------------------------------------------------------------- Node
info '[1/4] 检查环境'
command -v node >/dev/null 2>&1 || die '找不到 Node.js。PCLink 需要 Node.js 22 或更新版本；请安装后重试。'
node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null < /dev/null || printf '')
case "${node_major}" in
  ''|*[!0-9]*) die '无法读取 Node.js 版本（node -p 失败）。请确认 Node.js 22+ 已正确安装。' ;;
esac
if [ "${node_major}" -lt 22 ]; then
  node_version=$(node -p 'process.versions.node' 2>/dev/null < /dev/null || printf 'unknown')
  die "Node.js ${node_version} 过旧：需要 Node.js 22 或更新版本。"
fi
info "      Node.js $(node -p 'process.versions.node' 2>/dev/null < /dev/null || printf 'unknown')"

if ! command -v pnpm >/dev/null 2>&1; then
  die "找不到 pnpm：dsh plugin 通过 pnpm 安装插件。请先安装 pnpm（例如 'corepack enable' 后 'corepack prepare pnpm@latest --activate'），再重试。"
fi

# ----------------------------------------------------------------------- dsh
if [ -n "${DSH_BIN:-}" ]; then
  [ -x "${DSH_BIN}" ] || die "DSH_BIN 指向的文件不可执行：${DSH_BIN}"
  DSH=${DSH_BIN}
else
  DSH=$(command -v dsh 2>/dev/null || true)
  [ -n "${DSH}" ] || die "找不到 dsh：请把 dsh 放到 PATH，或设置 DSH_BIN=/path/to/dsh。"
fi
[ -x "${DSH}" ] || die "dsh 不可执行：${DSH}"

dsh_version_raw=$("${DSH}" -V 2>&1 < /dev/null) || die "运行 dsh -V 失败：${dsh_version_raw}"
DSH_VERSION=$(printf '%s\n' "${dsh_version_raw}" | sed -n '1p' | tr -d '\r')
info "      dsh ${DSH_VERSION} (${DSH})"
info "      pnpm $(pnpm --version 2>/dev/null < /dev/null || printf 'unknown')"

# `>=0.2.2-rc.1 <0.3.0`: 0.2.2 release and any later 0.2.x pass. A 0.2.2
# prerelease passes only at rc.1 or later.
version_in_range() {
  version=$1
  version=${version#v}
  [ -n "${version}" ] || return 1
  case "${version}" in
    *[!0-9A-Za-z.+-]*) return 1 ;;
  esac
  numeric=${version%%-*}
  prerelease=''
  case "${version}" in
    *-*) prerelease=${version#*-} ;;
  esac
  major=${numeric%%.*}
  rest=${numeric#*.}
  minor=${rest%%.*}
  patch=${rest#*.}
  case "${major}${minor}${patch}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${major}" -eq 0 ] && [ "${minor}" -eq 2 ] || return 1
  if [ "${patch}" -gt 2 ]; then
    return 0
  fi
  if [ "${patch}" -lt 2 ]; then
    return 1
  fi
  [ -z "${prerelease}" ] && return 0
  case "${prerelease}" in
    rc.*)
      rc_number=${prerelease#rc.}
      case "${rc_number}" in
        ''|*[!0-9]*) return 1 ;;
      esac
      [ "${rc_number}" -ge 1 ] && return 0
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

if ! version_in_range "${DSH_VERSION}"; then
  warn "dsh ${DSH_VERSION} 不在已验证范围 >=0.2.2-rc.1 <0.3.0 内。"
  ask '按 Enter 继续安装，Ctrl-C 退出：'
  case "${REPLY}" in
    q|Q|quit|QUIT) die '已取消：请先把 dsh 升级到 0.2.2 或更新版本。' ;;
  esac
  info '      继续安装（未验证的 dsh 版本）。'
fi

# ------------------------------------------------------------------ DSH home
[ -n "${HOME:-}" ] || die 'HOME 未设置；请设置 HOME 或 DSH_HOME 后再运行。'
if [ -n "${DSH_HOME:-}" ]; then
  case "${DSH_HOME}" in
    /*) ;;
    *) die "DSH_HOME 必须是绝对路径：${DSH_HOME}" ;;
  esac
else
  DSH_HOME=${HOME}/.dsh
fi
PROFILE_DIR=${DSH_HOME}/profiles/${PROFILE_NAME}
PLUGIN_BIN=${PROFILE_DIR}/node_modules/.bin/pclink
PACKAGE_DIR=${PROFILE_DIR}/node_modules/dsh-pclink

# ------------------------------------------------------------------- spec
if [ -n "${PCLINK_PLUGIN_SPEC:-}" ]; then
  PLUGIN_SPEC=${PCLINK_PLUGIN_SPEC}
  info '      插件来源：PCLINK_PLUGIN_SPEC'
else
  PLUGIN_SPEC="github:launsion-boop/phone-dsh#${PCLINK_REF:-main}&path:/pclink"
  info "      插件来源：${PLUGIN_SPEC}"
fi
if [ -n "${PCLINK_RELAY_URL:-}" ]; then
  info "      中继：${PCLINK_RELAY_URL}（PCLINK_RELAY_URL）"
else
  info "      中继：${DEFAULT_RELAY}（默认）"
fi

# ------------------------------------------------------- build facts helpers
# The on-disk package build. The walker must match core/package-info.mjs so an
# admin `plugin.packageSha256` and this value are comparable.
disk_facts() {
  if [ ! -d "${PACKAGE_DIR}" ]; then
    printf 'unknown unknown'
    return 0
  fi
  node - "${PACKAGE_DIR}" <<'NODE' 2>/dev/null || printf 'unknown unknown'
const { createHash } = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const root = process.argv[2]
const skipped = new Set(['node_modules', 'test', '.spike'])
let version = 'unknown'
for (const candidate of [path.join(root, 'package.json'), path.join(root, 'plugin', 'package.json')]) {
  try {
    const manifest = JSON.parse(fs.readFileSync(candidate, 'utf8'))
    if (typeof manifest.version === 'string' && manifest.version !== '') { version = manifest.version; break }
  } catch {}
}
const files = []
const walk = (directory, prefix) => {
  for (const name of fs.readdirSync(directory).sort()) {
    if (skipped.has(name)) continue
    const full = path.join(directory, name)
    const relative = prefix === '' ? name : prefix + '/' + name
    const stat = fs.statSync(full)
    if (stat.isDirectory()) walk(full, relative)
    else if (stat.isFile()) files.push({ relative, full })
  }
}
try { walk(root, '') } catch { process.stdout.write(version + ' unknown'); process.exit(0) }
files.sort((left, right) => left.relative < right.relative ? -1 : left.relative > right.relative ? 1 : 0)
const hash = createHash('sha256')
for (const file of files) {
  const bytes = fs.readFileSync(file.full)
  hash.update(file.relative)
  hash.update('\0')
  hash.update(String(bytes.length))
  hash.update('\0')
  hash.update(bytes)
}
process.stdout.write(version + ' ' + hash.digest('hex'))
NODE
}

# The running plugin's own build facts from the v1.6 admin status. Empty when
# the running process is pre-v1.6 (no plugin member) or the CLI is old.
running_facts() {
  status_json=$("${PLUGIN_BIN}" status --json 2>/dev/null < /dev/null || true)
  [ -n "${status_json}" ] || return 0
  printf '%s' "${status_json}" | node -e '
let text = ""
process.stdin.on("data", chunk => { text += chunk })
process.stdin.on("end", () => {
  try {
    const status = JSON.parse(text)
    if (status && status.plugin && typeof status.plugin.version === "string" && typeof status.plugin.packageSha256 === "string") {
      process.stdout.write(status.plugin.version + " " + status.plugin.packageSha256)
    }
  } catch {}
})
' 2>/dev/null || true
}

# ------------------------------------------------------ load/reload planning
profile_patch_reload() {
  manifest=${PROFILE_DIR}/package.json
  [ -f "${manifest}" ] || return 0
  node -e 'try { const p = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(p?.dsh?.profile?.patchReload ?? "")) } catch {}' "${manifest}" 2>/dev/null < /dev/null || true
}

plugin_ready() {
  [ -f "${DSH_HOME}/pclink/admin.json" ] || return 1
  [ -x "${PLUGIN_BIN}" ] || return 1
  "${PLUGIN_BIN}" status >/dev/null 2>&1 < /dev/null
}

wait_for_plugin() {
  limit=$1
  waited=0
  while [ "${waited}" -lt "${limit}" ]; do
    if plugin_ready; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# Wait until the running process reports the exact new build, not merely an
# open admin port (§8.2 plugin facts).
wait_for_plugin_build() {
  limit=$1
  want_version=$2
  want_sha=$3
  waited=0
  last='(no status)'
  while [ "${waited}" -lt "${limit}" ]; do
    facts=$(running_facts || true)
    if [ -n "${facts}" ]; then
      last=${facts}
      got_version=${facts%% *}
      got_sha=${facts#* }
      if [ "${got_version}" = "${want_version}" ] && { [ "${want_sha}" = 'unknown' ] || [ "${got_sha}" = "${want_sha}" ]; }; then
        return 0
      fi
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf '      运行中的插件仍是：%s；期望：%s %s\n' "${last}" "${want_version}" "${want_sha}" >&2
  return 1
}

service_kind() {
  if command -v launchctl >/dev/null 2>&1 && launchctl print "gui/$(id -u)/${LAUNCHD_LABEL}" >/dev/null 2>&1 < /dev/null; then
    printf 'launchd'
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user list-unit-files --no-legend 2>/dev/null < /dev/null | grep -q '^ai\.deepseek\.dsh\.service'; then
      printf 'systemd-ai'
      return 0
    fi
    if systemctl --user list-unit-files --no-legend 2>/dev/null < /dev/null | grep -q '^dsh\.service'; then
      printf 'systemd-dsh'
      return 0
    fi
  fi
  printf 'none'
}

launchd_command() {
  printf 'launchctl kickstart -k gui/%s/%s' "$(id -u)" "${LAUNCHD_LABEL}"
}

systemd_command() {
  if [ "$1" = 'systemd-ai' ]; then
    printf 'systemctl --user restart ai.deepseek.dsh.service'
  else
    printf 'systemctl --user restart dsh.service'
  fi
}

foreground_command() {
  printf '%s web --no-open' "${DSH}"
}

print_restart_command() {
  kind=$1
  case "${kind}" in
    launchd)
      info "        launchd：  $(launchd_command)"
      ;;
    systemd-ai)
      info "        systemd：  $(systemd_command 'systemd-ai')"
      ;;
    systemd-dsh)
      info "        systemd：  $(systemd_command 'systemd-dsh')"
      ;;
    *)
      info "        前台：     在运行 dsh web 的终端按 Ctrl-C，然后重新运行：$(foreground_command)"
      info "                    （请确认该终端的 DSH_HOME 与本次一致：${DSH_HOME}）"
      ;;
  esac
}

wait_after_manual_restart() {
  kind=$1
  print_restart_command "${kind}"
  ask '重启完成后按 Enter 继续校验运行中的版本（输入 q 退出）：'
  case "${REPLY}" in
    q|Q|quit|QUIT) die '已退出；重启 dsh web 后重新运行这条安装命令即可。' ;;
  esac
  info '      等待新版本就绪…'
  wait_for_plugin_build 120 "${NEW_VERSION}" "${NEW_SHA}" || die "运行中的插件没有加载新版本 ${NEW_VERSION}。请确认 dsh web 使用的是 ${DSH_HOME}，并查看它的日志。"
  info '      运行中的插件已是新版本。'
}

restart_now() {
  kind=$1
  case "${kind}" in
    launchd)
      launchctl kickstart -k "gui/$(id -u)/${LAUNCHD_LABEL}"
      ;;
    systemd-ai)
      systemctl --user restart ai.deepseek.dsh.service
      ;;
    systemd-dsh)
      systemctl --user restart dsh.service
      ;;
    *)
      return 1
      ;;
  esac
}

# ----------------------------------------------------------- before install
PLUGIN_WAS_READY=0
if plugin_ready; then
  PLUGIN_WAS_READY=1
fi

BEFORE_DISK=$(disk_facts)
BEFORE_VERSION=${BEFORE_DISK%% *}
BEFORE_SHA=${BEFORE_DISK#* }

RUNNING_FACTS=''
if [ "${PLUGIN_WAS_READY}" -eq 1 ]; then
  RUNNING_FACTS=$(running_facts || true)
fi
RUNNING_VERSION='unknown'
RUNNING_SHA='unknown'
if [ -n "${RUNNING_FACTS}" ]; then
  RUNNING_VERSION=${RUNNING_FACTS%% *}
  RUNNING_SHA=${RUNNING_FACTS#* }
fi

# -------------------------------------------------------------- plugin add
info ''
info '[2/4] 安装/更新 PCLink 插件'
info "      profile：${PROFILE_DIR}"
info "      spec：   ${PLUGIN_SPEC}"
if ! "${DSH}" plugin --profile "${PROFILE_NAME}" add "${PLUGIN_SPEC}" < /dev/tty; then
  die "dsh plugin add 失败。请查看上面的 pnpm 输出；如果提示构建脚本审批，请按提示同意后重新运行这条安装命令。"
fi

# ------------------------------------------------------------- hot / restart
# Read the manifest after the add: the command may have created the profile,
# and a declared `startup` reload policy must be honored.
RELOAD_MODE=$(profile_patch_reload)
case "${RELOAD_MODE}" in
  live|startup) ;;
  *) RELOAD_MODE=unknown ;;
esac
HOT_RELOAD=1
case "${RELOAD_MODE}" in
  startup) HOT_RELOAD=0 ;;
esac

AFTER_DISK=$(disk_facts)
NEW_VERSION=${AFTER_DISK%% *}
NEW_SHA=${AFTER_DISK#* }

RESTART_REQUIRED=0
if [ "${PLUGIN_WAS_READY}" -eq 1 ]; then
  if [ "${BEFORE_VERSION}" != "${NEW_VERSION}" ] || [ "${BEFORE_SHA}" != "${NEW_SHA}" ]; then
    RESTART_REQUIRED=1
  fi
  # A pre-v1.6 process has no admin `plugin` facts; an on-disk comparison
  # cannot prove what it loaded, so treat it as requiring a restart.
  if [ -z "${RUNNING_FACTS}" ]; then
    RESTART_REQUIRED=1
  elif [ "${RUNNING_VERSION}" != "${NEW_VERSION}" ] || [ "${RUNNING_SHA}" != "${NEW_SHA}" ]; then
    RESTART_REQUIRED=1
  fi
fi

if [ "${PLUGIN_WAS_READY}" -eq 1 ] && [ "${RESTART_REQUIRED}" -eq 1 ]; then
  info ''
  info '[3/4] 检测到插件已升级：运行中的 dsh web 仍加载旧代码。'
  info "      升级前运行中：${RUNNING_VERSION} sha256=${RUNNING_SHA}"
  info "      升级后磁盘上：${NEW_VERSION} sha256=${NEW_SHA}"
  if [ "${RUNNING_VERSION}" = 'unknown' ]; then
    info '      （旧版插件没有报告构建信息，无法证明它已是新版本；需要重启。）'
  fi
  kind=$(service_kind)
  RESTART_DONE=0
  if [ "${kind}" != 'none' ]; then
    ask '需要重启 dsh web 以加载新版本，现在重启？[Y/n] '
    case "${REPLY}" in
      n|N|no|NO|No) ;;
      *)
        info "      重启 dsh web（${kind}）…"
        if ! restart_now "${kind}"; then
          print_restart_command "${kind}" >&2
          die "重启 dsh web 失败（${kind}）。请按上面的命令手动重启。"
        fi
        RESTART_DONE=1
        ;;
    esac
  fi
  if [ "${RESTART_DONE}" -eq 1 ]; then
    info '      等待新版本被加载…'
    wait_for_plugin_build 120 "${NEW_VERSION}" "${NEW_SHA}" || die "dsh web 已重启，但运行中的插件不是 ${NEW_VERSION}。请查看 dsh web 日志。"
    info '      运行中的插件已是新版本。'
  else
    wait_after_manual_restart "${kind}"
  fi
elif [ "${PLUGIN_WAS_READY}" -eq 1 ]; then
  info ''
  info '[3/4] 插件已在运行且构建未变化；校验 admin API。'
  if wait_for_plugin 15; then
    info '      插件仍健康。'
  else
    die '插件在升级后没有恢复 admin API。请查看 dsh web 日志后重试。'
  fi
elif [ "${HOT_RELOAD}" -eq 1 ]; then
  info ''
  info '[3/4] 等待 dsh web 热加载插件…'
  if [ "${RELOAD_MODE}" = 'live' ]; then
    info '      profile patchReload=live。'
  else
    info '      profile 未声明 patchReload；先按 web profile 的热加载行为等待。'
  fi
  if wait_for_plugin 25; then
    info '      插件已热加载，无需重启 dsh web。'
    facts=$(running_facts || true)
    if [ -n "${facts}" ]; then
      got_version=${facts%% *}
      got_sha=${facts#* }
      if [ "${got_version}" != "${NEW_VERSION}" ] || { [ "${NEW_SHA}" != 'unknown' ] && [ "${got_sha}" != "${NEW_SHA}" ]; }; then
        die "热加载后的插件版本 ${got_version}（${got_sha}）与磁盘上的 ${NEW_VERSION}（${NEW_SHA}）不一致。请重启 dsh web。"
      fi
    fi
  else
    HOT_RELOAD=0
  fi
fi

if [ "${PLUGIN_WAS_READY}" -eq 0 ] && [ "${HOT_RELOAD}" -eq 0 ]; then
  info ''
  info '[3/4] 插件没有自动加载；此环境需要重启 dsh web。'
  kind=$(service_kind)
  wait_after_manual_restart "${kind}"
fi

if [ ! -x "${PLUGIN_BIN}" ]; then
  # Some package managers link the bin differently; fall back to the package
  # entry point under the profile (never a hard-coded ~/.dsh path).
  PACKAGE_CLI=${PACKAGE_DIR}/cli/bin.mjs
  [ -f "${PACKAGE_CLI}" ] || die "插件已安装，但在 ${PLUGIN_BIN} 找不到 pclink。请检查上面的 dsh plugin 输出。"
  set -- node "${PACKAGE_CLI}" pair
else
  set -- "${PLUGIN_BIN}" pair
fi

# ----------------------------------------------------------------------- pair
info ''
info '[4/4] 打开配对二维码（手机扫码即完成配对，不需要在电脑上输入指纹）'
if "$@" < /dev/null > /dev/tty 2>&1; then
  info ''
  info '安装与配对完成。以后可以直接运行上面 profile 里的 pclink pair 重新配对。'
else
  pair_status=$?
  die "配对未完成（退出码 ${pair_status}）。可以重新运行同一条安装命令，或直接运行 '${PLUGIN_BIN} pair' 重试。"
fi
