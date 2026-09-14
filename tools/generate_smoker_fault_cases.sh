#!/usr/bin/env bash
# Generate independent, disposable fault-injection copies of a known-good
# completed Smoker batch. This script does not run the validator.
#
# Usage:
#   generate_smoker_fault_cases.sh CLEAN_BATCH CASES_DIR
#
# Outputs:
#   CASES_DIR/clean_control/
#   CASES_DIR/fault_*/
#   CASES_DIR/fault_cases.tsv

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: generate_smoker_fault_cases.sh CLEAN_BATCH CASES_DIR

  CLEAN_BATCH  Completed, known-good Smoker batch directory.
  CASES_DIR    Disposable directory in which fault cases are generated.
USAGE
    exit 2
}

[[ $# -eq 2 ]] || usage

clean_batch=$(readlink -f -- "$1")
cases_dir=$(readlink -m -- "$2")

[[ -d $clean_batch ]] || {
    echo "ERROR: clean batch directory not found: $clean_batch" >&2
    exit 2
}

for required in original_plan.csv plan_deduplicated.csv summary.csv runs; do
    [[ -e "$clean_batch/$required" ]] || {
        echo "ERROR: clean batch lacks required item: $clean_batch/$required" >&2
        exit 2
    }
done

case "$cases_dir" in
    /|/home|/home/*/Smoker|"$clean_batch"|"$clean_batch"/*)
        echo "ERROR: unsafe CASES_DIR: $cases_dir" >&2
        exit 2
        ;;
esac

rm -rf -- "$cases_dir"
mkdir -p -- "$cases_dir"
manifest="$cases_dir/fault_cases.tsv"
printf 'case_name\texpected_rc\texpected_diagnostics\n' > "$manifest"

rebase_batch_paths() {
    local batch=$1

    OLD_BATCH=$clean_batch NEW_BATCH=$batch perl -pi -e '
        BEGIN {
            $old = quotemeta($ENV{OLD_BATCH});
            $new = $ENV{NEW_BATCH};
        }
        s/$old/$new/g;
    ' "$batch/summary.csv" "$batch"/runs/*/result.meta

    if [[ -f "$batch/batch_info.txt" ]]; then
        OLD_BATCH=$clean_batch NEW_BATCH=$batch perl -pi -e '
            BEGIN {
                $old = quotemeta($ENV{OLD_BATCH});
                $new = $ENV{NEW_BATCH};
            }
            s/$old/$new/g;
        ' "$batch/batch_info.txt"
    fi

    rm -f -- \
        "$batch/validation_evidence.txt" \
        "$batch/fault_validator.stdout" \
        "$batch/fault_validator.stderr"
}

prepare_case() {
    local name=$1
    local batch="$cases_dir/$name"

    cp -a -- "$clean_batch" "$batch"
    rebase_batch_paths "$batch"
    printf '%s\n' "$batch"
}

add_manifest_row() {
    local name=$1
    local expected_rc=$2
    shift 2
    local diagnostics
    diagnostics=$(IFS='|'; printf '%s' "$*")
    printf '%s\t%s\t%s\n' "$name" "$expected_rc" "$diagnostics" >> "$manifest"
}

# Clean control.
batch=$(prepare_case clean_control)
add_manifest_row clean_control zero \
    'Assessment: PASS' \
    'Expected execution path result: PASS'

# Missing rc.code.
batch=$(prepare_case fault_missing_rc)
rm -f -- "$batch/runs/000001/rc.code"
add_manifest_row fault_missing_rc nonzero \
    'Run directories with rc.code/result.meta/execution-trail quality issues: 1' \
    'Assessment: FAIL'

# Missing result.meta.
batch=$(prepare_case fault_missing_meta)
rm -f -- "$batch/runs/000001/result.meta"
add_manifest_row fault_missing_meta nonzero \
    'Run directories with rc.code/result.meta/execution-trail quality issues: 1' \
    'Assessment: FAIL'

# Missing run directory.
batch=$(prepare_case fault_missing_run)
rm -rf -- "$batch/runs/000001"
add_manifest_row fault_missing_run nonzero \
    'Summary rows with missing run directories: 1' \
    'Assessment: FAIL'

# Extra unreported run directory.
batch=$(prepare_case fault_extra_run)
cp -a -- "$batch/runs/000001" "$batch/runs/999999"
perl -pi -e 's/^run_id=000001$/run_id=999999/' \
    "$batch/runs/999999/result.meta"
perl -pi -e 's{/000001$}{/999999}' \
    "$batch/runs/999999/result.meta"
add_manifest_row fault_extra_run nonzero \
    'Run directories not represented in summary.csv: 1' \
    'Assessment: FAIL'

# summary.csv versus rc.code mismatch.
batch=$(prepare_case fault_rc_mismatch)
printf '2\n' > "$batch/runs/000001/rc.code"
add_manifest_row fault_rc_mismatch nonzero \
    'summary.csv vs rc.code return-code mismatches: 1' \
    'Assessment: FAIL'

# rc.code versus result.meta mismatch.
batch=$(prepare_case fault_meta_mismatch)
perl -pi -e 's/^rc=0$/rc=2/' "$batch/runs/000001/result.meta"
add_manifest_row fault_meta_mismatch nonzero \
    'rc.code vs result.meta return-code mismatches: 1' \
    'Assessment: FAIL'

# Duplicate summary row.
batch=$(prepare_case fault_duplicate_summary)
tail -n 1 -- "$batch/summary.csv" >> "$batch/summary.csv"
add_manifest_row fault_duplicate_summary nonzero \
    'summary.csv exact duplicate groups: 1' \
    'summary.csv extra duplicate rows: 1' \
    'Assessment: FAIL'

# Missing summary row.
batch=$(prepare_case fault_missing_summary_row)
tmp="$batch/summary.csv.tmp.$$"
sed '$d' "$batch/summary.csv" > "$tmp"
mv -- "$tmp" "$batch/summary.csv"
add_manifest_row fault_missing_summary_row nonzero \
    'Run directories not represented in summary.csv: 1' \
    'Assessment: FAIL'

# Bad deduplicated-plan accounting.
batch=$(prepare_case fault_bad_dedup)
tail -n 1 -- "$batch/plan_deduplicated.csv" \
    >> "$batch/plan_deduplicated.csv"
add_manifest_row fault_bad_dedup nonzero \
    'Deduplicated CSV matches recomputation: FAIL' \
    'Assessment: FAIL'

# Unsupported status classification.
batch=$(prepare_case fault_unclassified)
tmp="$batch/summary.csv.tmp.$$"
perl -MText::CSV -e '
    use strict;
    use warnings;
    my ($in_path, $out_path) = @ARGV;
    my $csv = Text::CSV->new({ binary => 1, auto_diag => 2 });
    open my $in,  "<", $in_path  or die "$in_path: $!\n";
    open my $out, ">", $out_path or die "$out_path: $!\n";
    my $header = $csv->getline($in) or die "missing CSV header\n";
    my %col; @col{@$header} = 0 .. $#$header;
    die "missing status column\n" unless exists $col{status};
    $csv->say($out, $header);
    my $changed = 0;
    while (my $row = $csv->getline($in)) {
        if (!$changed) {
            $row->[$col{status}] = "MYSTERY";
            $changed = 1;
        }
        $csv->say($out, $row);
    }
    close $out or die "$out_path: $!\n";
    close $in  or die "$in_path: $!\n";
    die "no data row changed\n" unless $changed;
' "$batch/summary.csv" "$tmp"
mv -- "$tmp" "$batch/summary.csv"
rm -f -- "$batch/result_classification_audit.txt"
add_manifest_row fault_unclassified nonzero \
    'Unclassified: 1' \
    'Assessment: FAIL'

printf 'Generated %d cases in %s\n' "$(( $(wc -l < "$manifest") - 1 ))" "$cases_dir"
printf 'Manifest: %s\n' "$manifest"
