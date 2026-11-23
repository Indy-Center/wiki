#!/usr/bin/env bash
# Proves deploy/backup.sh and deploy/restore.sh round-trip a real wiki: start Wiki.js on empty
# volumes, finish its first-run setup, create a page through the GraphQL API, back up, wipe the
# volumes, restore, and check the page and the admin's sign-in are back. Also checks a refused,
# failed or interrupted restore leaves the wiki on its earlier data, and that restore.sh takes a
# bare SQLite copy (what ticket 23 took off the old server). CI runs it on every pull request.
#
# Usage: bash tests/backup-round-trip.sh
# Needs Docker. Publishes no ports. Everything it starts is named after WIKI_TEST_PROJECT
# (default wiki-round-trip): containers, volumes and a network, all removed when it ends.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
project=${WIKI_TEST_PROJECT:-wiki-round-trip}

# The app folder, as on the VPS. Its name is the compose project, so the volumes are
# <project>_db-data and so on.
work=$(mktemp -d)
app=$work/$project
cp -r "$repo/deploy" "$app"
cd "$app"

# The wiki joins the external traefik-shared network, which this machine may already have for
# something else. The test gives it a network of its own instead, through an override file that
# backup.sh and restore.sh pick up too, since COMPOSE_FILE is in their environment.
network=$project-traefik-shared
cat > "$work/test-network.yml" <<EOF
networks:
  traefik-shared:
    name: $network
EOF
export COMPOSE_FILE="$app/docker-compose.yml:$work/test-network.yml"
docker network create "$network" >/dev/null

# Remove the test's containers, volumes, network and files however the test ends.
cleanup() {
  if cd "$app"; then docker compose --profile tools down -v --remove-orphans >/dev/null 2>&1 || true; fi
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  docker compose logs --tail 30 wiki >&2 || true
  exit 1
}

# Sends one request to the wiki from inside its own container (no ports are published) and
# prints the status and the body. Usage: request METHOD PATH [JSON BODY] [TOKEN]
request() {
  docker compose exec -T wiki node -e '
    const [method, path, body, token] = process.argv.slice(1);
    const headers = { "content-type": "application/json" };
    if (token) headers.authorization = `Bearer ${token}`;
    fetch(`http://127.0.0.1:3000${path}`, { method, headers, body: body || undefined })
      .then(async (res) => console.log(res.status, await res.text()))
      .catch((err) => { console.error(err.message); process.exit(1); });
  ' "$@"
}

# Sends a GraphQL query and prints the JSON answer. Usage: gql QUERY [TOKEN]
gql() {
  local body
  body=$(jq -n --arg query "$1" '{query: $query}')
  request POST /graphql "$body" "${2:-}" | sed 's/^[0-9]* //'
}

# Waits up to three minutes for the wiki to answer /healthz with the given body's start:
# '{"ok":true}' once set up, '<!DOCTYPE html>' while it shows its setup page.
wait_for() {
  for _ in $(seq 90); do
    [[ $(request GET /healthz 2>/dev/null) == "200 $1"* ]] && return 0
    sleep 2
  done
  fail "the wiki never answered /healthz with $1"
}

email=round-trip@example.com
password=round-trip-password
title="Round trip"
content="Made by the round trip."

# Signs in as the admin and prints the session token.
sign_in() {
  gql "mutation { authentication { login(username: \"$email\", password: \"$password\", strategy: \"local\") { responseResult { succeeded message } jwt } } }" \
    | jq -r '.data.authentication.login.jwt // empty'
}

# Prints the test page's title and content, as the API returns them.
page() {
  gql '{ pages { singleByPath(path: "round-trip", locale: "en") { title content } } }' "$1" \
    | jq -c '.data.pages.singleByPath'
}

# Runs a command in the wiki's volumes, as root, with no network.
in_volumes() { docker compose run --rm --no-deps -T data-tools sh -c "$1" </dev/null; }

# Checks the wiki holds the test's data: the page, the admin's sign-in, and the session token
# from before the backup (signed with keys kept in the database).
check_data() {
  local token
  token=$(sign_in)
  [ -n "$token" ] || fail "$1: the admin can't sign in"
  [ "$(page "$token")" = "$expected_page" ] || fail "$1: the page is not as it was: $(page "$token")"
  [[ $(gql '{ users { profile { email } } }' "$old_token") == *"\"email\":\"$email\""* ]] \
    || fail "$1: the session token from before the backup no longer works"
}

# Fails if a restore left its working folders in the volumes.
no_leftovers() {
  local left
  left=$(in_volumes 'ls -A /wiki/data /wiki/data/content | grep "^\.restore-" || true')
  [ -z "$left" ] || fail "$1: left in the volumes: $left"
}

running() { [ -n "$(docker compose ps -q --status running wiki)" ]; }

echo "--- Start the wiki on empty volumes; it shows its setup page"
docker compose up -d
# restore.sh tells a wiki that started without its settings by this: /healthz answers with the
# setup page rather than {"ok":true}.
wait_for '<!DOCTYPE html>'
# Its database, kept for later: the schema and no settings, as in a wiki never set up.
mkdir "$work/unset"
in_volumes 'sqlite3 /wiki/data/database.sqlite ".backup /tmp/unset.sqlite" && cat /tmp/unset.sqlite' \
  > "$work/unset/database.sqlite"
tar czf "$work/unset.tar.gz" -C "$work/unset" .

echo "--- Finish first-run setup through the setup endpoint"
setup=$(jq -n --arg email "$email" --arg password "$password" \
  '{adminEmail: $email, adminPassword: $password, adminPasswordConfirm: $password, siteUrl: "https://wiki.test", telemetry: false}')
[[ $(request POST /finalize "$setup") == '200 {"ok":true'* ]] || fail "setup did not finish"
wait_for '{"ok":true}'

echo "--- Create a page through the GraphQL API"
old_token=$(sign_in)
[ -n "$old_token" ] || fail "could not sign in after setup"
created=$(gql "mutation { pages { create(content: \"$content\", description: \"\", editor: \"markdown\", isPublished: true, isPrivate: false, locale: \"en\", path: \"round-trip\", tags: [], title: \"$title\") { responseResult { succeeded message } } } }" "$old_token")
[ "$(jq -r .data.pages.create.responseResult.succeeded <<<"$created")" = true ] || fail "could not create the page: $created"
expected_page=$(jq -cn --arg title "$title" --arg content "$content" '{title: $title, content: $content}')
check_data "before the backup"

# A file in content/, which the backup keeps; and files in the cache, an admin-area export and the
# Local File System target's folder, which it leaves out.
in_volumes 'echo kept > /wiki/data/content/round-trip.txt && chown -R 1000:1000 /wiki/data/content &&
  echo stale > /wiki/data/cache/round-trip.bin && mkdir -p /wiki/data/export-1 &&
  echo copy > /wiki/data/export-1/round-trip.md && echo copy > /wiki/backups/round-trip.md'

echo "--- Back up"
out=$work/out
mkdir "$out"
# Called from elsewhere with a relative folder, as a person might.
(cd "$work" && bash "$app/backup.sh" out)
files=("$out"/*)
if [ "${#files[@]}" -ne 1 ] || [ ! -f "${files[0]}" ]; then
  fail "backup.sh must write exactly one file, wrote: ${files[*]}"
fi
backup=${files[0]}
[ "$(basename "$backup")" = wiki.tar.gz ] || fail "the backup is $(basename "$backup"), not wiki.tar.gz"
# The runner (and the deploy user) must be able to read and delete what the recipe wrote.
[ -O "$backup" ] || fail "the backup is not owned by the user who ran backup.sh"
# It holds password hashes and the sign-in keys, so nobody else may read it.
[ "$(stat -c %a "$backup")" = 600 ] || fail "the backup's mode is $(stat -c %a "$backup"), not 600"
members=$(tar tzf "$backup" | sed 's|^\./||; s|/$||' | grep -v '^$' | sort)
[ "$members" = "$(printf '%s\n' content content/round-trip.txt database.sqlite)" ] \
  || fail "the backup should hold database.sqlite and content/ only, but holds: $(echo "$members" | tr '\n' ' ')"

echo "--- A file with no database is refused, and the wiki keeps running"
bad=$work/bad.tar.gz
tar czf "$bad" -C "$work" test-network.yml
if bash restore.sh "$bad"; then fail "restore.sh accepted a file with no database"; fi
running || fail "a refused restore stopped the wiki"
no_leftovers "after a refused restore"

echo "--- A database that isn't the wiki's is refused, and the wiki keeps running"
mkdir "$work/other"
in_volumes 'sqlite3 /tmp/other.sqlite "CREATE TABLE t (x); INSERT INTO t VALUES (1);" && cat /tmp/other.sqlite' \
  > "$work/other/database.sqlite"
tar czf "$work/other.tar.gz" -C "$work/other" .
if bash restore.sh "$work/other.tar.gz"; then fail "restore.sh accepted a database with no pages table"; fi
running || fail "a refused restore stopped the wiki"
no_leftovers "after a refused restore"

echo "--- A restore the wiki starts its setup page from is undone"
# The database of a wiki never set up passes the archive check, but holds no settings.
if bash restore.sh "$work/unset.tar.gz"; then fail "restore.sh accepted a wiki that started its setup page"; fi
wait_for '{"ok":true}'
check_data "after an undone restore"
no_leftovers "after an undone restore"

echo "--- A restore the wiki keeps crashing on is undone"
# A database with only an empty pages table passes the archive check, and the wiki's first
# migration fails on it, so the wiki exits and Docker restarts it.
mkdir "$work/broken"
in_volumes 'sqlite3 /tmp/broken.sqlite "CREATE TABLE pages (id INTEGER);" && cat /tmp/broken.sqlite' \
  > "$work/broken/database.sqlite"
tar czf "$work/broken.tar.gz" -C "$work/broken" .
if bash restore.sh "$work/broken.tar.gz"; then fail "restore.sh accepted a wiki that keeps restarting"; fi
wait_for '{"ok":true}'
check_data "after an undone restore"
no_leftovers "after an undone restore"

echo "--- An interrupted restore is refused until --undo puts the earlier data back"
# What an interruption after the swap leaves: the data set aside, the archive's moved in.
docker compose stop wiki
in_volumes 'cd /wiki/data && mkdir .restore-old &&
  find . -mindepth 1 -maxdepth 1 ! -name ".restore-*" ! -name content -exec mv {} .restore-old/ \; &&
  touch .restore-old/.complete .from-the-archive'
if bash restore.sh "$backup"; then fail "restore.sh ran over an interrupted restore"; fi
bash restore.sh --undo
wait_for '{"ok":true}'
check_data "after --undo"
no_leftovers "after --undo"
[ -z "$(in_volumes 'ls -A /wiki/data | grep -x .from-the-archive || true')" ] \
  || fail "--undo kept a file the interrupted restore had moved in"
[[ $(bash restore.sh --undo) == "Nothing to undo"* ]] || fail "a second --undo did not say there was nothing to undo"
running || fail "--undo with nothing to undo stopped the wiki"

echo "--- Wipe the wiki and its volumes"
docker compose down -v
for volume in db-data content backups; do
  docker volume inspect "${project}_$volume" >/dev/null 2>&1 && fail "the $volume volume was not removed"
done
docker compose up -d
wait_for '<!DOCTYPE html>'

echo "--- Restore"
bash restore.sh "$backup"

echo "--- Check the data came back"
wait_for '{"ok":true}'
check_data "after the restore"
no_leftovers "after the restore"
[ "$(in_volumes 'cat /wiki/data/content/round-trip.txt')" = kept ] || fail "content/ did not come back"
[ -z "$(in_volumes 'ls -A /wiki/data | grep -x export-1 || true; ls -A /wiki/data/cache | grep -x round-trip.bin || true')" ] \
  || fail "the cache or an export came back, though the backup leaves them out"
[ "$(in_volumes 'stat -c %u:%g /wiki/backups')" = 1000:1000 ] \
  || fail "the storage target's folder is not the wiki's to write to"

echo "--- Restore a bare SQLite copy, as ticket 23 took it off the old server"
copy=$work/wiki-20261021.sqlite
in_volumes 'sqlite3 /wiki/data/database.sqlite ".backup /tmp/copy.sqlite" && cat /tmp/copy.sqlite' > "$copy"
docker compose down -v
docker compose up -d
wait_for '<!DOCTYPE html>'
bash restore.sh "$copy"
wait_for '{"ok":true}'
check_data "after restoring a bare SQLite copy"
no_leftovers "after restoring a bare SQLite copy"

echo "PASS: the page, the admin's sign-in and the session keys survived backup and restore"
