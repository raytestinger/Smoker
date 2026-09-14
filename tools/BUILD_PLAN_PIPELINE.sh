#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

source_packages_index="$HOME/Smoker/minicpan/modules/02packages.details.txt.gz"
packages_index=""
module_input=""
randomized_index_name="02packages.details.randomized.txt.gz"
prefix="plan"
target_modules=100
module_limit=0
perl_versions="5.38"
max_deps=3
max_versions=2
max_pairs=0
selection_mode="ordered"
version_sampling="spread"
pair_mode="cross"
seed=20260724
sleep_ms=0

usage() {
    cat <<'USAGE'
Usage:
  BUILD_PLAN_PIPELINE.sh --packages-index FILE [options]
  BUILD_PLAN_PIPELINE.sh --input FILE [options]

Inputs:
  --packages-index FILE      Source CPAN index to copy and randomize
                             (default: $HOME/Smoker/minicpan/modules/02packages.details.txt.gz)
  --input FILE               Text file containing one target module per line

Output naming:
  --prefix NAME              Output prefix (default: plan)

Builder controls:
  --target-modules N         Successfully planned unique modules (default: 10)
  --module-limit N           Maximum candidate modules examined; 0 is unlimited (default: 0)
  --perl-versions LIST       Comma-separated Perl versions (default: 5.38)
  --max-deps N               Maximum dependencies per module (default: 3)
  --max-versions N           Maximum versions per dependency (default: 2)
  --max-pairs N              Maximum dependency pairs; 0 means unlimited
  --selection-mode MODE      ordered|random|balanced (default: ordered)
  --version-sampling MODE    recent|spread (default: spread)
  --pair-mode MODE           zip|grid|cross (default: cross)
  --seed N                   Reproducible random seed (default: 20260724)
  --sleep-ms N               MetaCPAN pause in milliseconds (default: 0)

Other:
  --help                     Show this help

Files produced:
  PREFIX.raw.csv
  PREFIX.manifest.json
  PREFIX.unique.csv
  PREFIX.duplicates.csv
  PREFIX.balanced.csv
  PREFIX.final.csv
  PREFIX.analysis.txt
  PREFIX.analysis.json
USAGE
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        --packages-index)
            (($# >= 2)) || die "--packages-index requires a value"
            source_packages_index=$2
            shift 2
            ;;
        --input)
            (($# >= 2)) || die "--input requires a value"
            module_input=$2
            shift 2
            ;;
        --prefix)
            (($# >= 2)) || die "--prefix requires a value"
            prefix=$2
            shift 2
            ;;
        --target-modules)
            (($# >= 2)) || die "--target-modules requires a value"
            target_modules=$2
            shift 2
            ;;
        --module-limit)
            (($# >= 2)) || die "--module-limit requires a value"
            module_limit=$2
            shift 2
            ;;
        --perl-versions)
            (($# >= 2)) || die "--perl-versions requires a value"
            perl_versions=$2
            shift 2
            ;;
        --max-deps)
            (($# >= 2)) || die "--max-deps requires a value"
            max_deps=$2
            shift 2
            ;;
        --max-versions)
            (($# >= 2)) || die "--max-versions requires a value"
            max_versions=$2
            shift 2
            ;;
        --max-pairs)
            (($# >= 2)) || die "--max-pairs requires a value"
            max_pairs=$2
            shift 2
            ;;
        --selection-mode)
            (($# >= 2)) || die "--selection-mode requires a value"
            selection_mode=$2
            shift 2
            ;;
        --version-sampling)
            (($# >= 2)) || die "--version-sampling requires a value"
            version_sampling=$2
            shift 2
            ;;
        --pair-mode)
            (($# >= 2)) || die "--pair-mode requires a value"
            pair_mode=$2
            shift 2
            ;;
        --seed)
            (($# >= 2)) || die "--seed requires a value"
            seed=$2
            shift 2
            ;;
        --sleep-ms)
            (($# >= 2)) || die "--sleep-ms requires a value"
            sleep_ms=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

printf '\n[0/6] Cleaning previous plan artifacts\n'
"$SCRIPT_DIR/clean_plan_workspace.sh"

if [[ -n $module_input ]]; then
    packages_index=""
else
    [[ -f $source_packages_index ]]         || die "packages index not found: $source_packages_index"

    copied_index="$SCRIPT_DIR/02packages.details.txt.gz"
    randomized_index="$SCRIPT_DIR/$randomized_index_name"

    printf '\n[1/6] Preparing randomized packages index\n'
    cp -f -- "$source_packages_index" "$copied_index"

    gzip -dc -- "$copied_index" |
    perl -e '
        use strict;
        use warnings;
        use List::Util qw(shuffle);

        my @header;
        my @rows;
        my $in_body = 0;

        while (my $line = <STDIN>) {
            if (!$in_body) {
                push @header, $line;
                $in_body = 1 if $line =~ /^\s*$/;
                next;
            }

            push @rows, $line if $line !~ /^\s*$/;
        }

        print @header;
        print shuffle(@rows);
    ' |
    gzip -c > "$randomized_index"

    packages_index="$randomized_index"

    printf 'Copied index:          %s\n' "$copied_index"
    printf 'Randomized index:      %s\n' "$randomized_index"
fi

for command in gzip perl; do
    command -v "$command" >/dev/null 2>&1         || die "required command not found: $command"
done

for tool in \
    clean_plan_workspace.sh \
    build_plan.pl \
    plan_dedup.pl \
    plan_balance.pl \
    plan_shuffle.pl \
    plan_analyze.pl
do
    [[ -x "$SCRIPT_DIR/$tool" ]] || die "missing executable tool: $SCRIPT_DIR/$tool"
done

if [[ -n $module_input ]]; then
    [[ -f $module_input ]] || die "module list not found: $module_input"
    source_args=(--input "$module_input")
else
    [[ -f $packages_index ]] || die "randomized packages index not found: $packages_index"
    source_args=(--packages-index "$packages_index")
fi

raw="${prefix}.raw.csv"
manifest="${prefix}.manifest.json"
unique="${prefix}.unique.csv"
duplicates="${prefix}.duplicates.csv"
balanced="${prefix}.balanced.csv"
final="${prefix}.final.csv"
analysis_txt="${prefix}.analysis.txt"
analysis_json="${prefix}.analysis.json"

printf '\n[2/6] Building raw plan\n'
perl "$SCRIPT_DIR/build_plan.pl" \
    "${source_args[@]}" \
    --output "$raw" \
    --manifest "$manifest" \
    --target-modules "$target_modules" \
    --module-limit "$module_limit" \
    --perl-versions "$perl_versions" \
    --max-deps "$max_deps" \
    --max-versions "$max_versions" \
    --max-pairs "$max_pairs" \
    --selection-mode "$selection_mode" \
    --version-sampling "$version_sampling" \
    --pair-mode "$pair_mode" \
    --seed "$seed" \
    --sleep-ms "$sleep_ms"

printf '\n[3/6] Deduplicating plan\n'
perl "$SCRIPT_DIR/plan_dedup.pl" \
    --input "$raw" \
    --output "$unique" \
    --duplicates-output "$duplicates"

printf '\n[4/6] Balancing plan\n'
perl "$SCRIPT_DIR/plan_balance.pl" \
    --input "$unique" \
    --output "$balanced" \
    --seed "$seed"

printf '\n[5/6] Shuffling balanced plan\n'
perl "$SCRIPT_DIR/plan_shuffle.pl" \
    --input "$balanced" \
    --output "$final" \
    --seed "$seed"

printf '\n[6/6] Analyzing final plan\n'
perl "$SCRIPT_DIR/plan_analyze.pl" \
    --input "$final" \
    --output "$analysis_txt" \
    --json-output "$analysis_json"

raw_rows=$(($(wc -l < "$raw") - 1))
unique_rows=$(($(wc -l < "$unique") - 1))
balanced_rows=$(($(wc -l < "$balanced") - 1))
final_rows=$(($(wc -l < "$final") - 1))
duplicate_rows=$(($(wc -l < "$duplicates") - 1))
final_unique=$(tail -n +2 "$final" | sort -u | wc -l)

planned_modules=$(perl -MJSON::PP -0777 -e '
    my $m = decode_json(<>);
    print $m->{planned_modules} // 0;
' "$manifest")

manifest_status=$(perl -MJSON::PP -0777 -e '
    my $m = decode_json(<>);
    print $m->{status} // "";
' "$manifest")

[[ $planned_modules -eq $target_modules ]] \
    || die "planned module count is $planned_modules; expected $target_modules"
[[ $manifest_status == complete ]] \
    || die "builder manifest status is '$manifest_status', expected complete"
[[ $raw_rows -gt 0 ]] \
    || die "raw plan contains no data rows"
[[ $unique_rows -eq $raw_rows ]] \
    || die "unique row count $unique_rows differs from raw count $raw_rows"
[[ $balanced_rows -eq $unique_rows ]] \
    || die "balanced row count $balanced_rows differs from unique count $unique_rows"
[[ $final_rows -eq $balanced_rows ]] \
    || die "final row count $final_rows differs from balanced count $balanced_rows"
[[ $final_unique -eq $final_rows ]] \
    || die "final plan contains duplicate rows"

printf '\nPipeline validation: PASS\n'
printf 'Planned modules:       %d\n' "$planned_modules"
printf 'Raw rows:             %d\n' "$raw_rows"
printf 'Duplicate rows:       %d\n' "$duplicate_rows"
printf 'Unique rows:          %d\n' "$unique_rows"
printf 'Balanced rows:        %d\n' "$balanced_rows"
printf 'Final rows:           %d\n' "$final_rows"
printf 'Final unique rows:    %d\n' "$final_unique"
printf 'Final plan:           %s\n' "$final"
printf 'Analysis:             %s\n' "$analysis_txt"
