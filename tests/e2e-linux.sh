#!/bin/bash
# Fallback test on a plain arm64 Linux host (no Termux): the Debian container under
# proot-distro, provisioning, the runtime installer and T3 Code's service launcher.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

FAILED=()
pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; FAILED+=("$*"); }
finish() {
  [ -f server.log ] && tail -n 60 server.log
  [ "${#FAILED[@]}" -eq 0 ] || { printf 'Failed: %s\n' "${FAILED[@]}"; exit 1; }
  echo "All checks passed."
  exit 0
}
env_json() { curl -fsS -m 5 http://127.0.0.1:3773/.well-known/t3/environment; }

sudo apt-get update -q && sudo apt-get install -y -q pipx curl jq build-essential libtalloc-dev pkg-config git
pipx install proot-distro
export PATH="$HOME/.local/bin:$PATH"

# Ubuntu's proot 5.1 crashes on current glibc; Termux ships a patched proot, so use a current upstream one here.
git clone -q --depth 1 --branch v5.5.0 https://github.com/proot-me/proot "$HOME/proot-src"
make -s -C "$HOME/proot-src/src" proot WITHOUT_PYTHON=1 > /dev/null || { fail "building proot"; finish; }
export PD_PROOT_BIN="$HOME/proot-src/src/proot"
"$PD_PROOT_BIN" --version | head -n 3

# Reuse the installer's guest files without running its Termux part.
T3A_SOURCE_ONLY=1 . ./install.sh
set +e +u

proot-distro install debian:trixie --name t3code || { fail "container install"; finish; }
root="$HOME/.local/share/proot-distro/containers/t3code/rootfs"
write_guest_files "$root"
if ! proot-distro login t3code -- true; then
  echo "proot cannot start the container; retrying with PROOT_NO_SECCOMP=1"
  export PROOT_NO_SECCOMP=1
fi
proot-distro login t3code -- bash /usr/local/lib/t3code-android/provision-root.sh && pass "root provisioning" || { fail "root provisioning"; finish; }
proot-distro login t3code --user t3 --env T3A_PROVIDERS=claude,codex,grok,opencode \
  -- bash /usr/local/lib/t3code-android/provision-user.sh && pass "user provisioning" || { fail "user provisioning"; finish; }

proot-distro login t3code --user t3 -- /usr/local/bin/t3code-guest-run > server.log 2>&1 &
for _ in $(seq 1 100); do env_json > env.json 2> /dev/null && break; sleep 3; done
cat env.json; echo
grep -q '"serverSelfUpdate":"boot-service"' env.json && pass "launcher-managed server" || fail "server not up or not launcher-managed"
proot-distro login t3code --user t3 -- /usr/local/bin/t3code-guest-env t3code-guest-providers list
proot-distro login t3code --user t3 -- /usr/local/bin/t3code-guest-env t3 pair --label ci | grep -q '^Pairing URL: http' &&
  pass "t3 pair works from a second session" || fail "t3 pair"

pid=$(cat "$root/home/t3/.t3/runtime/android-launcher.pid" 2> /dev/null)
if [ -n "$pid" ] && kill -TERM "$pid" 2> /dev/null; then
  for _ in $(seq 1 30); do kill -0 "$pid" 2> /dev/null || break; sleep 1; done
  kill -0 "$pid" 2> /dev/null && fail "launcher ignored SIGTERM" || pass "launcher stopped on SIGTERM"
else
  fail "no running launcher to stop"
fi
finish
