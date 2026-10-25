#!/bin/bash
# Realigns T3 Code's arm64 binary for 64 KB pages (as install.sh does on 16 KB/64 KB
# page devices) and runs it natively, so a broken realignment shows up with details.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
sudo apt-get install -y -q strace > /dev/null
python3 tests/extract-embedded.py install.sh embedded > /dev/null

v=$(curl -fsSL https://registry.npmjs.org/-/package/t3/dist-tags | jq -r .nightly)
curl -fsSL -o t3.tgz "https://github.com/pingdotgg/t3code/releases/download/v$v/t3-$v-linux-arm64.tar.gz"
mkdir -p t3 && tar -xzf t3.tgz -C t3 --strip-components=1
headers() { readelf -lW "$1" | sed -n '/Program Headers/,/Section to Segment/p'; }

echo "== original ($v)"; headers t3/t3
./t3/t3 --version || { echo "the original binary does not run"; exit 1; }

# The executable loads node_modules from its own directory, so realign a full copy.
cp -a t3 t3-16k
node embedded/t3a_elf.js t3-16k/t3 65536
echo "== realigned"; headers t3-16k/t3
# The other native files the runtime ships must already be 64 KB-congruent.
for f in t3-16k/resource-monitor/linux-arm64/t3-resource-monitor t3-16k/node_modules/@napi-rs/keyring-linux-arm64-gnu/*.node; do
  node -e '
    const b = require("fs").readFileSync(process.argv[1]);
    const off = Number(b.readBigUInt64LE(32)), sz = b.readUInt16LE(54), n = b.readUInt16LE(56);
    for (let i = 0; i < n; i++) {
      const p = off + i * sz;
      if (b.readUInt32LE(p) !== 1) continue;
      const o = b.readBigUInt64LE(p + 8), v = b.readBigUInt64LE(p + 16);
      console.log(`${process.argv[1]}: LOAD 0x${v.toString(16)} ${(v - o) % 65536n === 0n ? "ok" : "MISALIGNED"}`);
    }' "$f"
done
if ./t3-16k/t3 --version && ./t3-16k/t3 __service-preflight --database-path /tmp/x.sqlite --launcher-protocol 3; then
  echo "realigned binary runs"
  exit 0
fi
echo "realigned binary failed; tracing"
strace -f -o strace.txt ./t3-16k/t3 --version
grep -v -E 'futex|rt_sig' strace.txt | tail -n 60
exit 1
