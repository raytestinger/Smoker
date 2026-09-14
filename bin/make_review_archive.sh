#!/usr/bin/env bash
#
# make_review_archive.sh
#
# Create a compact review archive from a Smoker test batch.
#
# Usage:
#   make_review_archive.sh /path/to/test_batch
#

set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $(basename "$0") TEST_BATCH_DIRECTORY"
    exit 1
fi

BATCH="$(realpath "$1")"

if [[ ! -d "$BATCH" ]]; then
    echo "ERROR: batch directory not found:"
    echo "  $BATCH"
    exit 1
fi

NAME="$(basename "$BATCH")"
OUT="${NAME}_review.tar.gz"

TMP="$(mktemp)"

cleanup() {
    rm -f "$TMP"
}
trap cleanup EXIT

cd "$BATCH"

#
# Top-level files worth reviewing.
#

find . -maxdepth 1 -type f \
    \( \
        -name summary.csv \
        -o -name original_plan.csv \
        -o -name plan_deduplicated.csv \
        -o -name skipped_dup.csv \
        -o -name batch_review.txt \
        -o -name validation_evidence.txt \
        -o -name '*.manifest.json' \
        -o -name '*.json' \
    \) \
    | sort >>"$TMP"

#
# Scheduler log is stored below the batch root.
#

if [[ -f logs/run_smoker.log ]]; then
    printf '%s\n' logs/run_smoker.log >>"$TMP"
fi

#
# Per-run metadata.
#

find runs \
    \( \
        -name rc.code \
        -o -name result.meta \
        -o -name unavailable.note \
    \) \
    | sort >>"$TMP"

COUNT=$(wc -l <"$TMP")

tar -czf "$OUT" -T "$TMP"

echo
echo "Review archive created:"
echo "  $OUT"
echo
echo "Files included: $COUNT"
echo
ls -lh "$OUT"
