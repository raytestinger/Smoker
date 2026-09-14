#!/usr/bin/env bash
#
# Back up the Smoker source tree and optionally copy its local MiniCPAN
# mirror to a new timestamped directory on the snapshot drive.
#
# Source backup:
#   /QuickBackup/Smoker_YYYY-MM-DD_HHMMSS.tar.gz
#
# MiniCPAN backup:
#   /QuickBackup/minicpan_YYYY-MM-DD_HHMMSS/
#
# Existing backups are never overwritten or modified.
#

set -Eeuo pipefail

###############################################################################
# Configuration
###############################################################################

SMOKER_HOME="${SMOKER_HOME:-$HOME/Smoker}"
SMOKER_ROOT="$SMOKER_HOME"

# This is the single default backup destination for Smoker.
# Run_Smoker.pl does not duplicate this default; it only passes through
# SMOKER_SNAPSHOT_ROOT when the user explicitly exports an override.
DEFAULT_SNAPSHOT_ROOT="/QuickBackup"
SNAPROOT="${SMOKER_SNAPSHOT_ROOT:-$DEFAULT_SNAPSHOT_ROOT}"
MINICPAN_DIR="${SMOKER_MINICPAN_DIR:-$SMOKER_HOME/minicpan}"

export SMOKER_HOME SMOKER_ROOT

###############################################################################
# Functions
###############################################################################

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup_partial_files() {
    if [[ -n "${SMOKER_DEST_TMP:-}" &&
          -f "${SMOKER_DEST_TMP:-}" ]]; then
        rm -f -- "$SMOKER_DEST_TMP"
    fi

    if [[ -n "${MINICPAN_BACKUP_TMP:-}" &&
          -d "${MINICPAN_BACKUP_TMP:-}" ]]; then
        rm -rf -- "$MINICPAN_BACKUP_TMP"
    fi
}

resolve_dir() {
    local path="$1"
    [[ -d "$path" ]] || return 1
    (cd "$path" && pwd -P)
}

validate_safe_dir() {
    local label="$1"
    local path="$2"
    [[ -n "$path" ]] || die "$label path is empty"
    [[ "$path" != "/" ]] || die "$label path must not be /"
    [[ "$path" != "$HOME" ]] || die "$label path must not be the home directory"
}

trap cleanup_partial_files EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

###############################################################################
# Prerequisite checks
###############################################################################

command -v tar >/dev/null 2>&1 ||
    die "tar is not installed or is not in PATH"

command -v mountpoint >/dev/null 2>&1 ||
    die "mountpoint is not installed or is not in PATH"

validate_safe_dir "Smoker source" "$SMOKER_HOME"
validate_safe_dir "snapshot destination" "$SNAPROOT"

SMOKER_HOME_RESOLVED="$(resolve_dir "$SMOKER_HOME")" ||
    die "Smoker source directory does not exist: $SMOKER_HOME"
SNAPROOT_RESOLVED="$(resolve_dir "$SNAPROOT")" ||
    die "snapshot destination directory does not exist: $SNAPROOT"

validate_safe_dir "Smoker source" "$SMOKER_HOME_RESOLVED"
validate_safe_dir "snapshot destination" "$SNAPROOT_RESOLVED"

[[ -w "$SNAPROOT_RESOLVED" ]] ||
    die "snapshot destination is not writable: $SNAPROOT_RESOLVED"

if ! mountpoint -q "$SNAPROOT_RESOLVED"; then
    die "$SNAPROOT_RESOLVED is not a mounted filesystem"
fi

###############################################################################
# Destination names
###############################################################################

TS="${SMOKER_BACKUP_TIMESTAMP:-$(date +%Y-%m-%d_%H%M%S)}"

SMOKER_DEST="$SNAPROOT_RESOLVED/Smoker_${TS}.tar.gz"
SMOKER_DEST_TMP="${SMOKER_DEST}.partial"

MINICPAN_BACKUP_DIR="$SNAPROOT_RESOLVED/minicpan_${TS}"
MINICPAN_BACKUP_TMP="${MINICPAN_BACKUP_DIR}.partial"

[[ ! -e "$SMOKER_DEST" ]] ||
    die "backup archive already exists: $SMOKER_DEST"
[[ ! -e "$SMOKER_DEST_TMP" ]] ||
    die "partial backup archive already exists: $SMOKER_DEST_TMP"

###############################################################################
# Back up the Smoker source tree
###############################################################################

echo
echo "Backing up Smoker source tree..."
echo "Source: $SMOKER_HOME_RESOLVED"
echo "Destination: $SNAPROOT_RESOLVED"
echo

tar \
    --exclude='./test_results' \
    --exclude='./minicpan' \
    --exclude='./minicpan.incomplete' \
    --exclude='./.cpanm' \
    --exclude='./archive' \
    --exclude='./state' \
    --exclude='./tmp' \
    --exclude='./logs' \
    --exclude='./llm' \
    --exclude='./LLM' \
    --exclude='./bkSmoker' \
    --exclude='./QuickBackup' \
    --exclude='./distribution' \
    --exclude='*.tar' \
    --exclude='*.tar.gz' \
    --exclude='*.tgz' \
    -C "$SMOKER_HOME_RESOLVED" \
    -czf "$SMOKER_DEST_TMP" \
    . ||
    die "tar archive command failed"

[[ -s "$SMOKER_DEST_TMP" ]] ||
    die "tar archive command did not create a nonempty archive: $SMOKER_DEST_TMP"

mv -- "$SMOKER_DEST_TMP" "$SMOKER_DEST" ||
    die "cannot promote backup archive into place: $SMOKER_DEST"

[[ -s "$SMOKER_DEST" ]] ||
    die "backup archive is missing after promotion: $SMOKER_DEST"

###############################################################################
# Decide whether MiniCPAN should be backed up
###############################################################################

case "${SMOKER_BACKUP_MINICPAN:-0}" in
    1|[Yy]|[Yy][Ee][Ss])
        BACKUP_MINICPAN=1
        ;;
    0|[Nn]|[Nn][Oo])
        BACKUP_MINICPAN=0
        echo
        echo "MiniCPAN backup disabled by SMOKER_BACKUP_MINICPAN."
        ;;
    *)
        die "invalid SMOKER_BACKUP_MINICPAN value: ${SMOKER_BACKUP_MINICPAN}"
        ;;
esac

###############################################################################
# Back up MiniCPAN
###############################################################################

if ((BACKUP_MINICPAN)); then
    if [[ ! -d "$MINICPAN_DIR" ]]; then
        echo
        echo "WARNING: minicpan directory not found; skipping."
    else
        command -v rsync >/dev/null 2>&1 ||
            die "rsync is not installed or is not in PATH; required only for SMOKER_BACKUP_MINICPAN"

        MINICPAN_DIR_RESOLVED="$(resolve_dir "$MINICPAN_DIR")" ||
            die "cannot resolve MiniCPAN directory: $MINICPAN_DIR"

        if [[ -e "$MINICPAN_BACKUP_DIR" ||
              -e "$MINICPAN_BACKUP_TMP" ]]; then
            die "MiniCPAN backup destination already exists"
        fi

        echo
        echo "Backing up minicpan mirror..."
        echo

        mkdir -p -- "$MINICPAN_BACKUP_TMP" ||
            die "cannot create MiniCPAN backup staging directory"

        rsync \
            --archive \
            "$MINICPAN_DIR_RESOLVED/" \
            "$MINICPAN_BACKUP_TMP/" ||
            die "rsync MiniCPAN backup command failed"

        mv -- "$MINICPAN_BACKUP_TMP" "$MINICPAN_BACKUP_DIR" ||
            die "cannot promote MiniCPAN backup into place"
    fi
else
    echo
    echo "Skipping minicpan backup."
fi

###############################################################################
# Completion
###############################################################################

echo
echo "Backup complete: $SMOKER_DEST"
echo

SMOKER_DEST_TMP=""
MINICPAN_BACKUP_TMP=""

exit 0
