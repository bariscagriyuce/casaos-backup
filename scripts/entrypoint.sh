#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%F %T')] $*"; }

: "${BACKUP_CRON:=0 3 * * *}"
: "${CHECK_CRON:=0 5 * * 0}"
: "${RCLONE_CONFIG:=/config/rclone/rclone.conf}"

# busybox crond, container ortam değişkenlerini işlere aktarmaz; dosyaya yazıp backup.sh içinde yüklüyoruz.
export -p > /run/backup.env
chmod 600 /run/backup.env

if [ -z "${RESTIC_PASSWORD:-}" ] || [ -z "${RESTIC_REPOSITORY:-}" ]; then
  log "HATA: .env içinde RESTIC_PASSWORD ve RESTIC_REPOSITORY tanımlı olmalı."
  exit 1
fi

# rclone yapılandırılana kadar bekle (crash-loop yerine). Kurulum:
#   docker compose exec casaos-backup rclone config
until [ -s "$RCLONE_CONFIG" ]; do
  log "rclone yapılandırması yok ($RCLONE_CONFIG). Şunu çalıştırın: docker compose exec casaos-backup rclone config"
  sleep 60
done

if ! restic cat config >/dev/null 2>&1; then
  log "Restic deposu bulunamadı, oluşturuluyor: $RESTIC_REPOSITORY"
  restic init
fi

cat > /etc/crontabs/root <<EOF
$BACKUP_CRON /usr/local/bin/backup > /proc/1/fd/1 2>&1
$CHECK_CRON /usr/local/bin/backup --check-only > /proc/1/fd/1 2>&1
EOF

log "Zamanlama: yedek='$BACKUP_CRON' kontrol='$CHECK_CRON' (TZ=${TZ:-UTC})"

if [ "${RUN_ON_START:-false}" = "true" ]; then
  /usr/local/bin/backup || true
fi

exec crond -f -l 8
