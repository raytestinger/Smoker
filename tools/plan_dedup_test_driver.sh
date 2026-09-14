#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

input="dedup_test.input.csv"
output="dedup_test.unique.csv"
duplicates="dedup_test.duplicates.csv"

rm -f "$input" "$output" "$duplicates"

cat > "$input" <<'CSV'
"base","mode","module","version","dep_one","dep_one_version","dep_two","dep_two_version"
"perl:5.38","baseline","DateTime","1.65","","","",""
"perl:5.38","baseline","DateTime","1.65","","","",""
"perl:5.38","vary-one","DateTime","1.65","Specio","0.48","",""
"perl:5.38","vary-two","DateTime","1.65","Specio","0.48","Params::ValidationCompiler","0.30"
"perl:5.38","vary-two","DateTime","1.65","Params::ValidationCompiler","0.30","Specio","0.48"
CSV

perl -c plan_dedup.pl

perl plan_dedup.pl \
    --input "$input" \
    --output "$output" \
    --duplicates-output "$duplicates"

input_rows=$(($(wc -l < "$input") - 1))
output_rows=$(($(wc -l < "$output") - 1))
duplicate_rows=$(($(wc -l < "$duplicates") - 1))
unique_output_rows=$(tail -n +2 "$output" | sort -u | wc -l)

printf 'Input rows:             %d\n' "$input_rows"
printf 'Unique rows written:    %d\n' "$output_rows"
printf 'Duplicate rows removed: %d\n' "$duplicate_rows"
printf 'Unique output rows:     %d\n' "$unique_output_rows"

test "$input_rows" -eq 5
test "$output_rows" -eq 3
test "$duplicate_rows" -eq 2
test "$unique_output_rows" -eq 3

echo "plan_dedup.pl test: PASS"
