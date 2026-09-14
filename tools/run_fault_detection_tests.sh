#!/usr/bin/env bash
# Self-checking acceptance harness for validate_smoker_batch.pl.
#
# Each fault-test row is executed independently:
#   1. copy a known-good completed batch;
#   2. rebase embedded absolute batch paths to the copy;
#   3. inject exactly one defect;
#   4. immediately run the validator;
#   5. check its exit status and the intended report diagnostic.
#
# Usage:
#   run_fault_detection_tests.sh CLEAN_BATCH [FAULT_ROOT] [VALIDATOR]
#
# Example:
#   bin/run_fault_detection_tests.sh \
#     test_results/16_tests_20260730_182823 \
#     fault_tests \
#     bin/validate_smoker_batch.pl

set -uo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: run_fault_detection_tests.sh CLEAN_BATCH [FAULT_ROOT] [VALIDATOR]

  CLEAN_BATCH  Completed, known-good Smoker batch directory.
  FAULT_ROOT   Disposable output directory (default: ./fault_tests_generated).
  VALIDATOR    validate_smoker_batch.pl path
               (default: $SMOKER_HOME/bin/validate_smoker_batch.pl,
               or inferred from this script's parent directory).
USAGE
    exit 2
}

[[ $# -ge 1 && $# -le 3 ]] || usage

clean_batch=$(readlink -f -- "$1")
fault_root_input=${2:-"$PWD/fault_tests_generated"}
fault_root=$(readlink -m -- "$fault_root_input")

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
inferred_home=$(cd -- "$script_dir/.." 2>/dev/null && pwd -P || true)
validator_input=${3:-"${SMOKER_HOME:-$inferred_home}/bin/validate_smoker_batch.pl"}
validator=$(readlink -f -- "$validator_input" 2>/dev/null || true)

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

[[ -n $validator && -f $validator ]] || {
    echo "ERROR: validator not found: $validator_input" >&2
    exit 2
}

# Refuse dangerous output roots.
case "$fault_root" in
    /|/home|/home/*/Smoker|"$clean_batch"|"$clean_batch"/*)
        echo "ERROR: unsafe FAULT_ROOT: $fault_root" >&2
        exit 2
        ;;
esac

mkdir -p -- "$fault_root"
results_tsv="$fault_root/fault_test_results.tsv"
summary_txt="$fault_root/fault_test_summary.txt"
: > "$results_tsv"
printf 'test\texpected\tvalidator_rc\treport_check\tresult\n' > "$results_tsv"

passed=0
failed=0
current_batch=''
current_report=''

cleanup_current() {
    [[ -n $current_batch ]] || return 0
    rm -rf -- "$current_batch"
}
trap cleanup_current INT TERM

rebase_batch_paths() {
    local batch=$1
    local old=$clean_batch

    # summary.csv and result.meta contain absolute run_dir paths. A copied
    # batch must refer to its own runs, not back to the known-good source.
    OLD_BATCH=$old NEW_BATCH=$batch perl -pi -e '
        BEGIN {
            $old = quotemeta($ENV{OLD_BATCH});
            $new = $ENV{NEW_BATCH};
        }
        s/$old/$new/g;
    ' "$batch/summary.csv" "$batch"/runs/*/result.meta

    # Batch metadata and prior reports are historical. Rebase metadata for
    # audit clarity, and remove reports that could be mistaken for new output.
    if [[ -f "$batch/batch_info.txt" ]]; then
        OLD_BATCH=$old NEW_BATCH=$batch perl -pi -e '
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
    current_batch="$fault_root/$name"
    current_report="$current_batch/validation_evidence.txt"

    rm -rf -- "$current_batch"
    cp -a -- "$clean_batch" "$current_batch"
    rebase_batch_paths "$current_batch"
}

run_validator() {
    local stdout_file="$current_batch/fault_validator.stdout"
    local stderr_file="$current_batch/fault_validator.stderr"

    rm -f -- "$current_report" "$stdout_file" "$stderr_file"

    perl "$validator" "$current_batch" "$current_report" \
        >"$stdout_file" 2>"$stderr_file"
    return $?
}

record_result() {
    local name=$1 expected=$2 rc=$3 check=$4 result=$5
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$expected" "$rc" "$check" "$result" >> "$results_tsv"
}

check_report_patterns() {
    local report=$1
    shift
    local pattern

    for pattern in "$@"; do
        if ! grep -Fq -- "$pattern" "$report"; then
            echo "    missing report diagnostic: $pattern"
            return 1
        fi
    done
    return 0
}

run_case() {
    local name=$1
    local expected_rc=$2       # zero | nonzero
    local injector=$3
    shift 3
    local patterns=("$@")
    local rc=0 rc_ok=0 report_ok=0 check_text

    printf '\n[%02d] %s\n' "$((passed + failed + 1))" "$name"
    prepare_case "$name"

    if ! "$injector" "$current_batch"; then
        echo "  HARNESS ERROR: fault injection failed"
        record_result "$name" "$expected_rc" '-' 'injection failed' 'FAIL'
        failed=$((failed + 1))
        return
    fi

    run_validator
    rc=$?

    if [[ $expected_rc == zero ]]; then
        [[ $rc -eq 0 ]] && rc_ok=1
    else
        [[ $rc -ne 0 ]] && rc_ok=1
    fi

    if [[ -f $current_report ]]; then
        if check_report_patterns "$current_report" "${patterns[@]}"; then
            report_ok=1
        fi
    else
        echo "    validator wrote no report: $current_report"
    fi

    check_text=$(IFS=' ; '; printf '%s' "${patterns[*]}")

    if [[ $rc_ok -eq 1 && $report_ok -eq 1 ]]; then
        echo "  PASS: validator rc=$rc; intended defect detected"
        record_result "$name" "$expected_rc" "$rc" "$check_text" 'PASS'
        passed=$((passed + 1))
    else
        echo "  FAIL: validator rc=$rc; expected $expected_rc"
        echo "        stdout: $current_batch/fault_validator.stdout"
        echo "        stderr: $current_batch/fault_validator.stderr"
        echo "        report: $current_report"
        record_result "$name" "$expected_rc" "$rc" "$check_text" 'FAIL'
        failed=$((failed + 1))
    fi
}

# ------------------------- fault injectors -------------------------

inject_none() {
    return 0
}

inject_missing_rc() {
    rm -f -- "$1/runs/000001/rc.code"
}

inject_missing_meta() {
    rm -f -- "$1/runs/000001/result.meta"
}

inject_missing_run() {
    rm -rf -- "$1/runs/000001"
}

inject_extra_run() {
    cp -a -- "$1/runs/000001" "$1/runs/999999"
    # Make the extra directory internally self-identify as 999999, while
    # deliberately leaving it absent from summary.csv.
    perl -pi -e 's/^run_id=000001$/run_id=999999/' \
        "$1/runs/999999/result.meta"
    perl -pi -e 's{/000001$}{/999999}' \
        "$1/runs/999999/result.meta"
}

inject_rc_mismatch() {
    printf '2\n' > "$1/runs/000001/rc.code"
}

inject_meta_mismatch() {
    perl -pi -e 's/^rc=0$/rc=2/' "$1/runs/000001/result.meta"
}

inject_duplicate_summary() {
    tail -n 1 -- "$1/summary.csv" >> "$1/summary.csv"
}

inject_missing_summary_row() {
    local file="$1/summary.csv"
    local tmp="$file.tmp.$$"
    sed '$d' "$file" > "$tmp" && mv -- "$tmp" "$file"
}

inject_bad_dedup() {
    tail -n 1 -- "$1/plan_deduplicated.csv" \
        >> "$1/plan_deduplicated.csv"
}

inject_unclassified() {
    local file="$1/summary.csv"
    local tmp="$file.tmp.$$"

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
    ' "$file" "$tmp" && mv -- "$tmp" "$file"

    # Existing classification evidence describes the original clean batch;
    # remove it so it cannot mask the mutated status.
    rm -f -- "$1/result_classification_audit.txt"
}

# -------------------------- test-plan rows -------------------------
# The validator runs immediately after every row below.

run_case clean_control zero inject_none \
    'Assessment: PASS' \
    'Expected execution path result: PASS'

run_case fault_missing_rc nonzero inject_missing_rc \
    'Run directories with rc.code/result.meta/execution-trail quality issues: 1' \
    'Assessment: FAIL'

run_case fault_missing_meta nonzero inject_missing_meta \
    'Run directories with rc.code/result.meta/execution-trail quality issues: 1' \
    'Assessment: FAIL'

run_case fault_missing_run nonzero inject_missing_run \
    'Summary rows with missing run directories: 1' \
    'Assessment: FAIL'

run_case fault_extra_run nonzero inject_extra_run \
    'Run directories not represented in summary.csv: 1' \
    'Assessment: FAIL'

run_case fault_rc_mismatch nonzero inject_rc_mismatch \
    'summary.csv vs rc.code return-code mismatches: 1' \
    'Assessment: FAIL'

run_case fault_meta_mismatch nonzero inject_meta_mismatch \
    'rc.code vs result.meta return-code mismatches: 1' \
    'Assessment: FAIL'

run_case fault_duplicate_summary nonzero inject_duplicate_summary \
    'summary.csv exact duplicate groups: 1' \
    'summary.csv extra duplicate rows: 1' \
    'Assessment: FAIL'

run_case fault_missing_summary_row nonzero inject_missing_summary_row \
    'Run directories not represented in summary.csv: 1' \
    'Assessment: FAIL'

run_case fault_bad_dedup nonzero inject_bad_dedup \
    'Deduplicated CSV matches recomputation: FAIL' \
    'Assessment: FAIL'

run_case fault_unclassified nonzero inject_unclassified \
    'Unclassified: 1' \
    'Assessment: FAIL'

# ---------------------------- summary ------------------------------

{
    echo
    echo 'FAULT-DETECTION ACCEPTANCE SUMMARY'
    echo '=================================='
    printf 'Passed: %d\n' "$passed"
    printf 'Failed: %d\n' "$failed"
    printf 'Total:  %d\n' "$((passed + failed))"
    echo "Results: $results_tsv"
} | tee "$summary_txt"

if [[ $failed -ne 0 ]]; then
    exit 1
fi

exit 0
