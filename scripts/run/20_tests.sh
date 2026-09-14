#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKER_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"

export SMOKER_HOME
export SMOKER_ROOT="$SMOKER_HOME"

export SMOKER_TARBALL_CACHE="${SMOKER_TARBALL_CACHE:-$HOME/.cpanm/dists}"

cd "$SMOKER_HOME"

perl "$SMOKER_HOME/Run_Smoker.pl" \
    config/plans/20_tests.csv \
    --jobs "${SMOKER_JOBS:-6}"
