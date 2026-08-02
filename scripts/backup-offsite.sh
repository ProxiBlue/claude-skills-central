#!/bin/bash
# Off-site backup — encrypt the latest Graphiti dump locally, then push the
# ciphertext to a remote (Icedrive over WebDAV via rclone). Closes the real
# disaster hole: the nightly dumps live on the SAME disk as the data, so an
# HD crash loses both. This copies an encrypted copy off the machine.
#
# WHY ENCRYPT LOCALLY: Icedrive's WebDAV cannot reach its client-side-encrypted
# vault — WebDAV only sees non-encrypted storage. The dump is client domain
# data, so it is encrypted here (openssl AES-256, verified round-trip) before
# it ever leaves the machine. What lands on Icedrive is opaque.
#
# DORMANT until configured. Needs ~/.config/graphiti-offsite.env:
#   RCLONE_REMOTE="icedrive:proxiblue-backups/graphiti"   # rclone remote:path
#   OFFSITE_RETENTION=14                                   # keep N newest remote
# and an rclone remote named per RCLONE_REMOTE (see RECOVERY.md for the
# `rclone config` WebDAV steps).
#
# CRITICAL for restore: the passphrase at ~/.config/graphiti-offsite-passphrase
# MUST also be stored in the password manager. If the only copy is on the disk
# that crashes, the off-site backups are permanently unrecoverable.
#
# Exit non-zero on real failure so the monitor dispatcher alerts.

set -u
CFG="$HOME/.config/graphiti-offsite.env"
PF="$HOME/.config/graphiti-offsite-passphrase"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/graphiti}"
RCLONE="${RCLONE:-$HOME/.local/bin/rclone}"
command -v "$RCLONE" >/dev/null 2>&1 || RCLONE=rclone

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

[ -f "$CFG" ] || { log "offsite dormant: no $CFG (see RECOVERY.md to enable)"; exit 0; }
# shellcheck disable=SC1090
. "$CFG"
[ -n "${RCLONE_REMOTE:-}" ] || { log "offsite dormant: RCLONE_REMOTE unset"; exit 0; }
[ -f "$PF" ] || { log "ERROR: passphrase $PF missing — cannot encrypt"; exit 2; }
RETENTION="${OFFSITE_RETENTION:-14}"

DUMP=$(ls -t "$BACKUP_DIR"/graphiti-*.dump 2>/dev/null | head -1)
[ -n "$DUMP" ] || { log "ERROR: no dump to push in $BACKUP_DIR"; exit 2; }

ENC="$DUMP.enc"
log "encrypting $(basename "$DUMP") ($(du -h "$DUMP"|cut -f1)) ..."
if ! openssl enc -aes-256-cbc -pbkdf2 -salt -in "$DUMP" -out "$ENC" -pass file:"$PF"; then
  log "ERROR: encryption failed"; rm -f "$ENC"; exit 2
fi

log "pushing to $RCLONE_REMOTE ..."
if ! "$RCLONE" copy "$ENC" "$RCLONE_REMOTE/" --no-traverse 2>&1 | sed 's/^/  /'; then
  log "ERROR: rclone push failed"; exit 3
fi
log "pushed $(basename "$ENC")"

# prune remote: keep newest N .enc
REMOTE_OLD=$("$RCLONE" lsf "$RCLONE_REMOTE/" --include '*.dump.enc' 2>/dev/null | sort | head -n -"$RETENTION")
for f in $REMOTE_OLD; do "$RCLONE" deletefile "$RCLONE_REMOTE/$f" 2>/dev/null && log "pruned remote $f"; done
# prune local .enc (the plaintext .dump keep policy is the dump script's job)
find "$BACKUP_DIR" -name 'graphiti-*.dump.enc' -mtime +2 -delete 2>/dev/null

# verify the pushed file is actually there and non-zero
SZ=$("$RCLONE" size "$RCLONE_REMOTE/" --json 2>/dev/null | grep -oE '"bytes":[0-9]+' | head -1 | cut -d: -f2)
log "offsite OK — remote holds $("$RCLONE" lsf "$RCLONE_REMOTE/" --include '*.dump.enc' 2>/dev/null | wc -l) encrypted dump(s), ${SZ:-?} bytes total"
