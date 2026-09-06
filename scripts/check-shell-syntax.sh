#!/usr/bin/env sh
# install.sh and every script under scripts/ must parse. This repository is documentation
# plus these scripts, so a syntax error surfaces the first time someone dispatches a worker
# rather than here.
#
# bash -n uses exit 2 for a syntax error, which collides with "this check could not run".
# The two are separated: only a missing bash is 2, a broken script is always 1.
set -u
cd "$(dirname "$0")/.." || exit 2
command -v bash >/dev/null 2>&1 || { echo "no bash on this machine"; exit 2; }

bad=0
n=0
for f in install.sh scripts/*.sh; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  if ! bash -n "$f" 2>&1; then
    echo "$f: does not parse"
    bad=1
  fi
done
[ "$bad" -eq 0 ] || exit 1
echo "$n scripts parse"
