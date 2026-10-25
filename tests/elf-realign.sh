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

cp t3/t3 t3-16k
node embedded/t3a_elf.js t3-16k 65536
echo "== realigned"; headers t3-16k
if ./t3-16k --version; then
  echo "realigned binary runs"
  ./t3-16k __service-preflight --database-path /tmp/x.sqlite --launcher-protocol 3
  exit 0
fi
echo "realigned binary failed (exit $?); tracing"
strace -f -o strace.txt ./t3-16k --version
grep -v -E 'futex|rt_sig' strace.txt | tail -n 60
exit 1
