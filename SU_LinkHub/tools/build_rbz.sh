#!/usr/bin/env bash
# Build SU_LinkHub rbz from SU_LinkHub/src. Usage: tools/build_rbz.sh
# Output: SU_LinkHub/releases/SU_LinkHub_v<version>.rbz
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
ver="$(sed -n "s/.*EXTENSION_VERSION = '\([0-9.]*\)'.*/\1/p" "$here/src/su_linkhub.rb" | head -1)"
cv="$(sed -n "s/.*EXTENSION_VERSION = '\([0-9.]*\)'.*/\1/p" "$here/src/su_linkhub/constants.rb" | head -1)"
[ "$ver" = "$cv" ] || { echo "version mismatch: su_linkhub.rb=$ver constants.rb=$cv" >&2; exit 1; }
for f in "$here"/src/su_linkhub.rb "$here"/src/su_linkhub/*.rb; do ruby -c "$f" >/dev/null; done
out="$here/releases/SU_LinkHub_v$ver.rbz"
rm -f "$out"
(cd "$here/src" && zip -q -r -X -D "$out" . -x '*.DS_Store')
echo "$out"
