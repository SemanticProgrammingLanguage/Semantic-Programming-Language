#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
chmod +x ./masplc
mkdir -p proof
rm -f proof/stage-next proof/stage-next2 proof/from-smod

if grep -Eq 'field\.i|selfhost\.x64' src/msplc-selfhost.se; then
  echo "SELFHOST FAIL: legacy microcode marker found"
  exit 1
fi

./masplc compile src/msplc-selfhost.se -o proof/stage-next
chmod +x proof/stage-next
./proof/stage-next compile src/msplc-selfhost.se -o proof/stage-next2
chmod +x proof/stage-next2

./masplc compile masplc.smod -o proof/from-smod
chmod +x proof/from-smod

h0=$(sha256sum ./masplc | awk '{print $1}')
h1=$(sha256sum proof/stage-next | awk '{print $1}')
h2=$(sha256sum proof/stage-next2 | awk '{print $1}')
hm=$(sha256sum proof/from-smod | awk '{print $1}')

echo "installed : $h0"
echo "stage-next: $h1"
echo "stage-next2: $h2"
echo "from-smod : $hm"

cmp -s ./masplc proof/stage-next
cmp -s proof/stage-next proof/stage-next2
cmp -s ./masplc proof/from-smod

echo "SELFHOST PASS - UAST .se and .smod both reproduce MSPLC byte-for-byte"
