#!/usr/bin/env bash
# Usage: tools/bump_version.sh <new_version>   e.g. tools/bump_version.sh 0.13.7.2
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
new="$1"
old="$(sed -n "s/.*EXTENSION_VERSION = '\([0-9.]*\)'.*/\1/p" "$here/src/su_linkhub.rb" | head -1)"
sed -i "s/EXTENSION_VERSION = '$old'/EXTENSION_VERSION = '$new'/" "$here/src/su_linkhub.rb" "$here/src/su_linkhub/constants.rb"
sed -i "s/_v$old\.log/_v$new.log/g" "$here/src/su_linkhub/constants.rb"
echo "$old -> $new"
