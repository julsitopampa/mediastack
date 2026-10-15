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

It is meant to run **unattended, once a day, from cron** (see
[Scheduling](#scheduling)). Credentials come from a `chmod 600` env file
instead of an interactive vault unlock.

## Intended workflow

The script is the second half of a two-part clean-up for torrents the
tracker has removed ("unregistered"):

1. **qui purges the dead torrent.** An [automation
   rule](https://getqui.com/docs/features/automations/) in
   [qui](https://getqui.com/) matches `Unregistered is true` and deletes
   the torrent **with its files, preserving cross-seeds**. Deleting removes
   the torrent's own directory entry for each file, so the library copy's
   link count drops from 2 to 1. If a live cross-seed still shares the
   files they are kept, the count stays above 1, and the script correctly
   leaves that file alone.
2. **`relink.sh` repairs the library.** Later, cron runs the script: it
   finds the files now at link count 1, deletes them through Radarr/Sonarr,
   and triggers a search so a fresh, seeding, hard-linked copy replaces
   them.

The two parts are decoupled on purpose. qui's Delete action must be
standalone (it can't be combined with "run external program"), and once
the torrent is gone there is nothing left to hand to a program. So the
script takes no torrent data: it sweeps the whole library for orphans.

Two requirements follow:

- The purge rule's delete mode must **remove files**. A plain "Delete
  (keep files)" leaves the downloads copy in place, the link count stays
  at 2, and the script never sees the file.
- The `Unregistered` condition needs qBittorrent 5.1 or newer.

---

## Prerequisites

| Tool | Purpose | Reference |
|---|---|---|
| [`curl`](https://curl.se/docs/manpage.html) | HTTP calls to Radarr/Sonarr | curl man page |
| [`jq`](https://jqlang.org/) | Parses JSON responses from the *arr APIs | jq manual |
| [GNU `grep`](https://www.gnu.org/software/grep/manual/grep.html) | `-P` (PCRE) powers the lookbehind regexes; BusyBox `grep` lacks it | grep manual |
| [`cron`](https://man7.org/linux/man-pages/man5/crontab.5.html) | Daily scheduling | crontab(5) |

The script runs on the host, not inside the qui container, as UID/GID
`1000:1000`. It needs read access to `/data/media`.

---

## First-time setup

Run once, on the host.

**1. Install dependencies** (Debian/Ubuntu):

```bash
sudo apt update && sudo apt install -y jq curl
```

**2. Create the env file** at the absolute path set as `ENV_FILE` in the
script, with exactly these four names and unquoted values:

```
RADARR_URL=http://localhost:7878
RADARR_KEY=<radarr api key>
SONARR_URL=http://localhost:8989
SONARR_KEY=<sonarr api key>
```

Each app's API key is under **Settings → General → Security** in its web
UI. Then lock the file down:

```bash
chmod 600 /absolute/path/to/.env
chown 1000:1000 /absolute/path/to/.env
```

**3. Make the script executable**:

```bash
chmod 750 relink.sh
chown 1000:1000 relink.sh
```

**4. Dry-run in a cron-like environment**, to prove the script doesn't
depend on your interactive shell:

```bash
env -i HOME="$HOME" PATH=/usr/bin:/bin /absolute/path/relink.sh
```

The log should show `Found N unlinked file(s)` and `DRY` lines that match
your own `find` output.

**5. Do one live run by hand** (`--apply`), read `relink.log`, and only
then add the cron line from [Scheduling](#scheduling).

---

## Usage

```bash
./relink.sh            # dry-run (default) — logs what would happen, changes nothing
./relink.sh --apply    # live run — deletes files via API and triggers re-search
```

Runs as UID/GID `1000:1000`. Logs to `relink.log` in the same directory as
the script (to the file and to stdout).

### Scheduling

Install with `crontab -e` as the `1000:1000` user, not root:

```cron
0 0 * * * /absolute/path/relink.sh --apply >/dev/null 2>>/absolute/path/relink.log
```

- `>/dev/null` drops stdout, since `log()` already writes the same lines
  to `relink.log`; `2>>` appends stderr to that file so errors land in
  one place.
- Cron's `PATH` is minimal (typically `/usr/bin:/bin`). If `jq` or `curl`
  live elsewhere, add a `PATH=` line at the top of the crontab.
- Because the run happens once per period, no lock is used. Overlap would
  need a run that outlasts the period, or a manual run at the same moment.

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

The four values come from a `chmod 600` env file, read without executing it:

```bash
ENV_FILE="/absolute/path/to/.env"
env_get() { grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2- || true; }

RADARR_URL="$(env_get RADARR_URL)"
RADARR_KEY="$(env_get RADARR_KEY)"
SONARR_URL="$(env_get SONARR_URL)"
SONARR_KEY="$(env_get SONARR_KEY)"
```

- **Why not `source .env`:** [`source`](https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html)
  executes the file as shell code and loads every variable in it into the
  script and its `curl` children. If the file is shared with other
  services, that includes secrets this script has no business seeing.
  Extracting four named lines avoids both problems.
- **`grep -m1 "^$1="`:** [`grep`](https://man7.org/linux/man-pages/man1/grep.1.html)
  returns the first line that *starts with* the name plus `=`. The `^`
  anchor stops `OLD_RADARR_KEY=` from matching `RADARR_KEY`, and `-m1`
  stops at the first hit.
- **`cut -d= -f2-`:** [`cut`](https://man7.org/linux/man-pages/man1/cut.1.html)
  splits the line on `=` (`-d=`) and prints field 2 **through the end**
  (the trailing `-` makes it a range). That keeps any `=` inside the
  value. Plain `-f2` would print only up to the next `=` and silently cut
  off an API key ending in `=` padding, which would surface later as a
  confusing `401`.
- **`|| true`:** under `set -e` and `pipefail`, a missing key would make
  `grep` fail and kill the script silently. With it, the value comes back
  empty and the validation loop below prints a clear `missing ...` error.
- **Constraints:** values must be unquoted (quotes would be kept as part of
  the value); `ENV_FILE` must be an absolute path, since cron starts in
  `$HOME`; and the file should be `chmod 600`, owned by `1000:1000`. If
  your `.env` is shared with other services, prefer a dedicated file with
  only these four lines.

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

The check also tests for the literal string `"null"`. That guard dates
from the Vaultwarden version, where `jq -r` printed `null` for a missing
JSON field. With the env-file lookups an absent key yields an **empty**
string, which the `-z` test catches; the `"null"` test is harmless and
can stay.

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

1. **ID extraction from filename** — the movie folder and the file both
   carry the [TMDb](https://www.themoviedb.org/) ID as `{tmdb-XXXXX}`, so
   a full path contains it **twice**:

   ```
   /data/media/movies/Moonlight (2016) {tmdb-376867}/Moonlight (2016) {tmdb-376867} [WEBDL-1080p][EAC3 5.1][h264]-ACKER.mkv
   ```

   ```bash
   TMDB_ID="$(grep -oP '(?<=\{tmdb-)\d+' <<< "$f" | head -n1 || true)"
   ```

   - `-P` enables [PCRE](https://www.pcre.org/) mode, which makes
     `(?<=\{tmdb-)` — a **lookbehind** assertion — available. It matches
     a position only if the given text precedes it, without including
     that text in the result. The `\{` escapes the brace so PCRE reads it
     literally instead of as a quantifier.
   - `\d+` is the digit sequence returned; `-o` prints every match, not
     just the first, which here means two lines (`376867` twice).
   - `| head -n1` keeps only the first. `grep -m1` would not work: it
     stops after the first matching *line*, and the whole path is one
     line.
   - `|| true` is still needed: with `pipefail`, a path with no tag makes
     the pipeline fail, and `set -e` would kill the script instead of
     reaching the `-z` check that logs a clean skip.

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
   TVDB_ID="$(grep -oP '(?<=\{tvdb-)\d+' <<< "$f" | head -n1 || true)"
   SEASON_RAW="$(grep -oP '(?<=[Ss])\d{2}(?=[Ee]\d{2})' <<< "$f" || true)"
   ```

   The TVDb ID extraction works like Radarr's: the `{tvdb-XXXXX}` tag
   appears in both the series folder and the file, so `| head -n1` keeps
   only the first. Without it `TVDB_ID` would hold two lines and the
   `tvdbId=` query would be malformed. The season regex
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

Under cron, stdout is discarded (`>/dev/null`) because `log()` already
writes every line to the file; stderr is appended to the same file, so
`ERROR:` messages and `set -e` failures end up in one place.