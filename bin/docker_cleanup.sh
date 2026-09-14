#!/usr/bin/env bash
set -Eeuo pipefail

echo "[cleanup] starting docker cleanup"

before=$(docker system df || true)

echo
echo "[cleanup] docker system df BEFORE"
echo "$before"

echo
echo "[cleanup] removing exited containers"
docker container prune -f || true

echo
echo "[cleanup] removing dangling images"
docker image prune -f || true

echo
echo "[cleanup] removing dangling build cache"
docker builder prune -f || true

echo
echo "[cleanup] removing dangling volumes"
docker volume prune -f || true

echo
echo "[cleanup] docker system df AFTER"
docker system df || true

echo
echo "[cleanup] done"