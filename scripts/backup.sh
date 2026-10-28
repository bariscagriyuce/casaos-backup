#!/usr/bin/env bash
# CasaOS -> Google Drive yedekleme (restic + rclone).
#   backup               tam yedekleme + saklama politikası
#   backup --check-only  sadece depo bütünlük kontrolü
set -Eeuo pipefail
[ -f /run/backup.env ] && . /run/backup.env

: "${STOP_MODE:=all}"          # all | labeled | none
: "${STOP_TIMEOUT:=60}"
: "${KEEP_DAILY:=7}"
: "${KEEP_WEEKLY:=4}"
: "${KEEP_MONTHLY:=6}"
: "${NOTIFY_ON:=failure}"      # failure | always | never
EXCLUDE_FILE=/config/excludes.txt
META_DIR=/backup-meta

log() { echo "[$(date '+%F %T')] $*"; }

notify() {
  local title=$1 msg=$2
  if [ -n "${NTFY_URL:-}" ]; then
    curl -fsS -m 15 -H "Title: $title" -d "$msg" "$NTFY_URL" >/dev/null || true
  fi
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -fsS -m 15 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode chat_id="$TELEGRAM_CHAT_ID" \
      --data-urlencode text="$title"$'\n'"$msg" >/dev/null || true
  fi
}

exec 9>/run/backup.lock
if ! flock -n 9; then
  log "Başka bir yedekleme işlemi sürüyor, atlanıyor."
  exit 0
fi

if [ "${1:-}" = "--check-only" ]; then
  log "Depo kontrolü başlıyor..."
  if restic check --read-data-subset=5%; then
    log "Depo kontrolü başarılı."
  else
    log "HATA: depo kontrolü başarısız!"
    [ "$NOTIFY_ON" != never ] && notify "CasaOS yedek: kontrol HATASI" "restic check başarısız oldu, logları inceleyin."
    exit 1
  fi
  exit 0
fi

STOPPED=()

stop_containers() {
  [ "$STOP_MODE" = none ] && return 0
  local id name stop self
  while IFS='|' read -r id name stop self; do
    [ "$self" = "true" ] && continue
    if [ "$STOP_MODE" = labeled ]; then
      [ "$stop" = "true" ] || continue
    else
      [ "$stop" = "false" ] && continue
    fi
    STOPPED+=("$id")
    log "Durdurulacak: $name"
  done < <(docker ps --format '{{.ID}}|{{.Names}}|{{.Label "casaos-backup.stop"}}|{{.Label "casaos-backup.self"}}')

  if [ "${#STOPPED[@]}" -gt 0 ]; then
    docker stop -t "$STOP_TIMEOUT" "${STOPPED[@]}" >/dev/null
  fi
}

start_containers() {
  [ "${#STOPPED[@]}" -eq 0 ] && return 0
  log "Konteynerler yeniden başlatılıyor (${#STOPPED[@]})..."
  docker start "${STOPPED[@]}" >/dev/null || log "UYARI: bazı konteynerler başlatılamadı!"
  STOPPED=()
}

on_error() {
  start_containers
  log "HATA: yedekleme başarısız (satır $1)."
  [ "$NOTIFY_ON" != never ] && notify "CasaOS yedek: HATA" "Yedekleme başarısız oldu ($(date '+%F %T')). docker logs casaos-backup ile inceleyin."
  exit 1
}
trap 'on_error $LINENO' ERR
trap start_containers EXIT

START=$(date +%s)
log "===== Yedekleme başlıyor ====="

# Geri yükleme sırasında işe yarayacak konteyner/imaj bilgilerini kaydet.
rm -rf "${META_DIR:?}"/*
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' > "$META_DIR/containers.tsv"
docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}' > "$META_DIR/images.tsv"
docker ps -aq | xargs -r docker inspect > "$META_DIR/inspect.json"
docker network ls --format '{{.Name}}\t{{.Driver}}' > "$META_DIR/networks.tsv"
docker volume ls --format '{{.Name}}' > "$META_DIR/volumes.txt"

stop_containers

# "|| rc=$?" ERR trap'ini tetiklemeden çıkış kodunu yakalar (3 = kısmi başarı).
rc=0
restic backup /source "$META_DIR" \
  --tag casaos \
  --exclude-file "$EXCLUDE_FILE" \
  --exclude-caches \
  --verbose=1 || rc=$?

start_containers

case $rc in
  0) log "Snapshot oluşturuldu." ;;
  3) log "UYARI: bazı dosyalar okunamadı ama snapshot oluşturuldu." ;;
  *) on_error "restic-backup(rc=$rc)" ;;
esac

log "Saklama politikası uygulanıyor (günlük=$KEEP_DAILY haftalık=$KEEP_WEEKLY aylık=$KEEP_MONTHLY)..."
restic forget --tag casaos --group-by host,tags \
  --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" \
  --prune

DUR=$(( $(date +%s) - START ))
SUMMARY=$(restic stats latest --mode restore-size 2>/dev/null | grep -E 'Total (File Count|Size)' | tr -s ' ' || true)
log "===== Yedekleme tamamlandı (${DUR}s) ====="
[ "$NOTIFY_ON" = always ] && notify "CasaOS yedek: başarılı" "Süre: ${DUR}s"$'\n'"$SUMMARY"
exit 0
