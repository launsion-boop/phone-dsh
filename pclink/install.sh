#!/bin/sh
# PCLink v1 one-command installer (macOS / Linux).
#
# Intended entry point:
#   curl -fsSL https://raw.githubusercontent.com/launsion-boop/phone-dsh/main/pclink/install.sh | bash
#
# When stdin is the curl pipe, every interactive prompt is read from /dev/tty.
# There is no non-interactive approval path: the operator must type the
# fingerprint shown on the phone, exactly like `pclink pair`.
#
# Environment (all optional):
#   PCLINK_REF          git ref in the default GitHub spec (default: main)
#   PCLINK_PLUGIN_SPEC  full `dsh plugin add` package spec (mirror/self-hosted/local test)
#   PCLINK_RELAY_URL    relay override read by the plugin process (default: hosted relay)
#   DSH_BIN             dsh executable when it is not on PATH
#   DSH_HOME            DSH home (default: $HOME/.dsh)
#
# The script is POSIX sh; it is normally executed by bash from the URL above.

set -eu

DEFAULT_RELAY='https://pclink.tonoai.cn'
PROFILE_NAME='web'

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
  if [ "$status" -ne 0 ]; then
    printf '\n安装未完成（退出码 %s）。可以重新运行同一条命令；已完成的步骤会自动跳过或升级。\n' "$status" >&2
  fi
}
trap cleanup EXIT

# ------------------------------------------------------------------ platform
uname_s=$(uname -s 2>/dev/null || printf 'unknown')
case "$uname_s" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    die 'Windows 不在 PCLink v1 范围内。请在 macOS 或 Linux 上运行这条命令。'
    ;;
  Darwin|Linux)
    ;;
  *)
    warn "未在 $uname_s 上验证过；脚本会继续，但失败时请改用 macOS 或 Linux。"
    ;;
esac

# ----------------------------------------------------------------------- TTY
# `curl | bash` makes stdin the script pipe. Open the controlling terminal
# once and use fd 3 for every question. A process without a controlling
# terminal cannot approve a pairing and must fail before opening a slot.
if ! { : </dev/tty; } 2>/dev/null; then
  die '安装与配对需要终端（TTY）：请在终端里运行这条命令，不要接管道重定向或放到 CI。配对批准必须由你在终端输入手机屏幕上显示的指纹，脚本不会自动批准。'
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

ask_yes_no() {
  ask "$1 [y/N] "
  case "$REPLY" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------- Node
info '[1/4] 检查环境'
command -v node >/dev/null 2>&1 || die '找不到 Node.js。PCLink 需要 Node.js 22 或更新版本；请安装后重试。'
node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null < /dev/null || printf '')
case "$node_major" in
  ''|*[!0-9]*) die '无法读取 Node.js 版本（node -p 失败）。请确认 Node.js 22+ 已正确安装。' ;;
esac
if [ "$node_major" -lt 22 ]; then
  node_version=$(node -p 'process.versions.node' 2>/dev/null < /dev/null || printf 'unknown')
  die "Node.js $node_version 过旧：需要 Node.js 22 或更新版本。"
fi
info "      Node.js $(node -p 'process.versions.node' 2>/dev/null < /dev/null || printf 'unknown')"

if ! command -v pnpm >/dev/null 2>&1; then
  die "找不到 pnpm：dsh plugin 通过 pnpm 安装插件。请先安装 pnpm（例如 'corepack enable' 后 'corepack prepare pnpm@latest --activate'），再重试。"
fi

# ----------------------------------------------------------------------- dsh
if [ -n "${DSH_BIN:-}" ]; then
  [ -x "$DSH_BIN" ] || die "DSH_BIN 指向的文件不可执行：$DSH_BIN"
  DSH=$DSH_BIN
else
  DSH=$(command -v dsh 2>/dev/null || true)
  [ -n "$DSH" ] || die "找不到 dsh：请把 dsh 放到 PATH，或设置 DSH_BIN=/path/to/dsh。"
fi
[ -x "$DSH" ] || die "dsh 不可执行：$DSH"

dsh_version_raw=$("$DSH" -V 2>&1 < /dev/null) || die "运行 dsh -V 失败：$dsh_version_raw"
DSH_VERSION=$(printf '%s\n' "$dsh_version_raw" | sed -n '1p' | tr -d '\r')
info "      dsh $DSH_VERSION ($DSH)"
info "      pnpm $(pnpm --version 2>/dev/null < /dev/null || printf 'unknown')"

# `>=0.2.2-rc.1 <0.3.0`: 0.2.2 release and any later 0.2.x pass. A 0.2.2
# prerelease passes only at rc.1 or later.
version_in_range() {
  version=$1
  version=${version#v}
  [ -n "$version" ] || return 1
  case "$version" in
    *[!0-9A-Za-z.+-]*) return 1 ;;
  esac
  numeric=${version%%-*}
  prerelease=''
  case "$version" in
    *-*) prerelease=${version#*-} ;;
  esac
  major=${numeric%%.*}
  rest=${numeric#*.}
  minor=${rest%%.*}
  patch=${rest#*.}
  case "$major$minor$patch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$major" -eq 0 ] && [ "$minor" -eq 2 ] || return 1
  if [ "$patch" -gt 2 ]; then
    return 0
  fi
  if [ "$patch" -lt 2 ]; then
    return 1
  fi
  [ -z "$prerelease" ] && return 0
  case "$prerelease" in
    rc.*)
      rc_number=${prerelease#rc.}
      case "$rc_number" in
        ''|*[!0-9]*) return 1 ;;
      esac
      [ "$rc_number" -ge 1 ] && return 0
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

if ! version_in_range "$DSH_VERSION"; then
  warn "dsh $DSH_VERSION 不在已验证范围 >=0.2.2-rc.1 <0.3.0 内。"
  ask_yes_no '仍要继续安装吗？' || die '已取消：请先把 dsh 升级到 0.2.2 或更新版本。'
fi

# ------------------------------------------------------------------ DSH home
[ -n "${HOME:-}" ] || die 'HOME 未设置；请设置 HOME 或 DSH_HOME 后再运行。'
if [ -n "${DSH_HOME:-}" ]; then
  case "$DSH_HOME" in
    /*) ;;
    *) die "DSH_HOME 必须是绝对路径：$DSH_HOME" ;;
  esac
else
  DSH_HOME=$HOME/.dsh
fi
PROFILE_DIR=$DSH_HOME/profiles/$PROFILE_NAME
PLUGIN_BIN=$PROFILE_DIR/node_modules/.bin/pclink

# ------------------------------------------------------------------- spec
if [ -n "${PCLINK_PLUGIN_SPEC:-}" ]; then
  PLUGIN_SPEC=$PCLINK_PLUGIN_SPEC
  info '      插件来源：PCLINK_PLUGIN_SPEC'
else
  PLUGIN_SPEC="github:launsion-boop/phone-dsh#${PCLINK_REF:-main}&path:/pclink"
  info "      插件来源：$PLUGIN_SPEC"
fi
if [ -n "${PCLINK_RELAY_URL:-}" ]; then
  info "      中继：$PCLINK_RELAY_URL（PCLINK_RELAY_URL）"
else
  info "      中继：$DEFAULT_RELAY（默认）"
fi

# ------------------------------------------------------ load/reload planning
profile_patch_reload() {
  manifest=$PROFILE_DIR/package.json
  [ -f "$manifest" ] || return 0
  node -e 'try { const p = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(p?.dsh?.profile?.patchReload ?? "")) } catch {}' "$manifest" 2>/dev/null < /dev/null || true
}

plugin_ready() {
  [ -f "$DSH_HOME/pclink/admin.json" ] || return 1
  [ -x "$PLUGIN_BIN" ] || return 1
  "$PLUGIN_BIN" status >/dev/null 2>&1 < /dev/null
}

wait_for_plugin() {
  limit=$1
  waited=0
  while [ "$waited" -lt "$limit" ]; do
    if plugin_ready; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

PLUGIN_WAS_READY=0
if plugin_ready; then
  PLUGIN_WAS_READY=1
fi

# -------------------------------------------------------------- plugin add
info ''
info '[2/4] 安装/更新 PCLink 插件'
info "      profile：$PROFILE_DIR"
info "      spec：   $PLUGIN_SPEC"
if ! "$DSH" plugin --profile "$PROFILE_NAME" add "$PLUGIN_SPEC" < /dev/tty; then
  die "dsh plugin add 失败。请查看上面的 pnpm 输出；如果提示构建脚本审批，请按提示同意后重新运行这条安装命令。"
fi

# ------------------------------------------------------------- hot / restart
# Read the manifest after the add: the command may have created the profile,
# and a declared `startup` reload policy must be honored.
RELOAD_MODE=$(profile_patch_reload)
case "$RELOAD_MODE" in
  live|startup) ;;
  *) RELOAD_MODE=unknown ;;
esac
HOT_RELOAD=1
case "$RELOAD_MODE" in
  startup) HOT_RELOAD=0 ;;
esac

if [ "$PLUGIN_WAS_READY" -eq 1 ]; then
  info ''
  info '[3/4] 插件此前已在运行；本次只做升级/幂等校验，不重启 dsh web。'
elif [ "$HOT_RELOAD" -eq 1 ]; then
  info ''
  info '[3/4] 等待 dsh web 热加载插件…'
  if [ "$RELOAD_MODE" = 'live' ]; then
    info '      profile patchReload=live。'
  else
    info '      profile 未声明 patchReload；先按 web profile 的热加载行为等待。'
  fi
  if wait_for_plugin 25; then
    info '      插件已热加载，无需重启 dsh web。'
  else
    HOT_RELOAD=0
  fi
fi

if [ "$PLUGIN_WAS_READY" -eq 0 ] && [ "$HOT_RELOAD" -eq 0 ]; then
  info ''
  info '[3/4] 插件没有自动加载；此环境需要重启 dsh web。'
  info '      请在另一个终端按你的运行方式重启（执行前请确认 DSH_HOME 与本次一致）：'
  if command -v launchctl >/dev/null 2>&1 && launchctl print "gui/$(id -u)/ai.deepseek.dsh" >/dev/null 2>&1 < /dev/null; then
    info "        launchd：  launchctl kickstart -k gui/$(id -u)/ai.deepseek.dsh"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user list-unit-files --no-legend 2>/dev/null < /dev/null | grep -q '^ai\.deepseek\.dsh\.service'; then
      info '        systemd：  systemctl --user restart ai.deepseek.dsh.service'
    elif systemctl --user list-unit-files --no-legend 2>/dev/null < /dev/null | grep -q '^dsh\.service'; then
      info '        systemd：  systemctl --user restart dsh.service'
    fi
  fi
  info '        前台：     在运行 dsh web 的终端按 Ctrl-C，然后重新运行 dsh web --no-open'
  ask '重启完成后按 Enter 继续等待插件（输入 q 退出）：'
  case "$REPLY" in
    q|Q|quit|QUIT) die '已退出；重启 dsh web 后重新运行这条安装命令即可。' ;;
  esac
  info '      等待插件就绪…'
  wait_for_plugin 120 || die "插件仍未就绪。请确认 dsh web 已使用 $DSH_HOME 启动，并查看它的日志。"
  info '      插件已就绪。'
elif [ "$PLUGIN_WAS_READY" -eq 1 ]; then
  # The running plugin is already healthy. `dsh plugin add` may hot-upgrade it
  # in place; wait for the admin API so a reload/restart window cannot race the
  # pairing command.
  if wait_for_plugin 15; then
    info '      插件仍健康。'
  else
    die '插件在升级后没有恢复 admin API。请查看 dsh web 日志后重试。'
  fi
fi

if [ ! -x "$PLUGIN_BIN" ]; then
  # Some package managers link the bin differently; fall back to the package
  # entry point under the profile (never a hard-coded ~/.dsh path).
  PACKAGE_CLI=$PROFILE_DIR/node_modules/dsh-pclink/cli/bin.mjs
  [ -f "$PACKAGE_CLI" ] || die "插件已安装，但在 $PLUGIN_BIN 找不到 pclink。请检查上面的 dsh plugin 输出。"
  set -- node "$PACKAGE_CLI" pair
else
  set -- "$PLUGIN_BIN" pair
fi

# ----------------------------------------------------------------------- pair
info ''
info '[4/4] 打开配对二维码'
info '      扫码后，在手机配对页读取它显示的 12 位指纹并输入到这里；'
info '      这里的输入只从终端读取，脚本不会自动批准。'
if "$@" < /dev/tty > /dev/tty 2>&1; then
  info ''
  info '安装与配对完成。以后可以直接运行上面 profile 里的 pclink pair 重新配对。'
else
  pair_status=$?
  die "配对未完成（退出码 $pair_status）。可以重新运行同一条安装命令，或直接运行 '$PLUGIN_BIN pair' 重试。"
fi
