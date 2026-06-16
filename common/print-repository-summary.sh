#!/usr/bin/env bash
set -euo pipefail

metadata_dir="public/publisher-metadata"

echo "Targets published:"
if [[ -f "$metadata_dir/targets.txt" ]]; then
  sed '/^[[:space:]]*$/d' "$metadata_dir/targets.txt" | sort -u | sed 's/^/- /'
else
  echo "- none recorded"
fi

echo "Packages detected:"
if [[ -f "$metadata_dir/packages.txt" ]]; then
  sed '/^[[:space:]]*$/d' "$metadata_dir/packages.txt" | sort -u | sed 's/^/- /'
else
  echo "- none recorded"
fi

echo "Repository files generated:"
if [[ -f "$metadata_dir/repos.tsv" ]]; then
  awk -F '\t' 'NF >= 2 && $2 != "" { print "- " $2 }' "$metadata_dir/repos.tsv" | sort -u
else
  echo "- none recorded"
fi
