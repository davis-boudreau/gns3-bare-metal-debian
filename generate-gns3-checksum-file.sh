#!/usr/bin/env bash
set -euo pipefail

read -r -p "Enter the path to the image file: " file

# Trim whitespace
file="${file#"${file%%[![:space:]]*}"}"
file="${file%"${file##*[![:space:]]}"}"

if [[ -z "$file" ]]; then
  echo "No file provided." >&2
  exit 1
fi

if [[ ! -f "$file" ]]; then
  echo "File not found: $file" >&2
  exit 1
fi

# Detect platform and compute MD5
if command -v md5sum >/dev/null 2>&1; then
  # Linux (and some macs with coreutils)
  hash=$(md5sum -- "$file" | awk '{print tolower($1)}')
elif command -v md5 >/dev/null 2>&1; then
  # macOS default `md5` tool
  # Output format: MD5 (filename) = HASH
  hash=$(md5 -q -- "$file" | tr 'A-F' 'a-f')
else
  echo "Neither md5sum nor md5 found on this system." >&2
  exit 1
fi

# Build output filename: <original-filename>.md5sum (no path)
base="$(basename -- "$file")"
out="${base}.md5sum"

# Two spaces between hash and filename, as expected by GNS3
printf "%s  %s\n" "$hash" "$base" > "$out"

echo "Wrote MD5 to: $out"
echo "Contents:"
cat "$out"
