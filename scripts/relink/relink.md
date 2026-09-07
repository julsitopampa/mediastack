# relink.sh — Documentation

## Purpose

Torrent clients (qBittorrent, etc.) commonly seed a file that is
**hard-linked** into your Jellyfin media library, so the same data on disk
is referenced by both the torrent client and Jellyfin without duplicating
storage. See the [Hard link](https://en.wikipedia.org/wiki/Hard_link)
concept: a hard link is a second directory entry pointing at the same
inode, not a copy. When the torrent client removes, re-hashes, or replaces
that underlying file (a re-release, a cross-seed cleanup, a client
re-check), the link count on your library copy can drop to `1` — meaning
your Jellyfin copy is now the *only* reference left, orphaned from the
torrent that was keeping it seeded/maintained.

`relink.sh` finds those orphaned files, removes them properly through
[Radarr](https://radarr.video/) (movies) or [Sonarr](https://sonarr.tv/)
(TV) — not with a raw `rm` — and triggers a fresh search so the *arr app
re-downloads and re-hardlinks the content correctly.

This is a **manual maintenance script**, not a scheduled job: it requires
an interactive [Vaultwarden](https://github.com/dani-garcia/vaultwarden)
unlock each run, by design.

---

## Prerequisites

| Tool | Purpose | Reference |
|---|---|---|
| [`bw`](https://bitwarden.com/help/cli/) | Bitwarden/Vaultwarden CLI, used to fetch API keys | Bitwarden CLI docs |
| [`curl`](https://curl.se/docs/manpage.html) | HTTP calls to Radarr/Sonarr | curl man page |
| [`jq`](https://jqlang.org/) | Parses JSON responses from `bw` and the *arr APIs | jq manual |

Vaultwarden setup expected:
- Item named **`radarr`**: API key in the **first custom field** on the item, base URL in the **URI** field
- Item named **`sonarr`**: same layout
- You must already be logged in via `bw login` before running the script (`bw unlock` alone isn't enough on a fresh machine)

---

## First-time setup

Run once, on the Jellyfin box, before the first execution of `relink.sh`.

**1. Install dependencies**

```bash
# jq, curl, unzip (Debian/Ubuntu)
sudo apt update && sudo apt install -y jq curl unzip
```

**2. Download and install the `bw` binary** :

Check [github.com/bitwarden/clients/releases](https://github.com/bitwarden/clients/releases)
for the latest tag starting with `cli-v` — as of this writing that's
`cli-v2026.8.0` — and substitute the version number below if a newer one
has shipped since:

```bash
cd /tmp

wget https://github.com/bitwarden/clients/releases/download/cli-v2026.8.0/bw-linux-2026.8.0.zip
unzip bw-linux-2026.8.0.zip

chmod u+x bw
sudo mv bw /usr/local/bin/bw
```

`/usr/local/bin` is on `$PATH` by default on essentially every Linux
distro — that's what makes `bw` callable from anywhere afterward, without
needing to `export PATH=...` yourself. Confirm it worked:

```bash
bw --version
```

Optional but worth doing on a server you'll trust with vault access:
verify the download's SHA-256 checksum against the one Bitwarden
publishes per release (see the "Assets" section of the release page) —
[checksum verification instructions](https://bitwarden.com/help/cli/#download-and-install).

**2. Point `bw` at your Vaultwarden instance** (not the public Bitwarden
cloud — Vaultwarden is self-hosted, so the CLI needs to be told the server
explicitly):

```bash
bw config server https://vaultwarden.<domain>.fr
```

**3. Log in** (interactive, one-time — persists auth state under
`~/.config/Bitwarden CLI` for this user):

```bash
bw login
```

**4. Make the script executable and set ownership**:

```bash
chmod 750 relink.sh
chown 1000:1000 relink.sh
```
---

## Usage

```bash
./relink.sh            # dry-run (default) — logs what would happen, changes nothing
./relink.sh --apply    # live run — deletes files via API and triggers re-search
```

Runs as UID/GID `1000:1000`. Logs to `relink.log` in the same directory as
the script (both to that file and to stdout).

---

## How a file is found

```bash
find "$MEDIA_ROOT" -type f -links 1 \( -name "*.mkv" -o -name "*.mp4" \)
```

`-links 1` is the load-bearing flag: it filters to files whose
[link count](https://man7.org/linux/man-pages/man1/find.1.html) is exactly
1, i.e. no other directory entry (like the torrent client's copy) still
points at that inode. `\( -name "*.mkv" -o -name "*.mp4" \)` is a
parenthesised OR group — the backslash-escaped parens stop the shell from
treating them as a subshell, letting `find` treat them as its own grouping
syntax (see the [GNU findutils
manual](https://www.gnu.org/software/findutils/manual/html_mono/find.html#Combining-Primaries-With-Operators)).

Results are loaded into a bash array with
[`mapfile -t`](https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html#index-mapfile)
rather than `FILES=($(find ...))`. The latter is a classic shell
[word-splitting](https://mywiki.wooledge.org/WordSplitting) trap: any
filename containing a space would be split into multiple array entries.
`mapfile` reads line-by-line instead, which is safe as long as filenames
don't contain literal newlines (a safe bet for media files).

---

## How credentials are retrieved

```bash
bw status | jq -r '.status'          # confirm logged in
bw unlock --raw                       # interactive master-password prompt
```

The script prints an explicit prompt (`echo -e "\nEnter your Vaultwarden
vault's master password :\n"`) right before this call, since `bw unlock`'s
own prompt can otherwise appear with no context if you're not expecting
it.

`bw unlock --raw` returns a **session key**
([`BW_SESSION`](https://bitwarden.com/help/cli/#using-bw-session)) — a
token that authorizes subsequent `bw` calls without re-entering your
master password. It's kept in a local shell variable, never written to
disk, and explicitly discarded at the end via `bw lock`. It's *not*
exported into the environment — each `bw` call receives it directly via
the `--session` flag instead, which is enough since nothing downstream
needs it implicitly picked up from the environment.

Each credential is fetched with:

```bash
bw get item "radarr" --session "$BW_SESSION"
```

which returns a Bitwarden [item
object](https://bitwarden.com/help/cli/#get) as JSON. `jq` then pulls
either the base URL (`.login.uris[0].uri`) or the API key. The API key
comes from `.fields[0].value` — the **first custom field** defined on the
item, not the login password. This means field *order* on the Vaultwarden
item matters: if a second custom field is ever added above the API key
field, this lookup would silently start returning the wrong value instead
of failing loudly, since `.fields[0]` would still resolve to *something*.
out of it.

### The `name:value` validation loop

```bash
for name_val in "RADARR_KEY:$RADARR_KEY" "RADARR_URL:$RADARR_URL" ...; do
    val="${name_val#*:}"
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "ERROR: missing ${name_val%%:*} ..." >&2
        exit 1
    fi
done
```

Bash has no built-in way to iterate "variable name + its value" pairs, so
each loop item is a synthetic `NAME:value` string. Two [parameter
expansion](https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html)
operators pull them apart:

- `${name_val#*:}` — strip the **shortest** match of `*:` from the
  **front** → leaves everything after the first colon (the value)
- `${name_val%%:*}` — strip the **longest** match of `:*` from the
  **back** → leaves everything before the first colon (the name)

| Form | Trims | Greediness | Keeps |
|---|---|---|---|
| `${v#pat}` | front | shortest | after match |
| `${v##pat}` | front | longest | after match |
| `${v%pat}` | back | shortest | before match |
| `${v%%pat}` | back | longest | before match |

This combination (`#` single / `%%` double) is deliberate: it's the only
pairing that correctly splits on the *first* colon even when the value
itself contains colons — which a URL like `http://192.168.1.10:7878`
does. Using `##*:` or `%:*` instead would grab the wrong side of a
later colon (e.g. the port number).

The check also explicitly tests for the literal string `"null"`, not just
emptiness — because `jq -r` prints the text `null` (not an empty string)
when a JSON field is missing. Without that check, a misnamed Vaultwarden
field would silently become the string `"null"` sent as an API key,
surfacing later as a confusing `401 Unauthorized` from Radarr instead of
a clear error here.

`set -u` (see below) is also why `${1:-}` is used for the `--apply`
argument check — `${var:-default}` substitutes `default` only when `var`
is unset, letting "no CLI argument" resolve to dry-run instead of
crashing.

---

## Safety mechanisms

### `set -euo pipefail`

The three [bash strict-mode](http://redsymbol.net/articles/unofficial-bash-strict-mode/) flags:

- `-e` — exit immediately if any command fails (non-zero exit)
- `-u` — treat use of an unset variable as an error
- `-o pipefail` — a pipeline (`a | b`) fails if *any* stage fails, not just the last one

This is why several external commands are explicitly followed by `|| true`
where failure is an expected, handled case (e.g. `grep` finding no match)
rather than a bug — without it, `-e` would kill the script on a routine
"this file doesn't match" outcome.

### Dry-run by default

`DRY_RUN=true` unless `--apply` is passed. Every destructive branch
(`DELETE`/`POST /command`) is gated behind `if $DRY_RUN; then log "DRY ..."; continue; fi`,
so a dry-run and a live run walk the exact same resolution logic and
differ only in whether the API calls that mutate anything actually fire.

---

## Radarr flow

Reference: [Radarr API docs](https://radarr.video/docs/api/)

1. **ID extraction from filename** — Radarr's own
   [TRaSH-Guides](https://trash-guides.info/) naming convention embeds
   the [TMDb](https://www.themoviedb.org/) ID as `[tmdbid-XXXXX]`:

   ```bash
   TMDB_ID="$(grep -oP '(?<=tmdbid-)\d+' <<< "$f" || true)"
   ```

   `-P` enables [PCRE](https://www.pcre.org/) mode, which is what makes
   `(?<=tmdbid-)` — a **lookbehind** assertion — available. A lookbehind
   matches a position only if the given text precedes it, without
   including that text in the result. So against
   `...[tmdbid-11324]...`, the match is `11324` alone: the `tmdbid-`
   prefix is required but not captured. `\d+` is the digit sequence
   actually returned; `-o` prints only the match, not the whole line.

2. **Resolve to a Radarr movie** —
   `GET /api/v3/movie?tmdbId=<id>` returns an array (usually one element)
   of movie objects; `.[0].id` is the Radarr-internal movie ID, and
   `.[0].movieFile.id` is the ID of the *currently attached file record*
   (this is `null`/absent if Radarr thinks the movie isn't downloaded,
   which is logged and skipped).

3. **Delete the file, not the movie**:

   ```
   DELETE /api/v3/moviefile/{id}
   ```

   This removes the file from disk **and** clears Radarr's file record,
   while the movie entry itself — monitoring, quality profile, tags,
   history — stays intact. (Radarr also exposes `DELETE
   /api/v3/movie/{id}?deleteFiles=true`, which removes the *entire movie*
   from the library — deliberately **not** used here, since that would
   also wipe monitoring/profile config for something we want re-fetched,
   not forgotten.)

4. **Trigger re-download**:

   ```
   POST /api/v3/command   { "name": "MoviesSearch", "movieIds": [id] }
   ```

   Radarr's [command
   system](https://radarr.video/docs/api/#/Command) queues an
   asynchronous search; the response's `.id` is a command ID, logged for
   traceability but not polled for completion.

---

## Sonarr flow

Reference: [Sonarr API docs](https://sonarr.tv/docs/api/)

Sonarr's data model is one level deeper than Radarr's: a media file maps
to one **episode**, episodes belong to a **season**, seasons belong to a
**series**. This script intentionally treats the **season** as the unit
of repair — if one episode's hardlink broke, the whole season's files are
deleted and re-searched together, on the reasoning that a season torrent
pack changing invalidates the whole pack, not just one file within it.

1. **ID + season extraction from filename**:

   ```bash
   TVDB_ID="$(grep -oP '(?<=tvdbid-)\d+' <<< "$f" || true)"
   SEASON_RAW="$(grep -oP '(?<=[Ss])\d{2}(?=[Ee]\d{2})' <<< "$f" || true)"
   ```

   The TVDb ID extraction mirrors Radarr's lookbehind. The season regex
   uses **both** a lookbehind and a **lookahead**
   (`(?=[Ee]\d{2})` — "must be followed by this, without capturing it"):
   against `...S05E09...`, `S` satisfies the lookbehind, `E09` satisfies
   the lookahead, and only the two digits in between — `05` — are
   captured into `SEASON_RAW`.

2. **Fix the octal trap**:

   ```bash
   SEASON_NUM=$((10#$SEASON_RAW))
   ```

   `SEASON_RAW` is a string like `"05"`. Bash [arithmetic
   evaluation](https://www.gnu.org/software/bash/manual/html_node/Shell-Arithmetic.html)
   treats a leading-zero number as **octal** by default — and `08`/`09`
   aren't valid octal digits, so `$((SEASON_RAW))` alone would throw an
   error on exactly those two season numbers. `10#` is bash's explicit
   base-prefix syntax (`base#number`), forcing base-10 interpretation
   regardless of the leading zero.

3. **Resolve the series**: `GET /api/v3/series?tvdbId=<id>` → `.[0].id`.

4. **Season-level deduplication**:

   ```bash
   SEASON_KEY="${SERIES_ID}:${SEASON_NUM}"
   if [[ -n "${SEASONS_DONE[$SEASON_KEY]:-}" ]]; then
       ...skip...
   fi
   SEASONS_DONE[$SEASON_KEY]=1
   ```

   `SEASONS_DONE` is a bash [associative
   array](https://www.gnu.org/software/bash/manual/html_node/Arrays.html)
   (`declare -A`) — a string-keyed dictionary. The key combines series ID
   and season number (e.g. `"42:2"`). Only the key's *existence* matters;
   the value `1` is arbitrary. This ensures that if several broken files
   from the same series+season appear in one `find` result set, the
   season is only deleted and re-searched **once**, not once per file.

5. **Fetch and filter episode files**:

   ```bash
   curl -sf -G "${SONARR_URL}/api/v3/episodefile" \
       --data-urlencode "seriesId=${SERIES_ID}" \
       -H "X-Api-Key: ${SONARR_KEY}" \
   | jq -r --argjson s "$SEASON_NUM" '.[] | select(.seasonNumber == $s) | .id'
   ```

   `curl -G --data-urlencode` builds a proper `GET
   .../episodefile?seriesId=42` request. Sonarr's `episodefile` endpoint
   returns **every** file for the whole series, across all seasons — so
   filtering to one season happens client-side, in `jq`:

   - `--argjson s "$SEASON_NUM"` injects the bash variable as a JSON
     **number** (not a string). This distinction matters: `jq`'s `--arg`
     would inject it as a string, and `"2" == 2` is `false` in `jq`
     comparisons, silently matching nothing.
   - `.[] | select(.seasonNumber == $s) | .id` streams each array
     element, keeps only matching-season objects, and extracts their
     `id`.
   - `-r` (raw output) strips the JSON quoting, giving one bare number
     per line — this is what makes the later
     `while read -r fid; do ... done <<< "$FILE_IDS"` loop work directly
     on the output.

6. **Delete every file in the season, then search once**:

   ```
   DELETE /api/v3/episodefile/{id}     # once per file
   POST /api/v3/command   { "name": "SeasonSearch", "seriesId": ..., "seasonNumber": ... }
   ```

   **Operational consequence worth being explicit about**: deletion is
   synchronous and happens *before* the search is triggered. Between the
   last `DELETE` and Sonarr actually completing the re-download, the
   entire season is absent from disk and therefore from Jellyfin — not
   just the one file that lost its hardlink. This is intentional given
   the season-level repair strategy, but means a slow re-download creates
   a real, visible gap in your library during that window.

---

## Logging

```bash
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}
```

[`tee -a`](https://man7.org/linux/man-pages/man1/tee.1.html) writes to
both stdout and appends to `relink.log` in one step, so you get live
output when running interactively and a persistent audit trail either
way. Log line prefixes (`SKIP`, `DRY`, `DEL`, `SRCH`) are a simple
convention for grepping the log afterward, e.g. `grep '^.*DEL' relink.log`
to see everything actually deleted in a given run.