# wiki

The Indy Center Wiki at [wiki.flyindycenter.com](https://wiki.flyindycenter.com): the official [Wiki.js](https://js.wiki/) 2 image, run on ALEXANDRIA behind its Traefik, with the wiki's data in Docker volumes and backed up nightly.

[![Build and Deploy](https://github.com/Indy-Center/wiki/actions/workflows/build-and-deploy.yml/badge.svg)](https://github.com/Indy-Center/wiki/actions/workflows/build-and-deploy.yml)

Pages, uploaded files, users, groups, sign-in settings (OAuth2, with its client secret) and the wiki's own sign-in keys all live in its SQLite database. Editors change the wiki in the wiki itself, not here: this repository holds only how it runs.

## Project layout

- `deploy/`: everything deployed to `/home/deploy/apps/wiki/` on the server, and nothing else.
  - `docker-compose.yml`: the wiki, its three volumes and its Traefik route. Also `data-tools`, which never runs on its own: the backup scripts start it as a throwaway container, from the wiki's own image (which has `sqlite3`) with no network, to read and write the volumes.
  - `backup.sh` and `restore.sh`: the backup recipe and its reverse (see [Backups](#backups)).
  - `.env.example`: the runtime settings the deploy writes to `.env`. None yet.
- `tests/backup-round-trip.sh`: proves a backup restores as the same wiki. CI runs it.
- `.github/workflows/ci.yml`: shellcheck, checks the compose file, pulls the image, then runs the backup round trip.
- `.github/workflows/build-and-deploy.yml`: runs CI, then rsyncs `deploy/` to the server and runs `docker compose up -d` over SSH.

## Data

| Volume | Mounted at | Holds | Backed up |
| ------ | ---------- | ----- | --------- |
| `wiki_db-data` | `/wiki/data` | `database.sqlite`, plus `cache/` and `uploads/`, which Wiki.js rebuilds or empties itself, and any exports made from Admin → Utilities (`export`, `export-1`, …), which are copies of the database | the database only |
| `wiki_content` | `/wiki/data/content` | Nothing Wiki.js 2 uses today; the image declares the folder a volume, so it is named here rather than left as an unnamed one | yes |
| `wiki_backups` | `/wiki/backups` | The copy of the pages the Local File System storage target (Admin → Storage) writes | no: it is rebuilt from the database |

The volumes are named after the repository. Renaming the repository starts the wiki on new, empty volumes. None of the data is in this repository, and the repository is public, so none of it ever should be.

## Backups

The wiki is backed up nightly by the server's backup runner, which encrypts each backup and stores it off the box. [docker-infrastructure](https://github.com/Indy-Center/docker-infrastructure#backups) owns the runner and the schedule. This repository ships the two scripts the runner's contract asks for.

`deploy/backup.sh <folder>` writes one archive, `wiki.tar.gz`, into the folder, holding `database.sqlite` and `content/`. The wiki keeps running. The script copies the database with SQLite's online backup, which gets it as it stands while the wiki writes, and checks the copy passes SQLite's integrity check. The archive is unencrypted until the runner encrypts it, and holds password hashes and the sign-in keys, so it is readable only by whoever ran the script.

`deploy/restore.sh <file>` puts a decrypted archive back, replacing the wiki's data. It also takes a bare copy of the database (a `.sqlite` file, as SQLite's `.backup` writes it). In order, it:

1. with the wiki still running, unpacks the file into the volumes and checks its database passes the integrity check and has a `pages` table, and prints how many pages it holds. A bad file stops here and changes nothing;
2. stops the wiki, moves its data aside into `.restore-old` (in `/wiki/data` and in `/wiki/data/content`), moves the new data in, and gives it to the wiki's user. Everything in `/wiki/data` is replaced, the cache and old exports included;
3. starts the wiki and waits until `/healthz` answers `{"ok":true}`. A wiki that finds no settings in its database shows its setup page instead, so that means the restore failed;
4. deletes the data it moved aside.

If anything fails or is interrupted after the wiki stops, `restore.sh` puts the earlier data back and starts the wiki on it, and says so. If even that fails, the earlier data stays in the volumes in `.restore-old`, and a later `restore.sh` refuses to run until `bash restore.sh --undo` has put it back.

The wiki is down for the minute or so it restarts.

### Recover

A Recover one app runbook is coming to tech.flyindycenter.com; until then, see [Backups in docker-infrastructure](https://github.com/Indy-Center/docker-infrastructure#backups). In short, on the server as `deploy`, `backups list wiki` shows the backups and `backups restore wiki <backup>` fetches, decrypts and restores one. To keep what is there now as well, run `backups now wiki` first.

To run the scripts by hand instead, as `deploy`, keep the file under `/home/deploy` and out of `~/backups/wiki/`, which the runner empties on every backup:

```bash
cd ~/apps/wiki
mkdir -p -m 700 ~/wiki-before-restore
bash backup.sh ~/wiki-before-restore   # a copy of what is there now, in case
bash restore.sh /path/to/wiki.tar.gz
```

Delete `~/wiki-before-restore` once the restored wiki is checked: it holds the password hashes and sign-in keys unencrypted.

**From a bare database copy**, such as the one taken off the old server (`wiki-20261021.sqlite`): copy it where `deploy` can read it, restore it, then delete it. With your own login on the server:

```bash
sudo install -o deploy -g deploy -m 600 ~/wiki-20261021.sqlite /home/deploy/
sudo -iu deploy bash -c 'cd ~/apps/wiki && bash restore.sh ~/wiki-20261021.sqlite && rm ~/wiki-20261021.sqlite'
rm ~/wiki-20261021.sqlite
```

`restore.sh` prints the copy's page count before it stops anything, and `Restored wiki-20261021.sqlite` once the wiki answers on it.

CI proves the round trip on every pull request (`tests/backup-round-trip.sh`): it starts Wiki.js on empty volumes, finishes first-run setup through its setup endpoint, creates a page through the GraphQL API, backs up, deletes the volumes, restores, and checks the page, the admin's sign-in and a session token from before the backup all work again. It also restores a bare database copy, and checks that a refused restore, one the wiki can't start on, and an interrupted one each leave the wiki on its earlier data. To run it yourself, with Docker (the image is multi-arch, so a Raspberry Pi will do; it publishes no ports):

```bash
bash tests/backup-round-trip.sh
```

## Local development

There is nothing to build. To look at a throwaway wiki in a browser, at `http://localhost:3000`:

```bash
docker run --rm -p 127.0.0.1:3000:3000 -e DB_TYPE=sqlite -e DB_FILEPATH=/wiki/data/database.sqlite ghcr.io/requarks/wiki:2.5.305
```

It starts on the setup page, and its data goes when it stops.

## Deployment

`build-and-deploy.yml` runs on every push to `main`, and by hand from **Actions → Build and Deploy → Run workflow**. It calls `ci.yml` first and only deploys if it passes, then checks the container is still up 15 seconds later. [Deploying to the VPS](https://tech.flyindycenter.com/patterns/vps-apps/) describes the pipeline.

The deploy uses the organization's `ALEXANDRIA_*` variables and secrets (`SERVER: ALEXANDRIA` at the top of the workflow). An org admin adds this repository to all four before the first deploy.

On empty volumes, as on its first deploy, Wiki.js shows its setup page to whoever opens it first, and the first to finish it becomes the admin. So the first deploy is followed straight away by a restore, before the hostname points at the server.

The image is pinned to Wiki.js 2.5.305 by tag and digest, so a deploy never upgrades it by surprise. Wiki.js migrates its database on start and can't go back, and its next major version drops SQLite, so never move it to `latest` or `3`. Upgrading is a change to the image line: the tag and its digest together, after `backups now wiki` on the server, as `deploy`.

A deploy that changes `deploy/docker-compose.yml` recreates the container, so the wiki is down for the minute it takes to start.

## Disclaimer

This project is not affiliated with the Federal Aviation Administration or any governing aviation body. All content is approved only for use on the VATSIM network.
