#!/usr/bin/env bash
set -euo pipefail

usage() {
cat <<'EOF'
Usage:
  clean_plan_workspace.sh [--dry-run] [--help]

Removes generated plan-builder artifacts while preserving scripts.

Deleted patterns:
  *.raw.csv
  *.unique.csv
  *.balanced.csv
  *.final.csv
  *.duplicates.csv
  *.manifest.json
  *.analysis.txt
  *.analysis.json

Also removes:
  dedup_test.input.csv
  dedup_test.shuffled.csv

Preserved:
  *.pl
  *.sh
EOF
}

dry_run=0
case "${1:-}" in
  --dry-run) dry_run=1;;
  --help|-h) usage; exit 0;;
  "") ;;
  *) echo "Unknown option: $1" >&2; usage; exit 1;;
esac

patterns=(
  "*.raw.csv"
  "*.unique.csv"
  "*.balanced.csv"
  "*.final.csv"
  "*.duplicates.csv"
  "*.manifest.json"
  "*.analysis.txt"
  "*.analysis.json"
  "dedup_test.input.csv"
  "dedup_test.shuffled.csv"
)

shopt -s nullglob

count=0
for pat in "${patterns[@]}"; do
  for f in $pat; do
    if ((dry_run)); then
      printf 'Would remove: %s\n' "$f"
    else
      rm -f -- "$f"
      printf 'Removed: %s\n' "$f"
    fi
    count=$((count+1))
  done
done

if ((dry_run)); then
  printf '\nFiles that would be removed: %d\n' "$count"
else
  printf '\nFiles removed: %d\n' "$count"
fi
