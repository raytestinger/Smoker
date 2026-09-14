#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: bin/make_distribution.sh [--dry-run] [--output DIR]

Build an atomic Smoker distribution tree from committed Git content.

Options:
  --dry-run      Validate and show the source, destination, and commit only.
  --output DIR   Override SMOKER_DISTRIBUTION or the default sibling tree.
  -h, --help     Show this help.
EOF
}

DRY_RUN=0
OUTPUT="${SMOKER_DISTRIBUTION:-}"
while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --output)
            (($# >= 2)) || { printf '%s\n' 'ERROR: --output requires a directory' >&2; exit 2; }
            OUTPUT=$2
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'ERROR: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="${SMOKER_REPOSITORY:-$(cd "$SCRIPT_DIR/.." && pwd)}"
[[ -d "$REPOSITORY/.git" ]] || {
    printf 'ERROR: not a Git repository: %s\n' "$REPOSITORY" >&2
    exit 1
}
REPOSITORY="$(cd "$REPOSITORY" && pwd)"

if [[ -z "$OUTPUT" ]]; then
    OUTPUT="$(cd "$REPOSITORY/.." && pwd)/distribution"
fi
OUTPUT_PARENT="$(dirname "$OUTPUT")"
OUTPUT_NAME="$(basename "$OUTPUT")"
mkdir -p "$OUTPUT_PARENT"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd)"
OUTPUT="$OUTPUT_PARENT/$OUTPUT_NAME"

case "$OUTPUT/" in
    "$REPOSITORY/"|"$REPOSITORY/"*)
        printf 'ERROR: distribution must be outside the repository: %s\n' "$OUTPUT" >&2
        exit 1
        ;;
esac
[[ "$OUTPUT" != "/" ]] || { printf '%s\n' 'ERROR: refusing distribution path /' >&2; exit 1; }

COMMIT="$(git -C "$REPOSITORY" rev-parse --verify HEAD)"
if [[ -n "$(git -C "$REPOSITORY" status --porcelain --untracked-files=no)" ]]; then
    printf '%s\n' 'ERROR: repository has uncommitted tracked changes' >&2
    exit 1
fi

printf 'Repository:   %s\n' "$REPOSITORY"
printf 'Distribution: %s\n' "$OUTPUT"
printf 'Commit:       %s\n' "$COMMIT"
if ((DRY_RUN)); then
    printf '%s\n' 'Dry run complete; no files changed.'
    exit 0
fi

STAGING="$(mktemp -d "$OUTPUT_PARENT/.${OUTPUT_NAME}.staging.XXXXXX")"
OLD=""
cleanup() {
    if [[ -n "$OLD" && -d "$OLD" && ! -e "$OUTPUT" ]]; then
        mv -- "$OLD" "$OUTPUT"
    fi
    [[ ! -d "$STAGING" ]] || rm -rf -- "$STAGING"
}
trap cleanup EXIT

git -C "$REPOSITORY" archive --format=tar "$COMMIT" | tar -xf - -C "$STAGING"
cat > "$STAGING/RELEASE_SOURCE.txt" <<EOF
Smoker distribution source
Commit: $COMMIT
EOF

if [[ -e "$OUTPUT" ]]; then
    [[ -d "$OUTPUT" && ! -L "$OUTPUT" ]] || {
        printf 'ERROR: existing distribution is not a directory: %s\n' "$OUTPUT" >&2
        exit 1
    }
    OLD="$(mktemp -d "$OUTPUT_PARENT/.${OUTPUT_NAME}.previous.XXXXXX")"
    rmdir "$OLD"
    mv -- "$OUTPUT" "$OLD"
fi
mv -- "$STAGING" "$OUTPUT"
STAGING=""
if [[ -n "$OLD" ]]; then
    rm -rf -- "$OLD"
    OLD=""
fi
trap - EXIT

printf 'Distribution built successfully: %s\n' "$OUTPUT"
