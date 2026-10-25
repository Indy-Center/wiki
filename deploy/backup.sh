#!/usr/bin/env bash
# Writes the wiki's data to one archive, wiki.tar.gz, in the given folder: the database and the
# content folder. The wiki keeps running.
#
# Usage: bash backup.sh <empty output folder>
set -euo pipefail

out=${1:?usage: backup.sh <empty output folder>}
[ -d "$out" ] || { echo "Not a folder: $out" >&2; exit 1; }
# Docker needs an absolute path to mount the folder.
out=$(cd "$out" && pwd)

# Compose finds docker-compose.yml, and the volumes, from this script's folder.
cd "$(dirname "$0")"

# In a throwaway data-tools container: the wiki's volumes at /wiki/data, output folder at /out.
# OWNER is who ran this script.
docker compose run --rm --no-deps -T -v "$out:/out" -e OWNER="$(id -u):$(id -g)" \
  data-tools sh -s <<'EOF'
set -eu
data=/wiki/data
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
[ -f "$data/database.sqlite" ] || { echo "No database at $data/database.sqlite" >&2; exit 1; }

# The database, by SQLite's online backup, then an integrity check of the copy. It holds the
# pages, uploaded files, users, settings and the sign-in keys.
sqlite3 "$data/database.sqlite" ".backup '$work/database.sqlite'"
result=$(sqlite3 "$work/database.sqlite" 'PRAGMA integrity_check;')
[ "$result" = ok ] || { echo "The copied database failed its integrity check: $result" >&2; exit 1; }

# The content folder, kept with its owners and modes. Everything else in /wiki/data is left out:
# cache/ and uploads/ (Wiki.js's rendered pages and half-finished uploads, rebuilt or dropped on
# start) and export/, export-1/ and the like (copies of the database made from the admin area).
cp -a "$data/content" "$work/"

# One archive, written under a temporary name and renamed when complete, readable only by the caller.
(umask 077 && tar czf /out/.wiki.tar.gz.partial -C "$work" .)
chown "$OWNER" /out/.wiki.tar.gz.partial
chmod 600 /out/.wiki.tar.gz.partial
mv /out/.wiki.tar.gz.partial /out/wiki.tar.gz
EOF
