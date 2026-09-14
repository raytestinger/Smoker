#!/usr/bin/env bash
set -Eeuo pipefail

# sync_smoker_trees.sh
#
# Safe Smoker synchronization:
#   1. Copy changed files from development -> repository.
#   2. Preserve repository-only files; no deletions are performed.
#   3. Rebuild distribution from repository when make_distribution.sh exists.
#
# Usage:
#   ./sync_smoker_trees.sh
#   ./sync_smoker_trees.sh --dry-run
#
# Optional environment overrides:
#   SMOKER_ROOT=~/Smoker
#   SMOKER_DEVELOPMENT=~/Smoker/development
#   SMOKER_REPOSITORY=~/Smoker/repository
#   SMOKER_DISTRIBUTION=~/Smoker/distribution

usage() {
    cat <<'EOF'
Usage: sync_smoker_trees.sh [--dry-run] [--no-distribution]

Options:
  --dry-run          Show what would change without copying anything.
  --no-distribution  Update repository only; do not rebuild distribution.
  -h, --help         Show this help.
EOF
}

DRY_RUN=0
BUILD_DISTRIBUTION=1

while (($#)); do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --no-distribution)
            BUILD_DISTRIBUTION=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

SMOKER_ROOT="${SMOKER_ROOT:-$HOME/Smoker}"
DEVELOPMENT="${SMOKER_DEVELOPMENT:-$SMOKER_ROOT/development}"
REPOSITORY="${SMOKER_REPOSITORY:-$SMOKER_ROOT/repository}"
DISTRIBUTION="${SMOKER_DISTRIBUTION:-$SMOKER_ROOT/distribution}"
export SMOKER_ROOT SMOKER_DEVELOPMENT="$DEVELOPMENT"
export SMOKER_REPOSITORY="$REPOSITORY" SMOKER_DISTRIBUTION="$DISTRIBUTION"

for dir in "$DEVELOPMENT" "$REPOSITORY"; do
    if [[ ! -d "$dir" ]]; then
        printf 'Required directory does not exist: %s\n' "$dir" >&2
        exit 1
    fi
done

if [[ ! -d "$REPOSITORY/.git" ]]; then
    printf 'Not a Git repository: %s\n' "$REPOSITORY" >&2
    exit 1
fi

printf 'Development:  %s\n' "$DEVELOPMENT"
printf 'Repository:   %s\n' "$REPOSITORY"
printf 'Distribution: %s\n\n' "$DISTRIBUTION"

# --archive preserves permissions and timestamps.
# --checksum compares file contents, so identical files are skipped even if
# timestamps differ.
# No --delete is used: repository-only files remain untouched.
RSYNC_ARGS=(
    --archive
    --checksum
    --itemize-changes
    --human-readable
    --exclude=.git/
    --exclude=test_results/
    --exclude=minicpan/
    --exclude=logs/
    --exclude=.cpanm/
    --exclude='*.tar'
    --exclude='*.tar.gz'
    --exclude='*.tgz'
)

if ((DRY_RUN)); then
    RSYNC_ARGS+=(--dry-run)
    printf '%s\n' 'Dry run: no files will be changed.'
fi

printf '%s\n' 'Synchronizing development -> repository...'
rsync "${RSYNC_ARGS[@]}" "$DEVELOPMENT/" "$REPOSITORY/"

if ((DRY_RUN)); then
    printf '\n%s\n' 'Dry run complete.'
    exit 0
fi

printf '\n%s\n' 'Repository status after synchronization:'
git -C "$REPOSITORY" status --short

if ((BUILD_DISTRIBUTION)); then
    BUILDER="$REPOSITORY/bin/make_distribution.sh"

    if [[ -n "$(git -C "$REPOSITORY" status --porcelain --untracked-files=no)" ]]; then
        printf '\nWarning: repository has uncommitted tracked changes; distribution was not rebuilt.\n' >&2
        printf '%s\n' 'Commit the repository changes, then rerun this command.' >&2
    elif [[ -x "$BUILDER" ]]; then
        printf '\n%s\n' 'Rebuilding distribution from repository...'
        (
            cd "$REPOSITORY"
            "$BUILDER"
        )
    elif [[ -f "$BUILDER" ]]; then
        printf '\n%s\n' 'Rebuilding distribution from repository...'
        (
            cd "$REPOSITORY"
            bash "$BUILDER"
        )
    else
        printf '\nWarning: %s was not found; distribution was not rebuilt.\n' \
            "$BUILDER" >&2
    fi
fi

printf '\n%s\n' 'Synchronization complete.'
printf '%s\n' 'Review the repository before committing:'
printf '  cd %q\n' "$REPOSITORY"
printf '%s\n' '  git status'
printf '%s\n' '  git diff --stat'
printf '%s\n' '  git diff'
