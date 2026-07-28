#!/usr/bin/env bash
set -euo pipefail

explicit_identity="${1:-}"
if [ -n "$explicit_identity" ]; then
  /usr/bin/printf '%s\n' "$explicit_identity"
  exit 0
fi

/usr/bin/awk '
  /"Apple Development:/ &&
      length($2) == 40 &&
      $2 ~ /^[[:xdigit:]]+$/ &&
      selected == "" {
    selected = $2
  }
  END {
    if (selected != "") {
      print selected
    }
  }
'
