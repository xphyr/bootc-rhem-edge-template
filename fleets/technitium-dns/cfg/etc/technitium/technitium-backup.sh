#!/usr/bin/env bash
# Back up Technitium DNS data with restic, running restic in a container
# so nothing needs to be installed on the (read-only) host.
#
#   bash /etc/technitium-backup/technitium-backup.sh                 # run a backup (what the timer does)
#   bash /etc/technitium-backup/technitium-backup.sh restic <args>   # run any restic command, e.g.
#        ... restic snapshots
#        ... restic restore latest --tag technitium --target /restore
#            (/restore in the container is /var/tmp/technitium-restore on the host)
#
# Settings come from /etc/restic/technitium.env.

set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/restic/technitium.env}"
if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
  set -a; . "$ENV_FILE"; set +a
fi

RESTIC_IMAGE="${RESTIC_IMAGE:-docker.io/restic/restic:latest}"   # pin a version in the env file
# Host directories to back up (the container's /etc/dns and /etc/dns/ssl)
DNS_DATA_DIR="${DNS_DATA_DIR:-/etc/technitium}"
DNS_CERT_DIR="${DNS_CERT_DIR:-/var/lib/lego/technitium}"
RESTIC_CACHE_DIR_HOST="${RESTIC_CACHE_DIR_HOST:-/var/cache/restic}"
RESTORE_DIR="${RESTORE_DIR:-/var/tmp/technitium-restore}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"
TAG="technitium"
HOST_TAG="$(hostname -s)"

log() { echo "[technitium-backup] $*"; }

# restic, run as a throwaway container.
# - Data dirs are mounted read-only at their host paths, so snapshot paths match the host.
# - label=disable lets this container read volumes that carry the Technitium
#   container's private SELinux label (:Z).
restic() {
  mkdir -p "$RESTIC_CACHE_DIR_HOST" "$RESTORE_DIR"
  podman run --rm \
    --security-opt label=disable \
    --hostname "$HOST_TAG" \
    --env-file "$ENV_FILE" \
    -e RESTIC_CACHE_DIR=/cache \
    -v "$RESTIC_CACHE_DIR_HOST":/cache \
    -v "$RESTIC_PASSWORD_FILE":"$RESTIC_PASSWORD_FILE":ro \
    -v "$DNS_DATA_DIR":"$DNS_DATA_DIR":ro \
    -v "$DNS_CERT_DIR":"$DNS_CERT_DIR":ro \
    -v "$RESTORE_DIR":/restore \
    "$RESTIC_IMAGE" "$@"
}

# Pass-through mode: bash technitium-backup.sh restic <args>
if [[ "${1:-}" == "restic" ]]; then
  shift
  restic "$@"
  exit $?
fi

for d in "$DNS_DATA_DIR" "$DNS_CERT_DIR"; do
  [[ -d "$d" ]] || { log "ERROR: $d does not exist" >&2; exit 1; }
done

# --- 1. Back up -------------------------------------------------------------
# Technitium has no snapshot command; its files are small and written on change,
# so a live copy is fine. Query logs and downloaded block lists are skipped:
# logs are large and not needed to restore, block lists are re-downloaded.
podman pull -q "$RESTIC_IMAGE" >/dev/null

if ! restic cat config >/dev/null 2>&1; then
  log "Initialising restic repository $RESTIC_REPOSITORY"
  restic init
fi

log "Backing up $DNS_DATA_DIR and $DNS_CERT_DIR"
restic backup "$DNS_DATA_DIR" "$DNS_CERT_DIR" \
  --host "$HOST_TAG" \
  --tag "$TAG" \
  --exclude "$DNS_DATA_DIR/logs" \
  --exclude "$DNS_DATA_DIR/blocklists"

# --- 2. Retention ------------------------------------------------------------
log "Applying retention (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)"
restic forget --tag "$TAG" --host "$HOST_TAG" \
  --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" \
  --prune

log "Done"
