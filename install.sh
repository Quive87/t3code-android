#!/data/data/com.termux/files/usr/bin/bash
# T3 Code for Android
# ===================
# Installs and runs the newest nightly T3 Code server on an Android tablet or
# phone, inside Termux and a Debian userland (proot-distro), together with the
# agent CLIs T3 Code drives (Claude Code, Codex, Grok, OpenCode, ...), and keeps
# all of it up to date. Use it from the T3 Code Android app or from Chrome.
#
#   curl -fsSL https://raw.githubusercontent.com/Quive87/t3code-android/main/install.sh | bash
#
# Running it again repairs the install and updates everything. Afterwards use
# the `t3code` command (`t3code help`).
#
# Settings (environment variables; remembered for later runs):
#   T3A_PROVIDERS  agent CLIs to install, comma separated:
#                  claude,codex,grok,opencode,gemini,pi (default: the first four; "none")
#   T3A_PORT       server port (default 3773)
#   T3A_NO_START   1 = install everything but don't start the server

set -Eeuo pipefail

T3A_VERSION="1.0.0"
T3A_INSTALL_URL_DEFAULT="https://raw.githubusercontent.com/Quive87/t3code-android/main/install.sh"

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
CONTAINER="t3code"
DEBIAN_IMAGE="debian:trixie"
GUSER="t3"
GHOME="/home/t3"
CONF_DIR="$HOME/.config/t3code-android"
STATE_DIR="$HOME/.local/state/t3code-android"
CONFIG="$CONF_DIR/config"
INSTALL_LOG="$STATE_DIR/install.log"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m' D=$'\033[2m' G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' C=$'\033[36m' N=$'\033[0m'
else
  B="" D="" G="" Y="" R="" C="" N=""
fi
step() { printf '\n%s==>%s %s%s%s\n' "$C" "$N" "$B" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s  ! %s%s\n' "$Y" "$*" "$N" >&2; }
die() { printf '\n%st3code-android: %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

on_error() {
  local code=$?
  printf '\n%sInstallation failed (exit %s) while running: %s%s\n' "$R" "$code" "${BASH_COMMAND:-?}" "$N" >&2
  printf 'The full log is in %s\n' "$INSTALL_LOG" >&2
  printf 'Fix the problem above, then run the same install command again; it picks up where it stopped.\n' >&2
  exit "$code"
}

# ---------------------------------------------------------------------------
# Files placed inside the Debian container
# ---------------------------------------------------------------------------

write_guest_files() {
  local root=$1 lib="$1/usr/local/lib/t3code-android" bin="$1/usr/local/bin"
  mkdir -p "$lib" "$bin" "$1/etc/apt/apt.conf.d"

  # apt cannot switch to its _apt sandbox user under proot.
  printf 'APT::Sandbox::User "root";\n' > "$1/etc/apt/apt.conf.d/99t3code-android"

  cat > "$lib/env.sh" <<'__T3A_ENV__'
# shellcheck shell=bash
# Environment for the T3 Code server and every agent it starts. Sourced by the
# t3code helpers and by interactive shells of the t3 user.
export HOME=/home/t3 USER=t3 LOGNAME=t3 SHELL=/bin/bash
export T3CODE_HOME="$HOME/.t3"
export LANG=en_US.UTF-8
export TMPDIR=/tmp
# CLIs that open a browser (logins, previews) use Android's browser instead.
export BROWSER=/usr/local/bin/xdg-open
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.grok/bin:$HOME/.opencode/bin:$HOME/.bun/bin:$HOME/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/data/data/com.termux/files/usr/bin"
# Your own variables (API keys, proxies, ...) as KEY=value lines:
if [ -f "$HOME/.config/t3code-android/env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$HOME/.config/t3code-android/env"
  set +a
fi
__T3A_ENV__

  cat > "$bin/t3code-guest-env" <<'__T3A_GUEST_ENV__'
#!/bin/bash
# Runs a command (default: a login shell) as the t3 user's T3 Code environment.
. /usr/local/lib/t3code-android/env.sh
cd "$HOME" 2>/dev/null || cd /
[ "$#" -gt 0 ] || exec /bin/bash -l
exec "$@"
__T3A_GUEST_ENV__

  cat > "$bin/xdg-open" <<'__T3A_XDG__'
#!/bin/sh
# Opens URLs and files with Android apps through Termux.
termux_bin=/data/data/com.termux/files/usr/bin
case "${1:-}" in
  "") echo "usage: xdg-open URL|FILE" >&2; exit 1 ;;
  *://*|mailto:*|intent:*) exec "$termux_bin/termux-open-url" "$1" ;;
  *) exec "$termux_bin/termux-open" "$1" ;;
esac
__T3A_XDG__

  cat > "$bin/t3code-guest-run" <<'__T3A_RUN__'
#!/bin/bash
# Started by the t3code supervisor in Termux. Runs T3 Code's own service
# launcher (`t3 __service-launcher`) for the active version, exactly like the
# systemd service on Linux, so "Update server" in the apps works here too.
set -u
. /usr/local/lib/t3code-android/env.sh
cd "$HOME" || exit 1
runtime=$(/usr/local/bin/t3code-guest-update prepare-launch) || exit 1
mkdir -p "$T3CODE_HOME/runtime"
echo "$$" > "$T3CODE_HOME/runtime/android-launcher.pid"
if [ -f "$T3CODE_HOME/runtime/android-plain-serve" ]; then
  # Fallback when the launcher cannot run this version: no in-app updates.
  exec "$runtime" serve --host 127.0.0.1
fi
exec "$runtime" __service-launcher
__T3A_RUN__

  cat > "$bin/t3code-guest-update" <<'__T3A_UPDATE__'
#!/bin/bash
# Installs, activates and rolls back T3 Code runtimes for the Android service.
# Uses the same layout as T3 Code's installer and service:
#   $T3CODE_HOME/runtime/versions/<version>/t3   (+ .install-complete)
#   $T3CODE_HOME/runtime/service-state.json      (read by `t3 __service-launcher`)
#
#   t3code-guest-update latest            newest version on the channel
#   t3code-guest-update active            version the service runs
#   t3code-guest-update check             exit 0 when a newer, not-blocked version exists
#   t3code-guest-update ensure            make sure some version is installed and active
#   t3code-guest-update apply [V|--auto]  install V (default newest) and make it active
#   t3code-guest-update commit            the active version ran fine; drop the rollback backup
#   t3code-guest-update rollback [--if-uncommitted]  return to the version before the last apply
#   t3code-guest-update prepare-launch    validate state, print the runtime to launch
#   t3code-guest-update status            summary
set -Eeuo pipefail
. /usr/local/lib/t3code-android/env.sh

REPO=pingdotgg/t3code
BASE_URL=${T3CODE_RELEASE_BASE_URL:-https://github.com/$REPO/releases/download}
CHANNEL=${T3A_CHANNEL:-nightly}
RUNTIME=$T3CODE_HOME/runtime
VERSIONS=$RUNTIME/versions
STATE=$RUNTIME/service-state.json
BACKUP=$RUNTIME/android-backup
BLOCKED=$RUNTIME/android-blocked-versions
LIB=/usr/local/lib/t3code-android

log() { printf '[t3code-update] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

case "$(uname -m)" in
  aarch64 | arm64) ARCH=arm64 ;;
  x86_64 | amd64) ARCH=x64 ;;
  *) die "T3 Code has no Linux build for $(uname -m)" ;;
esac

mkdir -p "$VERSIONS"

is_complete() { [ -f "$VERSIONS/$1/t3" ] && [ "$(cat "$VERSIONS/$1/.install-complete" 2>/dev/null)" = "$1" ]; }
active_version() { jq -r '.activeVersion // empty' "$STATE" 2>/dev/null || true; }
has_pending_update() { jq -e '.update.status == "pending"' "$STATE" >/dev/null 2>&1; }
is_blocked() { grep -qxF "$1" "$BLOCKED" 2>/dev/null; }
newer() { node "$LIB/semver.js" newer "$1" "$2"; }

installed_versions() {
  local d v
  for d in "$VERSIONS"/*/; do
    v=$(basename "$d")
    if is_complete "$v"; then printf '%s\n' "$v"; fi
  done | node "$LIB/semver.js" sort
}

latest_version() {
  local v=""
  # npm is where T3 Code itself looks for server updates.
  v=$(curl -fsSL --retry 2 -m 30 https://registry.npmjs.org/-/package/t3/dist-tags 2>/dev/null |
    jq -r --arg c "$CHANNEL" 'if $c == "stable" then .latest else .[$c] end // empty' 2>/dev/null) || v=""
  if [ -z "$v" ]; then
    v=$(curl -fsSL --retry 2 -m 30 "https://api.github.com/repos/$REPO/releases?per_page=100" 2>/dev/null |
      jq -r --arg c "$CHANNEL" '
        [ .[] | select(.draft | not) | .tag_name
          | select(test(if $c == "stable" then "^v[0-9]+\\.[0-9]+\\.[0-9]+$"
                        else "^v[0-9]+\\.[0-9]+\\.[0-9]+-" + $c + "\\.[0-9]+\\.[0-9]+$" end)) ][0]
        // empty | ltrimstr("v")' 2>/dev/null) || v=""
  fi
  [ -n "$v" ] || die "could not look up the newest $CHANNEL release (offline?)"
  printf '%s\n' "$v"
}

page_size() { getconf PAGESIZE 2>/dev/null || echo 4096; }

install_version() {
  local v=$1 stage archive expected actual
  is_complete "$v" && return 0
  archive="t3-$v-linux-$ARCH.tar.gz"
  stage=$(mktemp -d "$VERSIONS/.staging-XXXXXX")
  chmod 755 "$stage"
  log "downloading T3 Code $v"
  if ! curl -fSL --retry 3 --progress-bar -o "$stage/$archive" "$BASE_URL/v$v/$archive" ||
    ! curl -fsSL --retry 3 -o "$stage/SHA256SUMS" "$BASE_URL/v$v/SHA256SUMS"; then
    rm -rf "$stage"
    die "download of T3 Code $v failed"
  fi
  expected=$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1 }' "$stage/SHA256SUMS")
  actual=$(sha256sum "$stage/$archive" | cut -d' ' -f1)
  if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
    rm -rf "$stage"
    die "checksum mismatch for $archive"
  fi
  tar -xzf "$stage/$archive" -C "$stage" --strip-components=1
  rm -f "$stage/$archive" "$stage/SHA256SUMS"
  if [ "$(page_size)" -gt 4096 ]; then
    # Node single-executable apps carry one 4 KB-aligned segment; realign it.
    node "$LIB/fix-elf-align.js" "$stage/t3" "$(page_size)" >&2 || true
  fi
  if ! "$stage/t3" --version >/dev/null 2>&1; then
    rm -rf "$stage"
    die "T3 Code $v does not start on this device (run: t3code doctor)"
  fi
  printf '%s\n' "$v" > "$stage/.install-complete"
  rm -rf "${VERSIONS:?}/$v"
  mv "$stage" "$VERSIONS/$v"
  log "installed T3 Code $v"
}

# The protocol between `t3 __service-launcher` and its server; asked of the runtime.
launcher_protocol() {
  local rt=$1 out p
  out=$("$rt" __service-preflight --database-path "$T3CODE_HOME/userdata/statev2.sqlite" --launcher-protocol 3 2>/dev/null | tail -n1) || out=""
  p=$(printf '%s' "$out" | jq -r 'if .status == "ready" then .launcherProtocol else empty end' 2>/dev/null) || p=""
  [ -n "$p" ] || p=$(printf '%s' "$out" | grep -oE 'requires protocol [0-9]+' | grep -oE '[0-9]+$' || true)
  printf '%s\n' "${p:-3}"
}

write_state() {
  local v=$1 proto tmp
  proto=$(launcher_protocol "$VERSIONS/$v/t3")
  tmp=$(mktemp "$RUNTIME/.service-state.XXXXXX")
  printf '{\n  "protocol": %s,\n  "activeVersion": "%s"\n}\n' "$proto" "$v" > "$tmp"
  mv -f "$tmp" "$STATE"
}

point_t3_command() {
  local v=$1 target launcher
  mkdir -p "$HOME/.local/bin"
  target="$VERSIONS/$v/t3"
  ln -sfn "$target" "$HOME/.local/bin/t3"
  launcher="$HOME/.local/bin/t3"
  grep -qxF "$launcher" "$RUNTIME/launchers" 2>/dev/null || printf '%s\n' "$launcher" >> "$RUNTIME/launchers"
}

backup_databases() {
  local from=$1 to=$2 f
  rm -rf "$BACKUP"
  mkdir -p "$BACKUP/files"
  printf '%s\n%s\n' "$from" "$to" > "$BACKUP/versions"
  for f in "$T3CODE_HOME"/userdata/*.sqlite "$T3CODE_HOME"/userdata/*.sqlite-wal "$T3CODE_HOME"/userdata/*.sqlite-shm; do
    [ -f "$f" ] && cp -p "$f" "$BACKUP/files/"
  done
  # T3 Code prunes runtimes nothing points at when it starts; a recorded launcher
  # link keeps the previous version around until the new one has proven itself.
  ln -sfn "$VERSIONS/$from/t3" "$RUNTIME/android-previous-t3"
  grep -qxF "$RUNTIME/android-previous-t3" "$RUNTIME/launchers" 2>/dev/null ||
    printf '%s\n' "$RUNTIME/android-previous-t3" >> "$RUNTIME/launchers"
  return 0
}

forget_backup() {
  rm -rf "$BACKUP"
  rm -f "$RUNTIME/android-previous-t3"
}

activate() {
  local v=$1 current
  current=$(active_version)
  if has_pending_update; then
    log "an in-app server update is still pending; leaving it to the launcher"
    return 0
  fi
  if [ -n "$current" ] && [ "$current" != "$v" ] && is_complete "$current"; then
    backup_databases "$current" "$v"
  fi
  write_state "$v"
  rm -f "$RUNTIME/android-plain-serve"
  point_t3_command "$v"
}

cmd_apply() {
  local v="${1:-}" auto=0 current
  if [ "$v" = "--auto" ]; then auto=1; v=""; fi
  [ -n "$v" ] || v=$(latest_version)
  current=$(active_version)
  if [ "$auto" = 1 ]; then
    if [ -n "$current" ] && is_complete "$current" && ! newer "$v" "$current"; then return 0; fi
    if is_blocked "$v"; then log "skipping $v: it failed to start here before"; return 0; fi
  else
    sed -i "/^$(printf '%s' "$v" | sed 's/[.[\*^$/]/\\&/g')\$/d" "$BLOCKED" 2>/dev/null || true
  fi
  install_version "$v"
  [ "$current" = "$v" ] && is_complete "$current" && { point_t3_command "$v"; return 0; }
  activate "$v"
  log "T3 Code $v is active"
}

cmd_rollback() {
  local from to f
  [ -f "$BACKUP/versions" ] || die "nothing to roll back"
  from=$(sed -n 1p "$BACKUP/versions")
  to=$(sed -n 2p "$BACKUP/versions")
  # --if-uncommitted: only undo a switch that never ran healthy (the supervisor's crash-loop guard).
  if [ "${1:-}" = "--if-uncommitted" ] && [ "$to" != "$(active_version)" ]; then exit 1; fi
  is_complete "$from" || die "the previous version $from is no longer installed"
  log "rolling back from $to to $from"
  for f in "$T3CODE_HOME"/userdata/*.sqlite "$T3CODE_HOME"/userdata/*.sqlite-wal "$T3CODE_HOME"/userdata/*.sqlite-shm; do
    [ -f "$f" ] && rm -f "$f"
  done
  cp -p "$BACKUP/files/"* "$T3CODE_HOME/userdata/" 2>/dev/null || true
  printf '%s\n' "$to" >> "$BLOCKED"
  write_state "$from"
  point_t3_command "$from"
  forget_backup
}

cmd_ensure() {
  local v
  v=$(active_version)
  if [ -n "$v" ] && is_complete "$v"; then point_t3_command "$v"; return 0; fi
  v=$(installed_versions | tail -n1)
  if [ -z "$v" ]; then v=$(latest_version); install_version "$v"; fi
  write_state "$v"
  point_t3_command "$v"
}

cmd_prepare_launch() {
  local v proto rt
  if ! jq -e '.activeVersion' "$STATE" >/dev/null 2>&1 || ! is_complete "$(active_version)"; then
    has_pending_update || cmd_ensure >&2
  fi
  v=$(active_version)
  rt="$VERSIONS/$v/t3"
  [ -f "$rt" ] || die "no usable T3 Code runtime (run: t3code update)"
  # Keep the state's protocol in step with what this runtime's launcher speaks.
  if ! has_pending_update; then
    proto=$(launcher_protocol "$rt")
    if [ "$(jq -r '.protocol' "$STATE" 2>/dev/null)" != "$proto" ]; then write_state "$v"; fi
  fi
  printf '%s\n' "$rt"
}

cmd_check() {
  local latest current
  latest=$(latest_version)
  current=$(active_version)
  [ -n "$current" ] || return 0
  newer "$latest" "$current" && ! is_blocked "$latest"
}

cmd_status() {
  printf 'channel:   %s\n' "$CHANNEL"
  printf 'active:    %s\n' "$(active_version)"
  printf 'latest:    %s\n' "$(latest_version 2>/dev/null || echo unknown)"
  printf 'installed: %s\n' "$(installed_versions | tr '\n' ' ')"
  [ -f "$RUNTIME/android-plain-serve" ] && printf 'mode:      plain serve (in-app updates off)\n'
  return 0
}

case "${1:-status}" in
  latest) latest_version ;;
  active) active_version ;;
  check) cmd_check ;;
  ensure) cmd_ensure ;;
  apply) shift; cmd_apply "${1:-}" ;;
  rollback) shift; cmd_rollback "${1:-}" ;;
  commit) forget_backup ;;
  prepare-launch) cmd_prepare_launch ;;
  installed) installed_versions ;;
  status) cmd_status ;;
  *) die "unknown command: $1" ;;
esac
__T3A_UPDATE__

  cat > "$bin/t3code-guest-providers" <<'__T3A_PROVIDERS__'
#!/bin/bash
# Installs, updates and lists the agent CLIs that T3 Code drives.
#   t3code-guest-providers install claude,codex ...
#   t3code-guest-providers list
set -uo pipefail
. /usr/local/lib/t3code-android/env.sh
NPM=(npm install -g --no-fund --no-audit --loglevel=error)

install_one() {
  case "$1" in
    claude) curl -fsSL https://claude.ai/install.sh | bash ;;
    codex) "${NPM[@]}" @openai/codex@latest ;;
    grok) curl -fsSL https://x.ai/cli/install.sh | bash ;;
    opencode) "${NPM[@]}" @opencode/cli@latest ;;
    gemini) "${NPM[@]}" @google/gemini-cli@latest ;;
    pi) "${NPM[@]}" @mariozechner/pi-coding-agent@latest ;;
    none | "") return 0 ;;
    *) echo "unknown agent CLI: $1 (choose from claude, codex, grok, opencode, gemini, pi)" >&2; return 2 ;;
  esac
}

version_of() {
  local bin=$1
  command -v "$bin" >/dev/null 2>&1 || { echo "-"; return; }
  timeout 60 "$bin" --version 2>/dev/null | head -n1 || echo "installed"
}

case "${1:-list}" in
  install | update)
    shift
    failed=()
    for p in $(printf '%s ' "$@" | tr ',' ' '); do
      printf '\n--- %s\n' "$p"
      install_one "$p" || failed+=("$p")
    done
    if [ "${#failed[@]}" -gt 0 ]; then echo "Could not install: ${failed[*]}" >&2; exit 1; fi
    ;;
  list)
    printf '%-10s %s\n' claude "$(version_of claude)" codex "$(version_of codex)" grok "$(version_of grok)" \
      opencode "$(version_of opencode)" gemini "$(version_of gemini)" pi "$(version_of pi)" \
      node "$(node --version 2>/dev/null || echo -)" git "$(git --version 2>/dev/null | cut -d' ' -f3)" gh "$(gh --version 2>/dev/null | head -n1 | cut -d' ' -f3)"
    ;;
  *) echo "usage: t3code-guest-providers install NAMES | list" >&2; exit 2 ;;
esac
__T3A_PROVIDERS__

  cat > "$lib/semver.js" <<'__T3A_SEMVER__'
// Version ordering used by T3 Code's service launcher (semver with numeric prerelease parts).
"use strict";
function parse(v) {
  const [core, pre] = v.split("+")[0].split(/-(.*)/s);
  return { core: core.split(".").map((n) => BigInt(n || 0)), pre: pre ? pre.split(".") : [] };
}
function compare(a, b) {
  const x = parse(a), y = parse(b);
  for (let i = 0; i < 3; i++) if (x.core[i] !== y.core[i]) return x.core[i] < y.core[i] ? -1 : 1;
  if (!x.pre.length || !y.pre.length) return x.pre.length === y.pre.length ? 0 : x.pre.length ? -1 : 1;
  for (let i = 0; i < Math.max(x.pre.length, y.pre.length); i++) {
    const p = x.pre[i], q = y.pre[i];
    if (p === undefined || q === undefined) return p === undefined ? -1 : 1;
    if (p === q) continue;
    const pn = /^\d+$/.test(p), qn = /^\d+$/.test(q);
    if (pn && qn) return BigInt(p) < BigInt(q) ? -1 : 1;
    if (pn !== qn) return pn ? -1 : 1;
    return p < q ? -1 : 1;
  }
  return 0;
}
const [cmd, a, b] = process.argv.slice(2);
if (cmd === "newer") process.exit(compare(a, b) > 0 ? 0 : 1);
if (cmd === "sort") {
  const lines = require("fs").readFileSync(0, "utf8").split("\n").filter(Boolean);
  process.stdout.write(lines.sort(compare).map((l) => l + "\n").join(""));
}
__T3A_SEMVER__

  cat > "$lib/fix-elf-align.js" <<'__T3A_ELF__'
// Realigns loadable segments whose file offset and address disagree modulo the
// page size, so a binary linked for 4 KB pages also loads on 16 KB / 64 KB page
// kernels. In T3 Code's Node single-executable build only the segment that
// postject appends (the app blob) needs it; Node finds that blob through its
// PT_NOTE header, which moves with the segment.
//   node fix-elf-align.js FILE PAGE_SIZE
"use strict";
const fs = require("fs");
const [file, pageArg] = process.argv.slice(2);
const page = BigInt(pageArg || 16384);
const buf = fs.readFileSync(file);
if (buf.readUInt32BE(0) !== 0x7f454c46 || buf[4] !== 2 || buf[5] !== 1) {
  console.error(`${file}: not a 64-bit little-endian ELF file`);
  process.exit(1);
}
const phoff = Number(buf.readBigUInt64LE(32));
const phentsize = buf.readUInt16LE(54);
const phnum = buf.readUInt16LE(56);
const PT_LOAD = 1;
const at = (i, o) => phoff + i * phentsize + o;
const type = (i) => buf.readUInt32LE(at(i, 0));
const get = (i, o) => buf.readBigUInt64LE(at(i, o));
const put = (i, o, v) => buf.writeBigUInt64LE(v, at(i, o));
const OFFSET = 8, VADDR = 16, PADDR = 24, MEMSZ = 40, ALIGN = 48;
const PT_NOTE = 4;
const loads = [...Array(phnum).keys()].filter((i) => type(i) === PT_LOAD);
let moved = 0;
for (const i of loads) {
  const offset = get(i, OFFSET), vaddr = get(i, VADDR), memsz = get(i, MEMSZ);
  const skew = (((offset - vaddr) % page) + page) % page;
  if (skew === 0n) continue;
  // Code addresses other segments relative to its own, so only a segment that holds
  // nothing but a note (the blob postject appends) can move safely.
  const isNote = [...Array(phnum).keys()].some((j) => type(j) === PT_NOTE && get(j, VADDR) === vaddr);
  if (!isNote) {
    console.error(`${file}: segment at 0x${vaddr.toString(16)} is misaligned and cannot be moved safely`);
    process.exit(1);
  }
  const next = loads.map((j) => get(j, VADDR)).filter((v) => v > vaddr).sort((a, b) => (a < b ? -1 : 1))[0];
  if (next !== undefined && vaddr + skew + memsz > next) {
    console.error(`${file}: segment at 0x${vaddr.toString(16)} cannot move without overlapping`);
    process.exit(1);
  }
  for (let j = 0; j < phnum; j++) {
    if (j === i || type(j) === PT_LOAD) continue;
    const v = get(j, VADDR);
    if (v >= vaddr && v < vaddr + memsz) {
      put(j, VADDR, v + skew);
      put(j, PADDR, get(j, PADDR) + skew);
    }
  }
  put(i, VADDR, vaddr + skew);
  put(i, PADDR, get(i, PADDR) + skew);
  if (get(i, ALIGN) < page) put(i, ALIGN, page);
  moved++;
}
if (moved > 0) {
  fs.writeFileSync(file, buf);
  console.error(`${file}: realigned ${moved} segment(s) for ${page} byte pages`);
}
__T3A_ELF__

  cat > "$lib/provision-root.sh" <<'__T3A_PROVISION_ROOT__'
#!/bin/bash
# System part of the container setup (runs as root inside the container).
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
APT=(apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
say() { printf '    %s\n' "$*"; }

say "Updating Debian packages"
apt-get -q update
"${APT[@]}" full-upgrade

say "Installing developer tools (git, python, compilers, gh, ripgrep, ...)"
"${APT[@]}" install --no-install-recommends \
  ca-certificates curl wget git git-lfs openssh-client gnupg procps psmisc lsof \
  less nano vim-tiny unzip zip xz-utils zstd bzip2 file jq ripgrep fd-find tree \
  python3 python3-pip python3-venv build-essential pkg-config sqlite3 gh \
  locales tzdata bash-completion iproute2 netbase

if ! locale -a 2>/dev/null | grep -qi '^en_US.utf8$'; then
  sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  locale-gen >/dev/null
fi

if [ -n "${T3A_TZ:-}" ] && [ -e "/usr/share/zoneinfo/$T3A_TZ" ]; then
  ln -sf "/usr/share/zoneinfo/$T3A_TZ" /etc/localtime
  printf '%s\n' "$T3A_TZ" > /etc/timezone
fi

# Node.js LTS from nodejs.org (Debian's is too old for some agent CLIs).
NODE_MAJOR=24
case "$(dpkg --print-architecture)" in
  arm64) NODE_ARCH=arm64 ;;
  amd64) NODE_ARCH=x64 ;;
  *) echo "unsupported architecture" >&2; exit 1 ;;
esac
dist="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"
sums=$(curl -fsSL --retry 3 "$dist/SHASUMS256.txt")
tarball=$(printf '%s\n' "$sums" | awk -v a="linux-$NODE_ARCH.tar.xz" '$2 ~ a"$" { print $2; exit }')
want=${tarball#node-}
want=${want%-linux-*}
if [ "$(node --version 2>/dev/null || true)" != "$want" ]; then
  say "Installing Node.js $want"
  curl -fsSL --retry 3 -o /tmp/node.tar.xz "$dist/$tarball"
  expected=$(printf '%s\n' "$sums" | awk -v f="$tarball" '$2 == f { print $1 }')
  echo "$expected  /tmp/node.tar.xz" | sha256sum -c --quiet -
  tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner \
    --exclude='*/CHANGELOG.md' --exclude='*/README.md' --exclude='*/LICENSE'
  rm -f /tmp/node.tar.xz
fi

if ! id t3 >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --uid 1000 t3 2>/dev/null || useradd --create-home --shell /bin/bash t3
fi
chmod 755 /usr/local/bin/t3code-guest-* /usr/local/bin/xdg-open
__T3A_PROVISION_ROOT__

  cat > "$lib/provision-user.sh" <<'__T3A_PROVISION_USER__'
#!/bin/bash
# User part of the container setup (runs as the t3 user).
set -Eeuo pipefail
. /usr/local/lib/t3code-android/env.sh
cd "$HOME"
say() { printf '    %s\n' "$*"; }

mkdir -p "$HOME/.local/bin" "$HOME/.npm-global" "$HOME/projects" "$HOME/.config/t3code-android" "$T3CODE_HOME/runtime"
npm config set prefix "$HOME/.npm-global" >/dev/null
npm config set fund false >/dev/null
npm config set update-notifier false >/dev/null
for rc in .bashrc .profile; do
  if ! grep -q 't3code-android/env.sh' "$HOME/$rc" 2>/dev/null; then
    printf '\n# T3 Code environment (t3code-android)\n. /usr/local/lib/t3code-android/env.sh\n' >> "$HOME/$rc"
  fi
done
git config --global --get-all safe.directory 2>/dev/null | grep -qx '\*' || git config --global --add safe.directory '*'
git config --global --get init.defaultBranch >/dev/null || git config --global init.defaultBranch main
if [ -n "${T3A_GIT_NAME:-}" ]; then git config --global user.name "$T3A_GIT_NAME"; fi
if [ -n "${T3A_GIT_EMAIL:-}" ]; then git config --global user.email "$T3A_GIT_EMAIL"; fi

# T3 Code's service reads extra settings from here.
if ! grep -q '^T3CODE_PORT=' "$T3CODE_HOME/service.env" 2>/dev/null; then
  printf 'T3CODE_PORT=%s\n' "${T3A_PORT:-3773}" >> "$T3CODE_HOME/service.env"
else
  sed -i "s/^T3CODE_PORT=.*/T3CODE_PORT=${T3A_PORT:-3773}/" "$T3CODE_HOME/service.env"
fi
chmod 600 "$T3CODE_HOME/service.env"

say "Installing T3 Code (${T3A_CHANNEL:-nightly})"
/usr/local/bin/t3code-guest-update ensure

providers=${T3A_PROVIDERS:-claude,codex,grok,opencode}
if [ "$providers" != "none" ]; then
  say "Installing agent CLIs: $providers"
  /usr/local/bin/t3code-guest-providers install "$providers" || echo "    (some agent CLIs failed; retry later with: t3code providers install NAME)" >&2
fi
__T3A_PROVISION_USER__

  chmod 755 "$bin/t3code-guest-env" "$bin/t3code-guest-run" "$bin/t3code-guest-update" \
    "$bin/t3code-guest-providers" "$bin/xdg-open"
}

# ---------------------------------------------------------------------------
# The `t3code` command in Termux
# ---------------------------------------------------------------------------

write_t3code_command() {
  cat > "$PREFIX/bin/t3code" <<'__T3A_CLI__'
#!/data/data/com.termux/files/usr/bin/bash
# t3code: run the newest nightly T3 Code server on this Android device.
# Installed by t3code-android (https://github.com/Quive87/t3code-android).
set -uo pipefail

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
CONTAINER=t3code
GUSER=t3
GHOME=/home/t3
CONF_DIR=$HOME/.config/t3code-android
STATE_DIR=$HOME/.local/state/t3code-android
LOG_DIR=$STATE_DIR/logs
SELF=$PREFIX/bin/t3code

# Defaults; change them in ~/.config/t3code-android/config.
T3A_PORT=3773
T3A_AUTO_UPDATE=1       # update to the newest nightly every time the server starts
T3A_UPDATE_HOUR=4       # also restart into a new nightly once a day at this hour ("off" disables)
T3A_WAKE_LOCK=1         # keep the CPU awake while the server runs
T3A_PROVIDERS=claude,codex,grok,opencode
T3A_INSTALL_URL=https://raw.githubusercontent.com/Quive87/t3code-android/main/install.sh
T3A_VERSION=unknown
# shellcheck disable=SC1091
[ -f "$CONF_DIR/config" ] && . "$CONF_DIR/config"
mkdir -p "$STATE_DIR" "$LOG_DIR"

if [ -t 1 ]; then B=$'\033[1m' D=$'\033[2m' G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' N=$'\033[0m'; else B="" D="" G="" Y="" R="" N=""; fi
say() { printf '%s\n' "$*"; }
err() { printf '%st3code: %s%s\n' "$R" "$*" "$N" >&2; }
die() { err "$*"; exit 1; }
slog() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_DIR/supervisor.log"; }

rootfs() {
  local d
  for d in "$PREFIX/var/lib/proot-distro/containers/$CONTAINER/rootfs" "$PREFIX/var/lib/proot-distro/installed-rootfs/$CONTAINER"; do
    [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}
if [ -n "${PD_CONTAINER:-}" ] || [ "${container:-}" = "proot-distro" ]; then
  die "this runs in Termux, not inside the container. Open a Termux session and run t3code there."
fi
ROOTFS=$(rootfs || true)
need_container() { [ -n "$ROOTFS" ] || die "the $CONTAINER container is missing; run the installer again: curl -fsSL $T3A_INSTALL_URL | bash"; }

guest() { proot-distro login "$CONTAINER" --user "$GUSER" -- /usr/local/bin/t3code-guest-env "$@"; }
guest_root() { proot-distro login "$CONTAINER" -- "$@"; }

pid_alive() { [ -n "${1:-}" ] && [ -d "/proc/$1" ]; }
supervisor_pid() {
  local p
  p=$(cat "$STATE_DIR/supervisor.pid" 2>/dev/null) || return 1
  pid_alive "$p" && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q __supervise && { echo "$p"; return 0; }
  return 1
}
launcher_pid() {
  local p
  p=$(cat "$ROOTFS$GHOME/.t3/runtime/android-launcher.pid" 2>/dev/null) || return 1
  pid_alive "$p" && { echo "$p"; return 0; }
  return 1
}
healthy() { curl -fsS -m 4 -o /dev/null "http://127.0.0.1:$T3A_PORT/.well-known/t3/environment" 2>/dev/null; }
clip() { command -v termux-clipboard-set >/dev/null 2>&1 && printf '%s' "$1" | timeout 8 termux-clipboard-set 2>/dev/null; }
open_url() { command -v termux-open-url >/dev/null 2>&1 && timeout 8 termux-open-url "$1" 2>/dev/null; }
# Termux's wake lock keeps the CPU running while the server works with the screen off.
wake_lock() { [ "$T3A_WAKE_LOCK" = 1 ] && timeout 10 termux-wake-lock > /dev/null 2>&1; return 0; }
wake_unlock() { [ "$T3A_WAKE_LOCK" = 1 ] && timeout 10 termux-wake-unlock > /dev/null 2>&1; return 0; }
prop() { getprop "$1" 2> /dev/null; }
android_sdk() { local s; s=$(prop ro.build.version.sdk); echo "${s:-0}"; }

rotate_logs() {
  local f
  for f in "$LOG_DIR/server.log" "$LOG_DIR/supervisor.log"; do
    if [ -f "$f" ] && [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" -gt 20971520 ]; then mv -f "$f" "$f.1"; fi
  done
}

# --- supervisor -------------------------------------------------------------

stop_launcher() {
  local lp
  lp=$(launcher_pid) && kill -TERM "$lp" 2>/dev/null
  return 0
}

update_ticker() {
  local today supervisor=$$ # $$ stays the supervisor's pid inside this subshell
  while sleep 900; do
    [ -e "$STATE_DIR/stop" ] && exit 0
    pid_alive "$supervisor" && [ "$(cat "$STATE_DIR/supervisor.pid" 2>/dev/null)" = "$supervisor" ] || exit 0
    case "$T3A_UPDATE_HOUR" in "" | off | none | no) continue ;; esac
    [ "$(date +%-H)" -eq "$T3A_UPDATE_HOUR" ] 2>/dev/null || continue
    today=$(date +%F)
    [ "$(cat "$STATE_DIR/last-update-check" 2>/dev/null)" = "$today" ] && continue
    printf '%s\n' "$today" > "$STATE_DIR/last-update-check"
    if guest t3code-guest-update check >/dev/null 2>&1; then
      slog "a newer nightly is out; restarting to update"
      touch "$STATE_DIR/restart-for-update"
      stop_launcher
    fi
  done
}

supervise() {
  local child="" ticker="" rc t0 ran fails=0 quick_launcher_fails=0 committed
  # Only this process holds the lock: every child below closes fd 9, or a leftover
  # child would keep the next supervisor from starting.
  exec 9> "$STATE_DIR/supervisor.lock"
  flock -n 9 || { slog "another supervisor is running; not starting a second one"; exit 0; }
  echo $$ > "$STATE_DIR/supervisor.pid"
  trap 'slog "stop requested"; touch "$STATE_DIR/stop"; stop_launcher' TERM INT HUP
  update_ticker 9>&- &
  ticker=$!
  slog "supervisor started (t3code-android $T3A_VERSION)"
  while [ ! -e "$STATE_DIR/stop" ]; do
    if [ "$T3A_AUTO_UPDATE" = 1 ] && [ "$fails" -eq 0 ]; then
      guest t3code-guest-update apply --auto >> "$LOG_DIR/supervisor.log" 2>&1 ||
        slog "update check failed; starting the installed version"
    fi
    rm -f "$STATE_DIR/restart-for-update"
    rotate_logs
    t0=$(date +%s)
    committed=0
    slog "starting T3 Code $(guest t3code-guest-update active 2>/dev/null)"
    proot-distro login "$CONTAINER" --user "$GUSER" -- /usr/local/bin/t3code-guest-run >> "$LOG_DIR/server.log" 2>&1 < /dev/null 9>&- &
    child=$!
    while pid_alive "$child"; do
      sleep 5 9>&- &
      wait $! 2> /dev/null # returns early when a signal arrives
      # Healthy for 90 s: this version is good, forget the pre-update backup.
      if [ "$committed" = 0 ] && [ $(($(date +%s) - t0)) -ge 90 ] && healthy; then
        committed=1
        fails=0
        quick_launcher_fails=0
        guest t3code-guest-update commit >> "$LOG_DIR/supervisor.log" 2>&1 || true
      fi
    done
    wait "$child" 2> /dev/null
    rc=$?
    ran=$(($(date +%s) - t0))
    slog "T3 Code exited (code $rc) after ${ran}s"
    [ -e "$STATE_DIR/stop" ] && break
    if [ -e "$STATE_DIR/restart-for-update" ]; then fails=0; continue; fi
    if [ "$committed" = 1 ]; then fails=0; else fails=$((fails + 1)); fi
    # A launcher that rejects its state exits immediately; fall back to plain `t3 serve`.
    if [ "$ran" -lt 20 ] && tail -n 30 "$LOG_DIR/server.log" | grep -q 'Service state is invalid or unsupported'; then
      quick_launcher_fails=$((quick_launcher_fails + 1))
      if [ "$quick_launcher_fails" -ge 2 ]; then
        slog "the service launcher cannot run this version; using plain 't3 serve' (in-app updates off until the next update)"
        touch "$ROOTFS$GHOME/.t3/runtime/android-plain-serve"
      fi
    fi
    if [ "$fails" -ge 3 ] && guest t3code-guest-update rollback --if-uncommitted >> "$LOG_DIR/supervisor.log" 2>&1; then
      slog "the new version kept failing; rolled back to $(guest t3code-guest-update active 2>/dev/null)"
      fails=0
    fi
    sleep $((fails < 6 ? 1 << fails : 60))
  done
  pkill -P "$ticker" 2> /dev/null
  kill "$ticker" 2> /dev/null
  rm -f "$STATE_DIR/supervisor.pid"
  wake_unlock
  slog "supervisor stopped"
}

# --- commands ---------------------------------------------------------------

wait_healthy() {
  local started deadline shown=0
  started=$(date +%s)
  deadline=$((started + $1))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    healthy && return 0
    # Give a just-spawned supervisor a moment to write its pid file.
    if ! supervisor_pid > /dev/null && [ $(($(date +%s) - started)) -gt 15 ]; then return 1; fi
    if [ "$shown" -eq 0 ] && [ $(($(date +%s) - started)) -gt 20 ]; then
      say "${D}  still starting (updates and first starts take longer)...${N}"
      shown=1
    fi
    sleep 2
  done
  return 1
}

cmd_start() {
  need_container
  if supervisor_pid > /dev/null; then
    say "T3 Code is already running."
    [ "${1:-}" = "--boot" ] || print_where
    return 0
  fi
  if launcher_pid > /dev/null; then
    # A server left behind without its supervisor (for example after a crash).
    cmd_stop > /dev/null
  fi
  rm -f "$STATE_DIR/stop"
  wake_lock
  nohup setsid "$SELF" __supervise < /dev/null >> "$LOG_DIR/supervisor.log" 2>&1 &
  [ "${1:-}" = "--boot" ] && return 0
  say "Starting T3 Code..."
  if ! wait_healthy 600; then
    err "T3 Code did not come up. Check: t3code logs"
    return 1
  fi
  say "${G}T3 Code is running.${N}"
  print_where
}

cmd_stop() {
  local sp lp i
  touch "$STATE_DIR/stop"
  sp=$(supervisor_pid) || sp=""
  lp=$(launcher_pid) || lp=""
  if [ -z "$sp" ] && [ -z "$lp" ]; then
    say "T3 Code is not running."
    wake_unlock
    return 0
  fi
  say "Stopping T3 Code..."
  [ -n "$lp" ] && kill -TERM "$lp" 2>/dev/null
  [ -n "$sp" ] && kill -TERM "$sp" 2>/dev/null
  for i in $(seq 1 60); do
    { [ -n "$sp" ] && pid_alive "$sp"; } || { [ -n "$lp" ] && pid_alive "$lp"; } || break
    sleep 1
  done
  if { [ -n "$lp" ] && pid_alive "$lp"; } || { [ -n "$sp" ] && pid_alive "$sp"; }; then
    err "T3 Code did not stop in time; forcing it"
    [ -n "$sp" ] && pkill -TERM -P "$sp" 2>/dev/null
    [ -n "$lp" ] && kill -KILL "$lp" 2>/dev/null
    [ -n "$sp" ] && kill -KILL "$sp" 2>/dev/null
  fi
  rm -f "$STATE_DIR/supervisor.pid"
  wake_unlock
  say "Stopped."
}

print_where() {
  say ""
  say "  On this device:  ${B}http://127.0.0.1:$T3A_PORT${N}"
  say "  Connect the T3 Code app:  ${B}t3code pair${N}   (copies a link to paste into Add environment)"
  say "  Open it in Chrome:        ${B}t3code open${N}"
}

cmd_status() {
  local sp v
  need_container
  if sp=$(supervisor_pid); then
    if healthy; then
      say "T3 Code: ${G}running${N} on port $T3A_PORT"
      if curl -fsS -m 4 "http://127.0.0.1:$T3A_PORT/.well-known/t3/environment" 2>/dev/null | grep -q '"serverSelfUpdate":"boot-service"'; then
        say "  in-app 'Update server': available"
      else
        say "  in-app 'Update server': ${Y}unavailable${N} (t3code update still works)"
      fi
    else
      say "T3 Code: ${Y}starting or restarting${N}"
    fi
  else
    say "T3 Code: ${D}stopped${N}  (start it with: t3code start)"
  fi
  guest t3code-guest-update status 2>/dev/null | sed 's/^/  /'
  [ -f "$HOME/.termux/boot/t3code" ] && say "  autostart: on (needs the Termux:Boot app)" || say "  autostart: off"
  case "$T3A_UPDATE_HOUR" in "" | off | none | no) v="on start only" ;; *) v="on start and daily at ${T3A_UPDATE_HOUR}:00" ;; esac
  [ "$T3A_AUTO_UPDATE" = 1 ] && say "  auto-update: $v" || say "  auto-update: off"
}

cmd_logs() {
  if [ "${1:-}" = "-f" ] || [ "${1:-}" = "--follow" ]; then
    exec tail -n 80 -F "$LOG_DIR/supervisor.log" "$LOG_DIR/server.log"
  fi
  say "${B}== supervisor ($LOG_DIR/supervisor.log)${N}"
  tail -n 30 "$LOG_DIR/supervisor.log" 2>/dev/null
  say "${B}== server ($LOG_DIR/server.log)${N}"
  tail -n 60 "$LOG_DIR/server.log" 2>/dev/null
  say "${D}T3 Code's own logs: $ROOTFS$GHOME/.t3/userdata/logs${N}"
}

cmd_pair() {
  local lan=0 open=0 label="Android app" out url token local_url
  while [ $# -gt 0 ]; do
    case "$1" in
      --lan) lan=1; label="Another device" ;;
      --open) open=1; label="Browser on this device" ;;
      --label) shift; label=${1:-$label} ;;
    esac
    shift
  done
  healthy || die "T3 Code is not running (start it with: t3code start)"
  out=$(guest t3 pair --label "$label" --ttl 15m 2>&1) || { printf '%s\n' "$out" >&2; die "could not create a pairing link"; }
  url=$(printf '%s\n' "$out" | sed -n 's/^Pairing URL: //p' | tail -n1)
  token=$(printf '%s\n' "$out" | sed -n 's/^Token: //p' | tail -n1)
  [ -n "$token" ] || { printf '%s\n' "$out" >&2; die "could not read the pairing token"; }
  local_url="http://127.0.0.1:$T3A_PORT/pair#token=$token"
  if [ "$open" = 1 ]; then
    open_url "$local_url" || say "Open this in your browser: $local_url"
    return 0
  fi
  if [ "$lan" = 1 ]; then
    say "Pair a computer or another phone on the same Wi-Fi (valid 15 minutes; scan or paste):"
    printf '%s\n' "$out" | sed -n '/^Pairing URL/q;p'
    say "  ${B}$url${N}"
    say "In T3 Code on that device: Settings > Connections (or Environments) > Add environment, paste it."
    return 0
  fi
  say "Link for the T3 Code app on ${B}this${N} device (valid 15 minutes):"
  say "  ${B}$local_url${N}"
  if clip "$local_url"; then say "${G}Copied to the clipboard.${N}"; fi
  say "In the T3 Code app: Settings > Environments > Add environment, then paste the link."
}

cmd_open() {
  healthy || cmd_start || return 1
  if [ "${1:-}" = "--pair" ] || [ ! -f "$STATE_DIR/browser-paired" ]; then
    cmd_pair --open && touch "$STATE_DIR/browser-paired"
  else
    open_url "http://127.0.0.1:$T3A_PORT/" || say "Open http://127.0.0.1:$T3A_PORT/ in your browser"
  fi
}

cmd_update() {
  local all=0 running=0 latest active
  [ "${1:-}" = "--all" ] && all=1
  need_container
  supervisor_pid > /dev/null && running=1
  if [ "$all" = 1 ]; then
    say "${B}Updating Termux packages${N}"
    pkg update -y 2>/dev/null || apt-get update
    apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
    say "${B}Updating Debian packages and Node.js${N}"
    guest_root bash /usr/local/lib/t3code-android/provision-root.sh
    say "${B}Updating agent CLIs${N}"
    guest t3code-guest-providers update "$T3A_PROVIDERS"
  fi
  latest=$(guest t3code-guest-update latest) || die "could not look up the newest nightly"
  active=$(guest t3code-guest-update active)
  if [ "$latest" = "$active" ]; then
    say "T3 Code $active is the newest nightly."
    return 0
  fi
  say "Updating T3 Code ${active:-?} -> $latest"
  [ "$running" = 1 ] && cmd_stop
  guest t3code-guest-update apply "$latest" || die "update failed"
  if [ "$running" = 1 ]; then cmd_start; else say "Done. Start it with: t3code start"; fi
}

cmd_login() {
  local p=${1:-}
  shift || true
  case "$p" in
    claude) guest claude auth login "$@" ;;
    codex)
      if [ "${1:-}" = "--home" ] && [ -n "${2:-}" ]; then
        guest env CODEX_HOME="$2" codex login
      else
        guest codex login "$@"
      fi
      ;;
    grok) guest grok login "$@" ;;
    opencode) guest opencode auth login "$@" ;;
    gemini) guest gemini "$@" ;;
    pi) guest pi "$@" ;;
    gh | github) guest gh auth login "$@" && guest gh auth setup-git ;;
    *)
      say "usage: t3code login claude|codex|grok|opencode|gemini|pi|github"
      say "  codex --device-auth   sign in with a code instead of a browser redirect"
      say "  codex --home DIR      sign a second ChatGPT account into DIR (use it as a shadow home in T3)"
      say "Antigravity and Cursor sign in from T3 Code: Settings > Providers."
      return 1
      ;;
  esac
}

cmd_autostart() {
  case "${1:-status}" in
    on)
      mkdir -p "$HOME/.termux/boot"
      printf '#!/data/data/com.termux/files/usr/bin/sh\n# Starts T3 Code at boot (needs the Termux:Boot app, opened once).\ntermux-wake-lock\nexec %s start --boot\n' "$SELF" > "$HOME/.termux/boot/t3code"
      chmod 755 "$HOME/.termux/boot/t3code"
      say "Autostart on. Install Termux:Boot (same source as Termux) and open it once."
      ;;
    off) rm -f "$HOME/.termux/boot/t3code"; say "Autostart off." ;;
    *) [ -f "$HOME/.termux/boot/t3code" ] && say "on" || say "off" ;;
  esac
}

cmd_fix_android() {
  local sdk serial pport pcode cport
  sdk=$(android_sdk)
  say "${B}Keep Android from killing T3 Code's agents${N}"
  say ""
  say "1. Battery: Settings > Apps > Termux > Battery > ${B}Unrestricted${N}."
  if [ "$sdk" -lt 31 ]; then
    say "2. This Android version has no phantom process killer. Nothing else to do."
    return 0
  fi
  say "2. Android 12+ kills background child processes (\"phantom processes\"), which"
  say "   stops agents mid-task. Turn that off once:"
  if [ "$sdk" -ge 34 ]; then
    say "   Settings > System > Developer options > ${B}Disable child process restrictions${N} (on)."
    say "   (Enable Developer options by tapping Build number 7 times in About tablet.)"
    say ""
    say "   If that switch is missing, continue here to do it over wireless debugging."
  fi
  say ""
  printf 'Do it now over wireless debugging (Wi-Fi needed)? [y/N] '
  read -r ans < /dev/tty || ans=n
  case "$ans" in y | Y | yes) ;; *) return 0 ;; esac
  command -v adb >/dev/null 2>&1 || pkg install -y android-tools || die "could not install adb"
  say ""
  say "Open Settings > Developer options > ${B}Wireless debugging${N} (turn it on), then"
  say "tap ${B}Pair device with pairing code${N}. Use split screen so the code stays visible."
  printf 'Pairing port (the number after the colon): '; read -r pport < /dev/tty
  printf 'Six-digit pairing code: '; read -r pcode < /dev/tty
  adb pair "127.0.0.1:$pport" "$pcode" || die "pairing failed; try again"
  printf 'Port shown under "IP address & Port" on the Wireless debugging screen: '; read -r cport < /dev/tty
  serial="127.0.0.1:$cport"
  adb connect "$serial" || die "could not connect"
  adb -s "$serial" shell '/system/bin/device_config set_sync_disabled_for_tests persistent; /system/bin/device_config put activity_manager max_phantom_processes 2147483647; settings put global settings_enable_monitor_phantom_procs false' || true
  adb -s "$serial" shell 'dumpsys deviceidle whitelist +com.termux' > /dev/null 2>&1 || true
  say "max_phantom_processes = $(adb -s "$serial" shell /system/bin/device_config get activity_manager max_phantom_processes 2>/dev/null | tr -d '\r')"
  adb disconnect "$serial" > /dev/null 2>&1 || true
  say "${G}Done.${N} You can turn Wireless debugging off again. Repeat this after major Android updates."
}

cmd_doctor() {
  local ps
  say "${B}Device${N}"
  if [ -n "$(prop ro.build.version.release)" ]; then
    say "  $(prop ro.product.manufacturer) $(prop ro.product.model), Android $(prop ro.build.version.release) (SDK $(prop ro.build.version.sdk))"
  fi
  say "  CPU: $(uname -m)   Termux: ${TERMUX_VERSION:-?} (${TERMUX_APK_RELEASE:-unknown source})"
  say "  Free space: $(df -h "$HOME" 2>/dev/null | awk 'NR==2 { print $4 }')"
  say "  proot-distro: $(proot-distro --version 2>/dev/null | head -n1)"
  need_container
  ps=$(guest getconf PAGESIZE 2>/dev/null)
  say "  Memory page size: ${ps:-?}$([ "${ps:-4096}" -gt 4096 ] && printf ' (16 KB pages: T3 Code is realigned at install; in-app updates may fail, use t3code update)')"
  say ""
  say "${B}T3 Code${N}"
  cmd_status
  say ""
  say "${B}Agent CLIs${N}"
  guest t3code-guest-providers list | sed 's/^/  /'
  say ""
  say "${B}Hints${N}"
  [ "${TERMUX_APK_RELEASE:-}" = "GOOGLE_PLAY_STORE" ] && say "  - Termux from Google Play is limited; prefer the GitHub or F-Droid build."
  [ "$(android_sdk)" -ge 31 ] && say "  - Android 12+: run 't3code fix-android' once so agents are not killed in the background."
  say "  - Logs: t3code logs"
}

cmd_uninstall() {
  local ans
  say "This removes T3 Code, the $CONTAINER container ${B}including everything in it (projects in $GHOME, logins)${N},"
  say "and the t3code command."
  printf 'Type "remove" to continue: '
  read -r ans < /dev/tty || ans=""
  [ "$ans" = "remove" ] || { say "Cancelled."; return 1; }
  cmd_stop
  rm -f "$HOME/.termux/boot/t3code" "$HOME/.shortcuts/T3 Code"* "$HOME/.shortcuts/tasks/T3 Code"*
  proot-distro remove "$CONTAINER" || true
  rm -rf "$STATE_DIR" "$CONF_DIR"
  rm -f "$SELF"
  say "Removed."
}

cmd_help() {
  cat <<EOF
${B}t3code${N} - the newest nightly T3 Code on this device  (t3code-android $T3A_VERSION)

  ${B}start${N} | ${B}stop${N} | ${B}restart${N}     run the server in the background
  ${B}status${N}                    is it running, which version
  ${B}pair${N} [--lan]              link for the T3 Code app here (--lan: for other devices)
  ${B}open${N} [--pair]             open T3 Code in the browser
  ${B}update${N} [--all]            newest nightly now (--all: also agents, Debian, Termux)
  ${B}login${N} PROVIDER            sign in: claude, codex, grok, opencode, gemini, pi, github
  ${B}providers${N} [install NAMES] list or install agent CLIs
  ${B}logs${N} [-f]                 supervisor and server logs
  ${B}shell${N}                     shell inside the container (as the t3 user)
  ${B}root${N} [CMD]                root shell or command in the container (apt install ...)
  ${B}t3${N} ARGS                   run the t3 CLI inside the container
  ${B}autostart${N} on|off          start at boot (Termux:Boot)
  ${B}fix-android${N}               stop Android from killing agents (Android 12+)
  ${B}doctor${N}                    diagnostics
  ${B}self-update${N}               re-run the installer (updates this tool)
  ${B}uninstall${N}                 remove everything

Settings: $CONF_DIR/config   Your env vars for agents: $ROOTFS$GHOME/.config/t3code-android/env
EOF
}

case "${1:-help}" in
  start) shift; cmd_start "$@" ;;
  stop) cmd_stop ;;
  restart) cmd_stop; cmd_start ;;
  status) cmd_status ;;
  logs | log) shift; cmd_logs "$@" ;;
  pair) shift; cmd_pair "$@" ;;
  open) shift; cmd_open "$@" ;;
  app) open_url "t3code://" || die "is the T3 Code app installed?" ;;
  update | upgrade) shift; cmd_update "$@" ;;
  login) shift; cmd_login "$@" ;;
  providers) shift; need_container; if [ $# -eq 0 ]; then guest t3code-guest-providers list; else guest t3code-guest-providers "$@"; fi ;;
  shell) need_container; exec proot-distro login "$CONTAINER" --user "$GUSER" -- /usr/local/bin/t3code-guest-env ;;
  root) shift; need_container; if [ $# -eq 0 ]; then exec proot-distro login "$CONTAINER"; else exec proot-distro login "$CONTAINER" -- "$@"; fi ;;
  t3) shift; need_container; exec proot-distro login "$CONTAINER" --user "$GUSER" -- /usr/local/bin/t3code-guest-env t3 "$@" ;;
  autostart) shift; cmd_autostart "$@" ;;
  fix-android) cmd_fix_android ;;
  doctor) cmd_doctor ;;
  self-update) exec bash -c "curl -fsSL '$T3A_INSTALL_URL' | bash" ;;
  uninstall) cmd_uninstall ;;
  __supervise) supervise ;;
  version | --version | -v) say "t3code-android $T3A_VERSION" ;;
  help | --help | -h) cmd_help ;;
  *) err "unknown command: $1"; cmd_help; exit 2 ;;
esac
__T3A_CLI__
  chmod 755 "$PREFIX/bin/t3code"
}

write_shortcuts() {
  mkdir -p "$HOME/.shortcuts"
  printf '#!/data/data/com.termux/files/usr/bin/bash\nt3code start && t3code open\n' > "$HOME/.shortcuts/T3 Code"
  printf '#!/data/data/com.termux/files/usr/bin/bash\nt3code pair\nread -rp "Press Enter to close" _\n' > "$HOME/.shortcuts/T3 Code - pair app"
  printf '#!/data/data/com.termux/files/usr/bin/bash\nt3code update\nread -rp "Press Enter to close" _\n' > "$HOME/.shortcuts/T3 Code - update"
  printf '#!/data/data/com.termux/files/usr/bin/bash\nt3code stop\n' > "$HOME/.shortcuts/T3 Code - stop"
  chmod 755 "$HOME/.shortcuts/T3 Code"*
}

save_config() {
  mkdir -p "$CONF_DIR"
  {
    printf '# t3code-android settings (written by the installer; edit freely)\n'
    printf 'T3A_PORT=%s\n' "$T3A_PORT"
    printf 'T3A_PROVIDERS=%s\n' "$T3A_PROVIDERS"
    printf 'T3A_AUTO_UPDATE=%s\n' "${T3A_AUTO_UPDATE:-1}"
    printf 'T3A_UPDATE_HOUR=%s\n' "${T3A_UPDATE_HOUR:-4}"
    printf 'T3A_WAKE_LOCK=%s\n' "${T3A_WAKE_LOCK:-1}"
    printf 'T3A_INSTALL_URL=%s\n' "$T3A_INSTALL_URL"
    printf 'T3A_VERSION=%s\n' "$T3A_VERSION"
  } > "$CONFIG"
}

container_rootfs() {
  local d
  for d in "$PREFIX/var/lib/proot-distro/containers/$CONTAINER/rootfs" "$PREFIX/var/lib/proot-distro/installed-rootfs/$CONTAINER"; do
    [ -d "$d/usr" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

main() {
  # Under `curl | bash` the script arrives on stdin; give child processes the terminal instead.
  if [ ! -t 0 ]; then
    if (exec < /dev/tty) 2> /dev/null; then exec < /dev/tty; else exec < /dev/null; fi
  fi
  mkdir -p "$STATE_DIR" "$CONF_DIR"
  exec > >(tee -a "$INSTALL_LOG") 2>&1
  trap on_error ERR

  printf '\n%sT3 Code for Android%s %s(installer %s)%s\n' "$B" "$N" "$D" "$T3A_VERSION" "$N"
  printf '%sNewest nightly T3 Code server + agent CLIs, running on this device.%s\n' "$D" "$N"

  if [ -n "${PD_CONTAINER:-}" ] || [ "${container:-}" = "proot-distro" ]; then
    die "run this in a Termux session, not inside the container (for example not in T3 Code's terminal)"
  fi
  [ -x "$PREFIX/bin/pkg" ] || [ -n "${TERMUX_VERSION:-}" ] || die "run this inside the Termux app (https://github.com/termux/termux-app/releases)"
  [ "$(id -u)" -ne 0 ] || die "run this as the normal Termux user, not as root"
  case "$(uname -m)" in
    aarch64 | x86_64) ;;
    *) die "T3 Code needs a 64-bit device (this one is $(uname -m))" ;;
  esac
  if [ "${TERMUX_APK_RELEASE:-}" = "GOOGLE_PLAY_STORE" ]; then
    warn "This Termux comes from Google Play, where some features are restricted. If something fails, use the GitHub build."
  fi

  # Settings: environment > saved config > defaults.
  local saved_port="" saved_providers="" saved_url=""
  if [ -f "$CONFIG" ]; then
    saved_port=$(sed -n 's/^T3A_PORT=//p' "$CONFIG")
    saved_providers=$(sed -n 's/^T3A_PROVIDERS=//p' "$CONFIG")
    saved_url=$(sed -n 's/^T3A_INSTALL_URL=//p' "$CONFIG")
    T3A_AUTO_UPDATE=${T3A_AUTO_UPDATE:-$(sed -n 's/^T3A_AUTO_UPDATE=//p' "$CONFIG")}
    T3A_UPDATE_HOUR=${T3A_UPDATE_HOUR:-$(sed -n 's/^T3A_UPDATE_HOUR=//p' "$CONFIG")}
    T3A_WAKE_LOCK=${T3A_WAKE_LOCK:-$(sed -n 's/^T3A_WAKE_LOCK=//p' "$CONFIG")}
  fi
  T3A_PORT=${T3A_PORT:-${saved_port:-3773}}
  T3A_PROVIDERS=${T3A_PROVIDERS:-${saved_providers:-claude,codex,grok,opencode}}
  T3A_INSTALL_URL=${T3A_INSTALL_URL:-${saved_url:-$T3A_INSTALL_URL_DEFAULT}}
  local first_install=1
  [ -x "$PREFIX/bin/t3code" ] && first_install=0

  local free_kb
  free_kb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 { print $4 }')
  if [ -n "$free_kb" ] && [ "$free_kb" -lt 4194304 ]; then
    warn "Only $((free_kb / 1024)) MB free. T3 Code with its tools needs about 4 GB (more for Antigravity)."
  fi

  step "Updating Termux packages"
  export DEBIAN_FRONTEND=noninteractive
  pkg update -y || apt-get update || die "could not refresh Termux packages; run 'termux-change-repo', pick another mirror, and retry"
  apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install \
    proot-distro curl util-linux procps coreutils termux-api termux-tools

  local pd_major
  pd_major=$(proot-distro --version 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)
  if [ -n "$pd_major" ] && [ "$pd_major" -lt 5 ]; then
    die "proot-distro $pd_major.x is too old; run 'pkg upgrade proot-distro' and retry"
  fi

  if [ -f "$STATE_DIR/supervisor.pid" ] && [ -x "$PREFIX/bin/t3code" ]; then
    step "Stopping the running T3 Code for the update"
    "$PREFIX/bin/t3code" stop || true
  fi

  local root
  if root=$(container_rootfs); then
    step "Debian container '$CONTAINER' already exists"
  else
    step "Installing a Debian container ($DEBIAN_IMAGE, about 50 MB)"
    proot-distro install "$DEBIAN_IMAGE" --name "$CONTAINER"
    root=$(container_rootfs) || die "the container was not created"
  fi

  step "Setting up Debian (developer tools, Node.js)"
  write_guest_files "$root"
  local tz=""
  command -v getprop > /dev/null 2>&1 && tz=$(getprop persist.sys.timezone 2>/dev/null || true)
  proot-distro login "$CONTAINER" --env "T3A_TZ=$tz" -- bash /usr/local/lib/t3code-android/provision-root.sh

  step "Installing T3 Code nightly and agent CLIs ($T3A_PROVIDERS)"
  proot-distro login "$CONTAINER" --user "$GUSER" \
    --env "T3A_PROVIDERS=$T3A_PROVIDERS" --env "T3A_PORT=$T3A_PORT" \
    --env "T3A_GIT_NAME=${T3A_GIT_NAME:-}" --env "T3A_GIT_EMAIL=${T3A_GIT_EMAIL:-}" \
    -- bash /usr/local/lib/t3code-android/provision-user.sh

  step "Installing the t3code command"
  write_t3code_command
  save_config
  write_shortcuts
  "$PREFIX/bin/t3code" autostart on > /dev/null
  info "t3code, Termux:Boot autostart and Termux:Widget shortcuts are in place"

  if [ "${T3A_NO_START:-0}" = 1 ]; then
    step "Done (not started because T3A_NO_START=1)"
    info "Start it with: t3code start"
    return 0
  fi

  step "Starting T3 Code"
  "$PREFIX/bin/t3code" start

  printf '\n%s%sAll set.%s Next steps:\n' "$G" "$B" "$N"
  cat <<EOF

  1. Install the T3 Code app (newest nightly build) with Obtainium, or
     open http://127.0.0.1:$T3A_PORT in Chrome for the full desktop UI ('t3code open').
  2. Connect the app:  ${B}t3code pair${N}  -> paste into Settings > Environments > Add environment.
  3. Sign in to your agents:  ${B}t3code login claude${N}, ${B}codex${N}, ${B}grok${N}, ${B}opencode${N}
     (Antigravity and Cursor: Settings > Providers in T3 Code).
  4. Keep Android from killing agents:  ${B}t3code fix-android${N}

  'Update server' in the apps works, and T3 Code moves to the newest nightly
  on every start and daily at ${T3A_UPDATE_HOUR:-4}:00.  More: ${B}t3code help${N}
EOF
  if [ "$first_install" = 1 ]; then
    "$PREFIX/bin/t3code" pair || true
  fi
}

# Kept on one line so `curl | bash` has read all of it before anything runs.
[ "${T3A_SOURCE_ONLY:-0}" = 1 ] || { main "$@"; exit $?; }
