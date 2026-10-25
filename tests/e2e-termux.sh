#!/data/data/com.termux/files/usr/bin/bash
# End-to-end test of install.sh inside termux-docker (Termux userland, no Android
# framework). Run as the container's normal user with the repo mounted at /repo.
set -uo pipefail

PORT=3773
FAILED=()
pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; FAILED+=("$*"); }
section() { printf '\n\033[1m=== %s\033[0m\n' "$*"; }
guest() { proot-distro login t3code --user t3 -- /usr/local/bin/t3code-guest-env "$@"; }
env_json() { curl -fsS -m 5 "http://127.0.0.1:$PORT/.well-known/t3/environment"; }
wait_for() { # wait_for SECONDS COMMAND...
  local deadline=$(($(date +%s) + $1)); shift
  until "$@"; do [ "$(date +%s)" -lt "$deadline" ] || return 1; sleep 3; done
}
finish() {
  section "Logs"
  t3code logs 2> /dev/null | tail -n 80
  section "Result"
  if [ "${#FAILED[@]}" -eq 0 ]; then echo "All checks passed."; exit 0; fi
  printf 'Failed: %s\n' "${FAILED[@]}"
  exit 1
}

section "Install (as with curl | bash)"
uname -a
if bash /repo/install.sh < /dev/null; then pass "installer finished"; else fail "installer failed"; finish; fi
pkg install -y jq > /dev/null 2>&1 || apt-get install -y jq > /dev/null 2>&1

section "Server"
t3code status
if env_json > "$PREFIX/tmp/env.json"; then pass "server answers on port $PORT"; else fail "server not reachable"; finish; fi
cat "$PREFIX/tmp/env.json"; echo
grep -q '"serverSelfUpdate":"boot-service"' "$PREFIX/tmp/env.json" &&
  pass "runs under T3's service launcher (in-app 'Update server' available)" ||
  fail "serverSelfUpdate is not boot-service"
latest=$(guest t3code-guest-update latest)
active=$(guest t3code-guest-update active)
[ -n "$latest" ] && [ "$active" = "$latest" ] && pass "runs the newest nightly ($active)" || fail "active=$active latest=$latest"
grep -q "\"serverVersion\":\"$active\"" "$PREFIX/tmp/env.json" && pass "server reports $active" || fail "server version mismatch"

section "Pairing"
out=$(t3code pair 2>&1)
echo "$out"
echo "$out" | grep -qE "http://127\.0\.0\.1:$PORT/pair#token=[A-Za-z0-9._~-]+" && pass "pairing link for the app" || fail "no pairing link"

section "Agent CLIs"
t3code providers | tee "$PREFIX/tmp/providers.txt"
for p in claude codex grok opencode; do
  grep -qE "^$p +[^ -]" "$PREFIX/tmp/providers.txt" && pass "$p runs" || fail "$p missing or not running"
done

section "Auto-update on start"
older=$(curl -fsSL "https://api.github.com/repos/pingdotgg/t3code/releases?per_page=40" |
  jq -r '[.[] | select(.draft | not) | .tag_name | select(test("^v[0-9.]+-nightly\\.[0-9]+\\.[0-9]+$"))][1] | ltrimstr("v")')
echo "older nightly: $older"
t3code stop
guest t3code-guest-update apply "$older" && pass "pinned the older nightly $older" || fail "could not pin $older"
t3code start > /dev/null
now=$(guest t3code-guest-update active)
latest=$(guest t3code-guest-update latest) # a new nightly may have shipped meanwhile
[ "$now" = "$latest" ] && pass "start moved $older -> $now" || fail "after start active=$now (expected $latest)"
wait_for 120 env_json > /dev/null && pass "server healthy after update" || fail "server down after update"
latest=$now

section "Rollback of a broken nightly"
t3code stop
vdir="$PREFIX/var/lib/proot-distro/containers/t3code/rootfs/home/t3/.t3/runtime/versions"
fake="9.9.9-nightly.29991231.99999"
cp -a "$vdir/$latest" "$vdir/$fake"
mv "$vdir/$fake/t3" "$vdir/$fake/t3.real"
cat > "$vdir/$fake/t3" << 'EOF'
#!/bin/sh
case "${1:-}" in --version | -v | __service-preflight) exec "$(dirname "$0")/t3.real" "$@" ;; esac
echo "simulated broken nightly" >&2
exit 1
EOF
chmod 755 "$vdir/$fake/t3"
echo "$fake" > "$vdir/$fake/.install-complete"
guest t3code-guest-update apply "$fake" && echo "activated broken $fake"
t3code start > /dev/null
now=$(guest t3code-guest-update active)
[ "$now" = "$latest" ] && pass "rolled back to $now after repeated failures" || fail "active=$now after broken update"
guest bash -c 'cat "$T3CODE_HOME/runtime/android-blocked-versions"' | grep -qxF "$fake" &&
  pass "broken version is blocked from auto-update" || fail "broken version not blocked"
wait_for 120 env_json > /dev/null && pass "server healthy after rollback" || fail "server down after rollback"
rm -rf "${vdir:?}/$fake"

section "16 KB page support (segment realignment)"
guest bash -c "cp \"\$T3CODE_HOME/runtime/versions/$latest/t3\" /tmp/t3-16k && node /usr/local/lib/t3code-android/fix-elf-align.js /tmp/t3-16k 65536" &&
  pass "realigned" || fail "realign failed"
guest node -e '
  const b = require("fs").readFileSync("/tmp/t3-16k");
  const off = Number(b.readBigUInt64LE(32)), sz = b.readUInt16LE(54), n = b.readUInt16LE(56);
  for (let i = 0; i < n; i++) {
    const p = off + i * sz;
    if (b.readUInt32LE(p) !== 1) continue;
    const o = b.readBigUInt64LE(p + 8), v = b.readBigUInt64LE(p + 16);
    if ((v - o) % 65536n !== 0n) { console.error("misaligned segment at 0x" + v.toString(16)); process.exit(1); }
  }' && pass "every segment is 64 KB-congruent" || fail "segments still misaligned"
v16=$(guest /tmp/t3-16k --version 2>&1 | tail -n1)
guest /tmp/t3-16k --version > /dev/null 2>&1 && pass "realigned binary still runs ($v16)" || fail "realigned binary does not run: $v16"
guest rm -f /tmp/t3-16k

section "Stop"
t3code stop
sleep 3
env_json > /dev/null 2>&1 && fail "still serving after stop" || pass "stopped cleanly"

section "Doctor"
t3code doctor || true

finish
