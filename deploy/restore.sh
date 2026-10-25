#!/usr/bin/env bash
# Replaces the wiki's data with a backup.sh archive, or a bare SQLite copy of its database, and
# starts the wiki on it. If anything fails after the wiki stops, puts the earlier data back and
# starts the wiki.
#
# Usage: bash restore.sh <archive>   (the decrypted wiki.tar.gz, or a .sqlite copy of the database)
#        bash restore.sh --undo      (puts back the data an interrupted restore set aside)
set -euo pipefail

arg=${1:?usage: restore.sh <archive> | --undo}
if [ "$arg" != --undo ]; then
  [ -f "$arg" ] || { echo "Not found: $arg" >&2; exit 1; }
  # Absolute folder and file name of the archive, for Docker's mount.
  dir=$(cd "$(dirname "$arg")" && pwd)
  name=$(basename "$arg")
fi

# Compose finds docker-compose.yml, and the volumes, from this script's folder.
cd "$(dirname "$0")"

# Runs a script from stdin in a throwaway data-tools container (the wiki's volumes, as root).
data_tools() {
  docker compose run --rm --no-deps -T "$@" data-tools sh -s
}

# A restore swaps two folders: the data volume at /wiki/data (without the content volume mounted
# inside it), and the content volume at /wiki/data/content. In each, while a restore runs:
#   .restore-new      the archive's data
#   .restore-old      the data it replaces; .restore-old/.complete once all of it is there
#   .restore-discard  the replaced data, being deleted after a successful restore
# Prepended to each script run in data-tools.
# shellcheck disable=SC2016 # expanded in data-tools, not here
folders='
set -eu
roots="/wiki/data /wiki/data/content"
# Finds what is in a folder apart from the restore folders and the content volume, then applies
# any find actions given.
items() { folder=$1; shift; find "$folder" -mindepth 1 -maxdepth 1 ! -name ".restore-*" ! -path /wiki/data/content "$@"; }
# Gives the data to the image'"'"'s node user (1000), whom the wiki runs as. The Local File System
# storage target writes to /wiki/backups, which Docker makes owned by root.
own() { chown -R 1000:1000 /wiki/data && chown 1000:1000 /wiki/backups; }
'

# Puts each folder's .restore-old back, removing anything moved in from the archive.
undo() {
  {
    echo "$folders"
    cat <<'EOF'
for root in $roots; do
  old=$root/.restore-old
  [ -d "$old" ] || continue
  if [ -e "$old/.complete" ]; then items "$root" -exec rm -rf {} +; fi
  find "$old" -mindepth 1 -maxdepth 1 ! -name .complete -exec mv {} "$root/" \;
  # find ignores a failed mv, so rmdir checks all of it moved: anything left stays in .restore-old.
  rm -f "$old/.complete"
  rmdir "$old"
  rm -rf "$root/.restore-new"
done
own
EOF
  } | data_tools
}

# Starts the wiki and waits up to five minutes for it to answer /healthz. Leaves the answer in
# $answer: {"ok":true} once it has loaded its settings, or its setup page if it found none.
start_wiki() {
  local container state
  answer=""
  docker compose up -d wiki
  for _ in $(seq 150); do
    container=$(docker compose ps -aq wiki)
    state=$(docker inspect -f '{{.State.Restarting}} {{.RestartCount}}' "$container")
    if [ "$state" != "false 0" ]; then
      reason="the wiki is restarting"
      break
    fi
    if answer=$(docker compose exec -T wiki wget -q -O - http://127.0.0.1:3000/healthz 2>/dev/null); then
      return 0
    fi
    sleep 2
  done
  answer=""
  docker compose logs --tail 50 wiki
  return 1
}

if [ "$arg" = --undo ]; then
  # Exit code 3 means no .restore-old; any other failure is Docker's, and stops here.
  set_aside=0
  data_tools <<<'test -d /wiki/data/.restore-old || test -d /wiki/data/content/.restore-old || exit 3' || set_aside=$?
  if [ "$set_aside" = 3 ]; then
    echo "Nothing to undo: no data set aside by an interrupted restore."
    exit 0
  fi
  [ "$set_aside" = 0 ] || exit "$set_aside"
  docker compose stop wiki
  undo
  start_wiki
  echo "Put back the data from before the interrupted restore."
  exit 0
fi

# 1. With the wiki still running: unpack the archive into .restore-new and check its database.
echo "Unpacking and checking $name"
{
  echo "$folders"
  cat <<'EOF'
cd /wiki/data
for root in $roots; do
  if [ -d "$root/.restore-old" ]; then
    echo "An earlier restore was interrupted. The data from before it is in the volume at" >&2
    echo "$root/.restore-old. Check the wiki, then run: bash restore.sh --undo" >&2
    exit 1
  fi
  rm -rf "$root/.restore-new" "$root/.restore-discard"
done
trap 'rm -rf /wiki/data/.restore-new /wiki/data/content/.restore-new' EXIT
mkdir .restore-new content/.restore-new
# A bare database (ticket 23's copy) or a backup.sh archive.
if [ "$(head -c 15 "/backup/$NAME")" = "SQLite format 3" ]; then
  cp "/backup/$NAME" .restore-new/database.sqlite
else
  tar xzf "/backup/$NAME" -C .restore-new
fi
db=.restore-new/database.sqlite
[ -f "$db" ] || { echo "$NAME holds no database.sqlite" >&2; exit 1; }
result=$(sqlite3 "$db" 'PRAGMA integrity_check;' 2>&1) || true
[ "$result" = ok ] || { echo "The database in $NAME failed its integrity check: $result" >&2; exit 1; }
pages=$(sqlite3 "$db" 'SELECT count(*) FROM pages;' 2>&1) \
  || { echo "The database in $NAME is not a Wiki.js database: $pages" >&2; exit 1; }
echo "Its database passed SQLite's integrity check and holds $pages pages"
# The archive's content folder goes into the content volume's own .restore-new.
if [ -d .restore-new/content ]; then
  find .restore-new/content -mindepth 1 -maxdepth 1 -exec mv {} content/.restore-new/ \;
  rmdir .restore-new/content
fi
trap - EXIT
EOF
} | data_tools -v "$dir:/backup:ro" -e NAME="$name"

# From here on, any failure or interruption puts the earlier data back.
reason="it was interrupted or a step failed"
on_failure() {
  local status=$?
  trap - EXIT INT TERM
  echo "The restore failed: $reason. Putting back the data from before it." >&2
  docker compose stop wiki || true
  if undo && start_wiki; then
    echo "The wiki is running again on its data from before the restore." >&2
  else
    echo "Could not put the earlier data back. It is in the volumes at /wiki/data/.restore-old" >&2
    echo "and /wiki/data/content/.restore-old. To try again: bash restore.sh --undo" >&2
  fi
  exit $((status == 0 ? 1 : status))
}
trap on_failure EXIT
trap 'exit 130' INT TERM

# 2. Stop the wiki, set its data aside in .restore-old, and move the archive's in.
docker compose stop wiki
echo "Replacing the wiki's data with $name"
{
  echo "$folders"
  cat <<'EOF'
for root in $roots; do
  mkdir "$root/.restore-old"
  items "$root" -exec mv {} "$root/.restore-old/" \;
  # find ignores a failed mv: only mark it complete once nothing of the old data is left outside,
  # since undo deletes what is outside a complete .restore-old.
  [ -z "$(items "$root")" ]
  touch "$root/.restore-old/.complete"
done
for root in $roots; do
  find "$root/.restore-new" -mindepth 1 -maxdepth 1 -exec mv {} "$root/" \;
  rmdir "$root/.restore-new"
done
own
EOF
} | data_tools

# 3. Start the wiki and check it loaded the archive's settings: a wiki that finds none in its
#    database shows its setup page instead, and offers it to anyone who opens the site.
reason="the wiki did not finish starting"
start_wiki
if [ "$answer" != '{"ok":true}' ]; then
  reason="the wiki started its setup page, so it found no settings in the archive's database"
  exit 1
fi

# 4. Passed: delete the replaced data.
trap - EXIT INT TERM
{
  echo "$folders"
  cat <<'EOF'
for root in $roots; do
  mv "$root/.restore-old" "$root/.restore-discard"
  rm -rf "$root/.restore-discard"
done
EOF
} | data_tools || echo "Restored, but could not delete the replaced data in .restore-discard; the next restore will." >&2
echo "Restored $name"
