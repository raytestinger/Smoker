#!/usr/bin/env bash
set -Eeuo pipefail

echo "[docker-full-prune] WARNING: this removes Docker leftovers aggressively."
echo "[docker-full-prune] It removes stopped containers, unused networks,"
echo "[docker-full-prune] dangling/unused images, build cache, and unused volumes."
echo

docker ps

echo
read -r -p "Type PRUNE to continue: " answer

if [[ "$answer" != "PRUNE" ]]; then
    echo "[docker-full-prune] cancelled"
    exit 0
fi

echo
echo "[docker-full-prune] BEFORE:"
docker system df || true

echo
echo "[docker-full-prune] stopping running containers, if any"
running="$(docker ps -q || true)"
if [[ -n "$running" ]]; then
    docker stop $running
fi

echo
echo "[docker-full-prune] removing all stopped containers"
docker container prune -f || true

echo
echo "[docker-full-prune] removing unused networks"
docker network prune -f || true

echo
echo "[docker-full-prune] removing unused images"
docker image prune -a -f || true

echo
echo "[docker-full-prune] removing build cache"
docker builder prune -a -f || true

echo
echo "[docker-full-prune] removing unused volumes"
docker volume prune -a -f || docker volume prune -f || true

echo
echo "[docker-full-prune] AFTER:"
docker system df || true

echo
echo "[docker-full-prune] done"