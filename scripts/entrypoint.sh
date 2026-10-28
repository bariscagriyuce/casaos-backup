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

# Önceki yedek konteynerleri durdurduktan sonra yarıda kesildiyse (sunucu yeniden başladı,
# konteyner yeniden oluşturuldu...) onları tekrar başlat.
STATE_FILE=/config/.stopped-containers
if [ -s "$STATE_FILE" ]; then
  log "Yarıda kalan yedekten kalan durdurulmuş konteynerler başlatılıyor: $(tr '\n' ' ' < "$STATE_FILE")"
  xargs -r docker start < "$STATE_FILE" >/dev/null || log "UYARI: bazı konteynerler başlatılamadı!"
  rm -f "$STATE_FILE"
fi

# rclone yapılandırılana kadar bekle (crash-loop yerine). Kurulum:
#   docker compose exec casaos-backup rclone config
until [ -s "$RCLONE_CONFIG" ]; do
  log "rclone yapılandırması yok ($RCLONE_CONFIG). Şunu çalıştırın: docker compose exec casaos-backup rclone config"
  sleep 60
done

# Depoya ulaşılamazsa (ör. eksik/süresi dolmuş token) çıkıp crash-loop'a girmek yerine bekleyip tekrar dene;
# böylece konteyner ayakta kalır ve rclone ayarı düzeltilebilir.
until restic cat config >/dev/null 2>&1; do
  log "Restic deposu bulunamadı, oluşturuluyor: $RESTIC_REPOSITORY"
  if restic init; then
    break
  fi
  log "HATA: depoya ulaşılamadı. rclone ayarını kontrol edin: docker exec casaos-backup rclone lsd gdrive:  (5 dk sonra tekrar denenecek)"
  sleep 300
done

cat > /etc/crontabs/root <<EOF
$BACKUP_CRON /usr/local/bin/backup > /proc/1/fd/1 2>&1
$CHECK_CRON /usr/local/bin/backup --check-only > /proc/1/fd/1 2>&1
EOF

log "Zamanlama: yedek='$BACKUP_CRON' kontrol='$CHECK_CRON' (TZ=${TZ:-UTC})"

if [ "${RUN_ON_START:-false}" = "true" ]; then
  /usr/local/bin/backup || true
fi

exec crond -f -l 8
