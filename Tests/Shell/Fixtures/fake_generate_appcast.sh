#!/usr/bin/env bash
set -euo pipefail

if [ "${FAKE_GENERATE_APPCAST_IGNORE_TERM_AND_HANG:-0}" = "1" ]; then
  trap '' TERM
  /usr/bin/printf '%s\n' "$$" > "$FAKE_GENERATE_APPCAST_PID_FILE"
  while :; do
    :
  done
fi

output=""
for ((argument_index = 1; argument_index <= $#; argument_index += 1)); do
  argument="${!argument_index}"
  [ "$argument" != "fixture-private-key" ] || {
    echo "private key was exposed in argv" >&2
    exit 1
  }
  if [ "$argument" = "-o" ]; then
    output_index=$((argument_index + 1))
    output="${!output_index}"
  fi
done

if /usr/bin/env | /usr/bin/grep -Fq 'fixture-private-key'; then
  echo "private key was exposed in the environment" >&2
  exit 1
fi

IFS= read -r private_key
[ "$private_key" = "fixture-private-key" ] || {
  echo "private key was not provided on standard input" >&2
  exit 1
}
[ -n "$output" ] || {
  echo "missing appcast output argument" >&2
  exit 1
}

/usr/bin/printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">' \
  '  <channel>' \
  '    <item><enclosure sparkle:edSignature="fixture-signature"/></item>' \
  '  </channel>' \
  '  <!-- sparkle-signatures:' \
  'edSignature: fixture-feed-signature' \
  '  -->' \
  '</rss>' > "$output"
/usr/bin/printf 'invoked\n' > "$FAKE_APPCAST_MARKER"
