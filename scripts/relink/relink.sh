#!/usr/bin/env bash
#
# relink.sh - find media files no longer hardlinked to their torrent,
# delete them via Radarr/Sonarr (which also removes them from disk),
# then trigger a search so they get re-downloaded/re-hardlinked properly.
#
# Usage:
#   ./relink.sh            # dry-run (default): logs what WOULD happen
#   ./relink.sh --apply    # actually deletes + triggers searches
#
# Requires: bw (Bitwarden/Vaultwarden CLI), curl, jq
# Vaultwarden items expected: "Radarr" and "Sonarr", API key in first custom
# field, base URL in the URI field.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/relink.log"
MEDIA_ROOT="/data/media"

DRY_RUN=true
if [[ "${1:-}" == "--apply" ]]; then
    DRY_RUN=false
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

for cmd in bw curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' is required but not installed." >&2
        exit 1
    fi
done

log "=== relink run started (dry_run=$DRY_RUN) ==="

# --- Unlock vault and fetch credentials ---------------------------------

BW_STATUS="$(bw status | jq -r '.status')"
if [[ "$BW_STATUS" == "unauthenticated" ]]; then
    echo "Not logged in to Bitwarden/Vaultwarden. Run 'bw login' first." >&2
    exit 1
fi

echo -e "\nEnter your Vaultwarden vault's master password :\n"
BW_SESSION="$(bw unlock --raw)"
if [[ -z "$BW_SESSION" ]]; then
    echo "ERROR: failed to unlock vault." >&2
    exit 1
fi


get_item_field() {
    # $1 = item name, $2 = "apikey" or "uri"
    local item_json
    item_json="$(bw get item "$1" --session "$BW_SESSION")"
    if [[ "$2" == "apikey" ]]; then
        echo "$item_json" | jq -r '.fields[0].value'
    else
        echo "$item_json" | jq -r '.login.uris[0].uri'
    fi
}

RADARR_KEY="$(get_item_field "radarr" "apikey")"
RADARR_URL="$(get_item_field "radarr" "uri")"
SONARR_KEY="$(get_item_field "sonarr" "apikey")"
SONARR_URL="$(get_item_field "sonarr" "uri")"

for name_val in "RADARR_KEY:$RADARR_KEY" "RADARR_URL:$RADARR_URL" "SONARR_KEY:$SONARR_KEY" "SONARR_URL:$SONARR_URL"; do
    val="${name_val#*:}"
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "ERROR: missing ${name_val%%:*} - check Vaultwarden item fields." >&2
        exit 1
    fi
done

log "Vault credentials retrieved (Radarr key: ${RADARR_KEY:0:4}..., Sonarr key: ${SONARR_KEY:0:4}...)"

bw lock >/dev/null 2>&1 || true

# --- Find candidate files ------------------------------------------------

mapfile -t FILES < <(find "$MEDIA_ROOT" -type f -links 1 \( -name "*.mkv" -o -name "*.mp4" \))

log "Found ${#FILES[@]} unlinked file(s)"

# --- Process each file ----------------------------------------------------
declare -A SEASONS_DONE
 
for f in "${FILES[@]}"; do
    case "$f" in
        "$MEDIA_ROOT"/movies/*|"$MEDIA_ROOT"/animes-movies/*|"$MEDIA_ROOT"/documentary/*)
            APP="radarr"
            ;;
        "$MEDIA_ROOT"/tv/*|"$MEDIA_ROOT"/animes/*|"$MEDIA_ROOT"/documentary-tv/*)
            APP="sonarr"
            ;;
        *)
            log "SKIP  $f - path does not match any known Radarr/Sonarr root"
            continue
            ;;
    esac
 
    if [[ "$APP" == "radarr" ]]; then
        TMDB_ID="$(grep -oP '(?<=tmdbid-)\d+' <<< "$f" || true)"
        if [[ -z "$TMDB_ID" ]]; then
            log "SKIP  $f - no tmdbid found in filename"
            continue
        fi
 
        MOVIE_JSON="$(curl -sf -G "${RADARR_URL}/api/v3/movie" \
            --data-urlencode "tmdbId=${TMDB_ID}" \
            -H "X-Api-Key: ${RADARR_KEY}" || true)"
        MOVIE_ID="$(echo "$MOVIE_JSON" | jq -r '.[0].id // empty')"
        FILE_ID="$(echo "$MOVIE_JSON" | jq -r '.[0].movieFile.id // empty')"
 
        if [[ -z "$MOVIE_ID" || -z "$FILE_ID" ]]; then
            log "SKIP  $f - radarr: no movie/movieFile for tmdbId=$TMDB_ID"
            continue
        fi
 
        if $DRY_RUN; then
            log "DRY   $f -> radarr movieId=$MOVIE_ID fileId=$FILE_ID : would delete file + MoviesSearch"
            continue
        fi
 
        curl -sf -X DELETE "${RADARR_URL}/api/v3/moviefile/${FILE_ID}" \
            -H "X-Api-Key: ${RADARR_KEY}" >/dev/null
        log "DEL   $f -> radarr movieId=$MOVIE_ID fileId=$FILE_ID deleted"
 
        CMD_JSON="$(curl -sf -X POST "${RADARR_URL}/api/v3/command" \
            -H "X-Api-Key: ${RADARR_KEY}" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"MoviesSearch\",\"movieIds\":[${MOVIE_ID}]}")"
        CMD_ID="$(echo "$CMD_JSON" | jq -r '.id // empty')"
        log "SRCH  $f -> radarr MoviesSearch triggered commandId=$CMD_ID"
 
    else
        TVDB_ID="$(grep -oP '(?<=tvdbid-)\d+' <<< "$f" || true)"
        SEASON_RAW="$(grep -oP '(?<=[Ss])\d{2}(?=[Ee]\d{2})' <<< "$f" || true)"
 
        if [[ -z "$TVDB_ID" || -z "$SEASON_RAW" ]]; then
            log "SKIP  $f - no tvdbid or SxxExx season marker found in filename"
            continue
        fi
        SEASON_NUM=$((10#$SEASON_RAW))  # force base-10: "08" would else be invalid octal
 
        SERIES_JSON="$(curl -sf -G "${SONARR_URL}/api/v3/series" \
            --data-urlencode "tvdbId=${TVDB_ID}" \
            -H "X-Api-Key: ${SONARR_KEY}" || true)"
        SERIES_ID="$(echo "$SERIES_JSON" | jq -r '.[0].id // empty')"
 
        if [[ -z "$SERIES_ID" ]]; then
            log "SKIP  $f - sonarr: no series for tvdbId=$TVDB_ID"
            continue
        fi
 
        SEASON_KEY="${SERIES_ID}:${SEASON_NUM}"
        if [[ -n "${SEASONS_DONE[$SEASON_KEY]:-}" ]]; then
            log "SKIP  $f - seriesId=$SERIES_ID season=$SEASON_NUM already processed this run"
            continue
        fi
        SEASONS_DONE[$SEASON_KEY]=1
 
        FILE_IDS="$(curl -sf -G "${SONARR_URL}/api/v3/episodefile" \
            --data-urlencode "seriesId=${SERIES_ID}" \
            -H "X-Api-Key: ${SONARR_KEY}" \
            | jq -r --argjson s "$SEASON_NUM" '.[] | select(.seasonNumber == $s) | .id')"
 
        if [[ -z "$FILE_IDS" ]]; then
            log "SKIP  $f - sonarr: no episode files found for seriesId=$SERIES_ID season=$SEASON_NUM"
            continue
        fi
 
        if $DRY_RUN; then
            IDS_ONELINE="$(echo "$FILE_IDS" | tr '\n' ' ')"
            log "DRY   $f -> sonarr seriesId=$SERIES_ID season=$SEASON_NUM fileIds=[$IDS_ONELINE] : would delete all + SeasonSearch"
            continue
        fi
 
        while read -r fid; do
            curl -sf -X DELETE "${SONARR_URL}/api/v3/episodefile/${fid}" \
                -H "X-Api-Key: ${SONARR_KEY}" >/dev/null
            log "DEL   $f -> sonarr seriesId=$SERIES_ID season=$SEASON_NUM fileId=$fid deleted"
        done <<< "$FILE_IDS"
 
        CMD_JSON="$(curl -sf -X POST "${SONARR_URL}/api/v3/command" \
            -H "X-Api-Key: ${SONARR_KEY}" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"SeasonSearch\",\"seriesId\":${SERIES_ID},\"seasonNumber\":${SEASON_NUM}}")"
        CMD_ID="$(echo "$CMD_JSON" | jq -r '.id // empty')"
        log "SRCH  $f -> sonarr SeasonSearch triggered commandId=$CMD_ID"
    fi
done
 
log "=== relink run finished ==="
