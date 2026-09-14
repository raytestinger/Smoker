#!/usr/bin/env bash
set -Eeuo pipefail

# Explicitly create or update the local MiniCPAN mirror used by Smoker.
#
# Smoker does not create this mirror automatically. Run this helper manually
# when a local CPAN mirror is wanted.
#
# Active mirror:
#   $HOME/Smoker/minicpan
#
# Staging directory:
#   $HOME/Smoker/minicpan.incomplete
#
# The staging directory is promoted to the active mirror only after the
# required package index exists.
#
# Usage:
#   minicpan_ready.sh
#   minicpan_ready.sh --snapshot
#
# By default no snapshot copy is made.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKER_HOME="${SMOKER_HOME:-${SMOKER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
SMOKER_ROOT="$SMOKER_HOME"

export SMOKER_HOME SMOKER_ROOT

MIRROR="${SMOKER_MINICPAN_DIR:-$HOME/Smoker/minicpan}"
STAGING="${MIRROR}.incomplete"
SAVE="${SMOKER_SAVE_MINICPAN:-/Backup/minicpan}"
LOGDIR="${SMOKER_LOG_DIR:-$SMOKER_HOME/logs}"

SNAPSHOT=0

usage() {
    cat <<'EOF'
Usage: minicpan_ready.sh [--snapshot]

Create or update the explicit local MiniCPAN mirror.

  --snapshot   After a successful update, copy the completed mirror to
               /Backup/minicpan, or to SMOKER_SAVE_MINICPAN when set.

The mirror is first built in minicpan.incomplete and is promoted only after
modules/02packages.details.txt.gz has been created.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        --snapshot)
            SNAPSHOT=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
    shift
done

command -v minicpan >/dev/null 2>&1 ||
    die "minicpan command not found; install CPAN::Mini first"

command -v tee >/dev/null 2>&1 ||
    die "tee command not found"

mkdir -p "$HOME/Smoker" "$LOGDIR"

STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="$LOGDIR/minicpan_ready_${STAMP}.log"

ACTIVE_INDEX="$MIRROR/modules/02packages.details.txt.gz"
STAGING_INDEX="$STAGING/modules/02packages.details.txt.gz"

log() {
    printf '%s\n' "$*" | tee -a "$LOG"
}

if [[ -e "$STAGING" ]]; then
    die "staging directory already exists: $STAGING
Inspect, rename, or remove it before retrying."
fi

if [[ -d "$MIRROR" ]]; then
    log "[minicpan] Copying active mirror into staging directory..."
    mkdir -p "$STAGING"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a "$MIRROR/" "$STAGING/" |
            tee -a "$LOG"
    else
        cp -a "$MIRROR/." "$STAGING/"
    fi
else
    log "[minicpan] No active mirror found; creating a new staged mirror."
    mkdir -p "$STAGING"
fi

log "[minicpan] Active mirror:  $MIRROR"
log "[minicpan] Staging mirror: $STAGING"
log "[minicpan] Updating from CPAN..."

set +e
minicpan \
    -l "$STAGING" \
    -r https://www.cpan.org \
    2>&1 | tee -a "$LOG"
MINICPAN_STATUS=${PIPESTATUS[0]}
set -e

if ((MINICPAN_STATUS != 0)); then
    log "ERROR: minicpan exited with status $MINICPAN_STATUS"
    log "[minicpan] Incomplete data retained at: $STAGING"
    exit "$MINICPAN_STATUS"
fi

if [[ ! -s "$STAGING_INDEX" ]]; then
    log "ERROR: update completed without a usable package index:"
    log "       $STAGING_INDEX"
    log "[minicpan] Incomplete data retained at: $STAGING"
    exit 1
fi

log "[minicpan] Required package index verified."

OLD_MIRROR=""

if [[ -e "$MIRROR" ]]; then
    OLD_MIRROR="${MIRROR}.previous.${STAMP}"
    log "[minicpan] Preserving previous mirror as: $OLD_MIRROR"
    mv -- "$MIRROR" "$OLD_MIRROR"
fi

if ! mv -- "$STAGING" "$MIRROR"; then
    if [[ -n "$OLD_MIRROR" && ! -e "$MIRROR" ]]; then
        mv -- "$OLD_MIRROR" "$MIRROR" || true
    fi
    die "could not promote staged mirror"
fi

log "[minicpan] Staged mirror promoted successfully."

if ((SNAPSHOT)); then
    if ! mountpoint -q /Backup; then
        log "WARNING: /Backup is not mounted; snapshot skipped."
    elif ! command -v rsync >/dev/null 2>&1; then
        log "WARNING: rsync is unavailable; snapshot skipped."
    else
        mkdir -p "$SAVE"
        log "[minicpan] Copying completed mirror to: $SAVE"
        rsync -a --delete "$MIRROR/" "$SAVE/" |
            tee -a "$LOG"
    fi
else
    log "[minicpan] Snapshot not requested."
fi

log "[minicpan] Mirror ready."
du -sh "$MIRROR" 2>/dev/null | tee -a "$LOG"

if [[ -n "$OLD_MIRROR" ]]; then
    log "[minicpan] Previous mirror retained at: $OLD_MIRROR"
fi

exit 0
