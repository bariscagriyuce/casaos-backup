FROM alpine:3.21

RUN apk add --no-cache bash restic rclone docker-cli curl tzdata ca-certificates util-linux

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint
COPY scripts/backup.sh     /usr/local/bin/backup
COPY scripts/restore.sh    /usr/local/bin/restore
RUN chmod +x /usr/local/bin/entrypoint /usr/local/bin/backup /usr/local/bin/restore \
 && mkdir -p /source /restore /cache /backup-meta

ENTRYPOINT ["/usr/local/bin/entrypoint"]
