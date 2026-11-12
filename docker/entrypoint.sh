#!/usr/bin/env bash
# Старт DayZ-сервера: конфиги из git, файлы игры — из артефакта (URL) или через steamcmd в рантайме.
set -euo pipefail

DATA=${DATA:-/data}
SERVERDIR=$DATA/serverfiles
MODSDIR=$DATA/mods
PROFILES=$DATA/profiles
CFGDIR=$DATA/config
RAW=${CFG_RAW_BASE:-https://git.sts.co.ua/sts/dayz_serv/raw/branch/dev}

log() { printf '[entrypoint] %s\n' "$*"; }

: "${SERVER_NAME:=STS Namalsk}"
: "${MAX_PLAYERS:=60}"
: "${GAME_PORT:=2302}"
: "${QUERY_PORT:=2305}"
: "${RCON_PORT:=2306}"
: "${MISSION:=regular.namalsk}"
: "${SERVER_PASSWORD:=}"
: "${ADMIN_PASSWORD:=changeme}"
: "${RCON_PASSWORD:=changeme}"

# envsubst читает ОКРУЖЕНИЕ, а не шилл-переменные: без export подстановка даёт пустые строки
export SERVER_NAME SERVER_PASSWORD ADMIN_PASSWORD MAX_PLAYERS GAME_PORT QUERY_PORT RCON_PORT MISSION RCON_PASSWORD

mkdir -p "$DATA" "$CFGDIR" "$PROFILES"

# --- 1. конфиги из git (fallback — то, что запечено в образ) ---
fetch_cfg() {
  local name=$1 url="$RAW/config/$1" tmp="$CFGDIR/.$1.new"
  if curl -fsSL --max-time 20 "$url" -o "$tmp" 2>/dev/null; then
    mv "$tmp" "$CFGDIR/$1"; log "config $name <- git"
  else
    rm -f "$tmp"
    [ -f "$CFGDIR/$name" ] || cp "/opt/dayz-defaults/config/$name" "$CFGDIR/$name" 2>/dev/null || true
    log "config $name <- образ (git недоступен)"
  fi
}
fetch_cfg serverDZ.cfg
fetch_cfg mods.txt
[ -f "$CFGDIR/BEServer_x64.cfg.tpl" ] || cp /opt/dayz-defaults/config/BEServer_x64.cfg.tpl "$CFGDIR/" 2>/dev/null || true

# --- 2. список модов (id;папка;название) ---
MODS=()
if [ -f "$CFGDIR/mods.txt" ]; then
  while IFS=';' read -r id folder _name; do
    case "${id:-}" in ''|\#*) continue;; esac
    MODS+=("$id|$folder")
  done < "$CFGDIR/mods.txt"
fi

steam_dl() {
  if [ -n "${STEAM_GUARD_CODE:-}" ]; then
    /opt/steam/steamcmd.sh +@sSteamCmdForcePlatformType linux \
      +login "${STEAM_USER:?нужен STEAM_USER}" "${STEAM_PASS:?нужен STEAM_PASS}" "${STEAM_GUARD_CODE}" "$@" +quit
  else
    /opt/steam/steamcmd.sh +@sSteamCmdForcePlatformType linux \
      +login "${STEAM_USER:?нужен STEAM_USER}" "${STEAM_PASS:?нужен STEAM_PASS}" "$@" +quit
  fi
}

# --- 3. файлы игры ---
if [ ! -x "$SERVERDIR/DayZServer" ]; then
  mkdir -p "$SERVERDIR"
  if [ -n "${SERVERFILES_URL:-}" ]; then
    log "качаю серверные файлы: $SERVERFILES_URL"
    curl -fL --retry 3 --max-time 3600 "$SERVERFILES_URL" | tar -I zstd -xf - -C "$DATA"
  elif [ -n "${STEAM_USER:-}" ]; then
    log "качаю DayZ (223350) через steamcmd"
    steam_dl +force_install_dir "$SERVERDIR" +app_update 223350 validate
  else
    log "ОШИБКА: нет файлов игры, не задан ни SERVERFILES_URL, ни STEAM_USER"; exit 1
  fi
fi

# --- 4. моды ---
mkdir -p "$MODSDIR"
for item in "${MODS[@]:-}"; do
  [ -n "$item" ] || continue
  id=${item%%|*}; folder=${item##*|}
  [ -d "$MODSDIR/$folder" ] && continue
  if [ -n "${MODS_URL:-}" ]; then
    log "качаю архив модов: $MODS_URL"
    curl -fL --retry 3 --max-time 3600 "$MODS_URL" | tar -I zstd -xf - -C "$DATA"
    break
  elif [ -n "${STEAM_USER:-}" ]; then
    log "качаю мод $id -> $folder"
    steam_dl +workshop_download_item 221100 "$id"
    cp -a "$HOME/Steam/steamapps/workshop/content/221100/$id" "$MODSDIR/$folder"
  else
    log "ОШИБКА: нет модов и нечем качать"; exit 1
  fi
done

# --- 5. линковка модов, ключи, миссия ---
MODARGS=(); mkdir -p "$SERVERDIR/keys"
for item in "${MODS[@]:-}"; do
  [ -n "$item" ] || continue
  folder=${item##*|}
  [ -d "$MODSDIR/$folder" ] || { log "нет папки мода $MODSDIR/$folder"; exit 1; }
  [ -e "$MODSDIR/$folder/addons" ] || ln -s "$MODSDIR/$folder/Addons" "$MODSDIR/$folder/addons" 2>/dev/null || true
  ln -sfn "$MODSDIR/$folder" "$SERVERDIR/@$folder"
  if [ -d "$MODSDIR/$folder/Keys" ]; then
    cp -f "$MODSDIR/$folder"/Keys/*.bikey "$SERVERDIR/keys/" 2>/dev/null || true
  fi
  MODARGS+=("@$folder")
done

MPDIR="$SERVERDIR/mpmissions"
if [ ! -f "$MPDIR/$MISSION/init.c" ]; then
  # глубина важна: миссия лежит в <mod>/Extras/Regular/<mission> — это 4 уровня от $MODSDIR
  src=$(find "$MODSDIR" -maxdepth 6 -type d -name "$MISSION" 2>/dev/null | head -1 || true)
  if [ -n "$src" ]; then
    mkdir -p "$MPDIR"
    rm -rf "$MPDIR/$MISSION"
    cp -a "$src" "$MPDIR/" && log "миссия $MISSION скопирована: $src"
  fi
fi
if [ ! -f "$MPDIR/$MISSION/init.c" ]; then
  log "ОШИБКА: в миссии $MPDIR/$MISSION нет init.c — сервер поднимется без игрового мира (player connect disabled)"
else
  log "миссия ok: init.c на месте ($(ls "$MPDIR/$MISSION" | wc -l) файлов)"
fi

MODSTR=$(IFS=';'; echo "${MODARGS[*]:-}")
log "моды: ${MODSTR:-нет}"

# --- 6. конфиги и запуск ---
envsubst '$SERVER_NAME $SERVER_PASSWORD $ADMIN_PASSWORD $MAX_PLAYERS $QUERY_PORT $MISSION' \
  < "$CFGDIR/serverDZ.cfg" > "$CFGDIR/serverDZ.rendered.cfg"
mkdir -p "$SERVERDIR/battleye"
log "rendered: $(grep -E 'steamQueryPort|hostname' "$CFGDIR/serverDZ.rendered.cfg" | tr '\n' ' ')"
envsubst '$RCON_PASSWORD $RCON_PORT' \
  < "$CFGDIR/BEServer_x64.cfg.tpl" > "$SERVERDIR/battleye/BEServer_x64.cfg" 2>/dev/null || true

cd "$SERVERDIR"
exec ./DayZServer \
  -config="$CFGDIR/serverDZ.rendered.cfg" \
  -port="$GAME_PORT" \
  -profiles="$PROFILES" \
  -bepath=battleye \
  -dologs -adminlog -netlog -freezecheck \
  ${MODSTR:+-mod="$MODSTR"}
