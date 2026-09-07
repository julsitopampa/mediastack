#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "${SCRIPT_DIR}/../../" && pwd)"
LOG_FILE="${SCRIPT_DIR}/backup.log"
REPO="/data/backup/mediastack"
EXCLUDES_FILE="${SCRIPT_DIR}/restic-excludes.txt"
PASS_FILE="/home/julsito/.config/restic/password"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

# --- Pre-flight Checks ---

if ! grep -qs '/data ' /proc/mounts; then
    echo "ERROR: Backup destination '/data' is not mounted." >&2
    exit 1
fi

if [[ ! -f "$PASS_FILE" ]]; then
    echo "ERROR: Password file missing at $PASS_FILE" >&2
    exit 1
fi

if ! restic snapshots -r "$REPO" --password-file "$PASS_FILE" >/dev/null 2>&1; then
    echo "ERROR: Restic repository at $REPO is not initialized or unreachable." >&2
    echo "Initialize it once with: restic init -r $REPO --password-file $PASS_FILE" >&2
    exit 1
fi

# --- Core Functions ---

dump_postgresql() {
    local target_dump_file="$1"

    log "Dumping PostgreSQL databases..."
    if sudo /usr/local/bin/mediastack-pg-dump > "$target_dump_file" 2>&1 | tee -a "$LOG_FILE"; then
        chmod 600 "$target_dump_file"
    else
        log "WARNING: PostgreSQL dump failed. Continuing snapshot..."
        rm -f "$target_dump_file"
    fi
}

cmd_backup() {
    log "Starting backup..."
    local timestamp="$(date +%Y%m%d_%H%M%S)"
    local sql_dump="${SCRIPT_DIR}/postgres_cluster_${timestamp}.sql"

    dump_postgresql "$sql_dump"

    log "Creating Restic snapshot..."
    if restic backup -r "$REPO" --password-file "$PASS_FILE" "$STACK_DIR" \
        --exclude-file "$EXCLUDES_FILE" --tag "mediastack" --cleanup-cache 2>&1 | tee -a "$LOG_FILE"; then
        log "Restic snapshot created successfully."
    else
        log "ERROR: Restic snapshot failed!"
    fi

    rm -f "$sql_dump"

    log "Pruning old snapshots..."
    if ! restic forget -r "$REPO" --password-file "$PASS_FILE" --tag "mediastack" \
        --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 1 --prune 2>&1 | tee -a "$LOG_FILE"; then
        log "WARNING: Pruning old snapshots failed."
    fi

    log "Backup completed."
}

cmd_restore() {
    local snapshot_id="${1:-latest}"
    local target_dir="${2:-/home/julsito/mediastack-restore-$(date +%Y%m%d_%H%M%S)}"

    log "Restoring snapshot '$snapshot_id' to $target_dir..."
    mkdir -p "$target_dir"
    restic restore -r "$REPO" --password-file "$PASS_FILE" "$snapshot_id" --target "$target_dir" 2>&1 | tee -a "$LOG_FILE"

    log "Files restored to $target_dir"

    local restored_dump
    restored_dump="$(find "$target_dir" -path "*/scripts/backup/postgres_cluster_*.sql" 2>/dev/null | head -n 1 || true)"

    if [[ -n "$restored_dump" && -f "$restored_dump" ]]; then
        read -rp "Do you want to restore PostgreSQL database from $(basename "$restored_dump")? [y/N] " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            log "Restoring PostgreSQL database..."
            if sudo /usr/local/bin/mediastack-pg-restore < "$restored_dump" 2>&1 | tee -a "$LOG_FILE"; then
                log "PostgreSQL database restored successfully."
            else
                log "ERROR: PostgreSQL database restore failed!"
            fi
        fi
    fi

    log "Restore completed."
}

case "${1:-backup}" in
    backup)    cmd_backup ;;
    restore)   cmd_restore "${2:-latest}" "${3:-}" ;;
    snapshots) restic snapshots -r "$REPO" --password-file "$PASS_FILE" ;;
    check)     restic check -r "$REPO" --password-file "$PASS_FILE" ;;
    *) echo "Usage: $0 {backup|restore [snapshot_id] [target_dir]|snapshots|check}"; exit 1 ;;
esac
