#!/usr/bin/env bash
# Бутстрап для стокового образа (debian:bookworm-slim): ставит зависимости и steamcmd,
# забирает entrypoint и конфиги из git, дальше передаёт управление entrypoint.sh.
# Нужен потому, что Forgejo-реестр не отдаёт образы анонимно, а Flux не умеет pull с авторизацией
# без Enterprise. Итог: в образе живёт только debian, весь код — в git.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture i386
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl tar zstd gettext-base tini procps iproute2 \
  lib32gcc-s1 libstdc++6 libc6 zlib1g

mkdir -p /opt/steam
curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar xz -C /opt/steam
/opt/steam/steamcmd.sh +quit >/dev/null 2>&1 || true

RAW=${CFG_RAW_BASE:-https://git.sts.co.ua/sts/dayz_serv/raw/branch}/${BRANCH:-dev}
mkdir -p /opt/dayz-defaults/config
for f in serverDZ.cfg mods.txt BEServer_x64.cfg.tpl; do
  curl -fsSL "$RAW/config/$f" -o "/opt/dayz-defaults/config/$f" || echo "warn: $f не скачался"
done
curl -fsSL "$RAW/docker/entrypoint.sh" -o /tmp/entrypoint.sh
chmod +x /tmp/entrypoint.sh
exec bash /tmp/entrypoint.sh
