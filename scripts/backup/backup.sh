#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "${SCRIPT_DIR}/../../" && pwd)"
LOG_FILE="${SCRIPT_DIR}/backup.log"
EXCLUDES_FILE="${SCRIPT_DIR}/restic-excludes.txt"
export RESTIC_PASSWORD_FILE="/home/$USER/.config/restic/password"
export RESTIC_REPOSITORY="/data/backup/mediastack"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

# --- Pre-flight Checks ---

if ! grep -qs '/data ' /proc/mounts; then
    echo "ERROR: Backup destination '/data' is not mounted." >&2
    exit 1
fi

if [[ ! -f "$RESTIC_PASSWORD_FILE" ]]; then
    echo "ERROR: Password file missing at $PASS_FILE" >&2
    exit 1
fi

if ! restic snapshots >/dev/null 2>&1; then
    echo "ERROR: Restic repository at $RESTIC_REPOSITORY is not initialized or unreachable." >&2
    echo "Initialize it once with: restic init" >&2
    exit 1
fi

dump_postgresql() {
    local target_dump_file="$1"

    log "Dumping PostgreSQL databases..."
    if sudo /usr/local/bin/mediastack-pg dump > "$target_dump_file" 2>&1 | tee -a "$LOG_FILE"; then
        chmod 600 "$target_dump_file"
    else
        log "WARNING: PostgreSQL dump failed. Continuing snapshot..."
        rm -f "$target_dump_file"
    fi
}

dump_sqlite() {
    log "Finding SQlite databases..."
    mapfile -t DB < <(find "$STACK_DIR" -type f -name '*.db' 2>/dev/null)

    # directory name after 'appadat/' + '-' + 'filename'
    local db_name="$(grep -oP '(?<=appdata\/)[a-z]+(?=\/)' <<< "$d" || true)-$(grep-oP '(?<=\/)[a-zA-Z0-9-_]+.db' <<< "$d" || true)"

    log "Dumping SQlite databases..."
    for d in "${DB[@]}"; do
        if sqlite3 $d ".backup '$SCRIPT_DIR/sqlite/$db_name'" 2>&1 | tee -a "$LOG_FILE"; then
            chmod 600 "$SCRIPT_DIR/sqlite/$db_name"
        else
            log "WARNING: SQlite dump failed. Continuing snapshot..."
            rm -f "$SCRIPT_DIR/sqlite/$db_name"
    done

    for d in "$SCRIPT_DIR/sqlite/*.db"; do
        result=$(sqlite3 "$d" "PRAGMA integrity_check;")
        [ "$result" = "ok" ] || { log "INTEGRITY FAIL: $db -> $result"; exit 1; }
    done
}

cmd_backup() {
    log "Starting backup..."
    local timestamp="$(date +%Y%m%d_%H%M%S)"
    local sql_dump="${SCRIPT_DIR}/pgsql/postgres_cluster_${timestamp}.sql"

    dump_postgresql "$sql_dump"
    dump_sqlite

    log "Creating Restic snapshot..."
    if restic backup "$STACK_DIR" \
        --exclude-file "$EXCLUDES_FILE" --tag "mediastack" --cleanup-cache 2>&1 | tee -a "$LOG_FILE"; then
        log "Restic snapshot created successfully."
    else
        log "ERROR: Restic snapshot failed!"
    fi

    rm -f "$sql_dump"
    rm -f "${SCRIPT_DIR}/sqlite/*"

    log "Pruning old snapshots..."
    if ! restic forget --tag "mediastack" \
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
    restic restore "$snapshot_id" --target "$target_dir" 2>&1 | tee -a "$LOG_FILE"

    log "Files restored to $target_dir"

    local restored_dump
    restored_dump="$(find "$target_dir" -path "*/scripts/backup/postgres_cluster_*.sql" 2>/dev/null | head -n 1 || true)"

    if [[ -n "$restored_dump" && -f "$restored_dump" ]]; then
        read -rp "Do you want to restore PostgreSQL database from $(basename "$restored_dump")? [y/N] " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            log "Restoring PostgreSQL database..."
            if sudo /usr/local/bin/mediastack-pg restore < "$restored_dump" 2>&1 | tee -a "$LOG_FILE"; then
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
    snapshots) restic snapshots ;;
    check)     restic check --read-data-subset=10% ;;
    *) echo "Usage: $0 {backup|restore [snapshot_id] [target_dir]|snapshots|check}"; exit 1 ;;
esac
