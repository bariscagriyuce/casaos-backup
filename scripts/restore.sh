#!/usr/bin/env bash
# Kullanım:
#   restore                          -> snapshot listesini gösterir
#   restore latest                   -> son snapshot'ı /restore altına açar
#   restore <id> [restic seçenekleri] örn: restore latest --include /source/DATA/AppData/jellyfin
set -euo pipefail

if [ $# -eq 0 ]; then
  restic snapshots --tag casaos
  echo
  echo "Geri yüklemek için: restore latest   (veya restore <snapshot-id>)"
  exit 0
fi

snap=$1; shift
restic restore "$snap" --target /restore "$@"
echo "Dosyalar konteyner içinde /restore altına (hostta ./restore klasörüne) açıldı."
