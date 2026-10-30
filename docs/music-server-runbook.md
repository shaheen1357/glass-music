# Music Server Runbook

Everything you need to run the Navidrome music server and keep the Glass app in
step with it — get in, upload music, make it show up, how playlists move between
phone and server, the folder-to-playlist feeder, backups. Keep this file.

*Updated 2026-10-30: two-way playlist sync, folder → playlist links, the old
`gen_playlists.sh` retired.*

---

## What you have

- A free **Oracle** Linux VM at **`140.245.229.48`** (user `ubuntu`), reachable
  on the domain **`glassstream.duckdns.org`**.
- **Navidrome 0.64** runs there in **Docker**, serving your music over HTTPS.
- Your music lives on the server at **`~/navidrome/music`**
  (full path `/home/ubuntu/navidrome/music`), one folder per album/playlist.
- **Caddy** sits in front and gives it a real HTTPS certificate, so the app and
  the browser reach `https://glassstream.duckdns.org` with a padlock.
- **folderlinks** — a small script at `~/navidrome/folderlinks/` that feeds new
  songs dropped into a folder to the playlist linked to that folder (§4).
- The master copy of your music is the **`Flac` folder on the laptop/PC**. The
  server is a copy, not a backup — keep the master somewhere safe.

## Two things to never lose

1. **The SSH key** — `~/Downloads/ssh-key-2026-10-27 (1).key` on the laptop. It
   is the *only* way into the server. Back it up. There is no password login.
2. **A master copy of the music** off the server. The free VM can be reclaimed
   and has no backup; don't let the server be your only copy.

---

## The golden rules (the short version of everything)

- The `Flac` folder on the laptop/PC is the **master**. The server is a copy and
  a stream source, **not a backup** — a free VM can vanish. Keep the master.
- **Never delete a song's only copy.** The phone can't upload to the server, so a
  phone-only song that isn't in your `Flac` master and isn't on the server is
  gone once deleted. Upload first, delete after.
- **Playlists are shared, and both sides are the master.** Edit on the phone or in
  Navidrome's web UI — adds *and* removals on either side survive and meet in the
  middle. Neither side overwrites the other.
- **Deleting a whole playlist does not sync yet.** Delete it on the server first,
  then on the phone (§10). Done the other way round, it comes back.
- **Folders feed playlists only with new arrivals.** A song dropped into a linked
  folder is appended to its playlist once. Remove it from the playlist and it
  stays removed. Nothing is a "smart" playlist.
- **Liked songs is your favourites**, kept by hand. Nothing feeds it automatically.
- A song shows **once** whether it's local, on the server, or both; it plays from
  the local file if present, otherwise it streams.

---

## 1. Get into the server (SSH)

```bash
ssh -i "/home/shehin/Downloads/ssh-key-2026-10-27 (1).key" ubuntu@140.245.229.48
```

- `ssh` — open a secure shell on the remote machine.
- `-i "<path>"` — the identity file (your private key). The quotes matter: the
  filename has a space and brackets.
- `ubuntu@140.245.229.48` — log in as user `ubuntu` on that IP.

If it refuses with "permissions too open", lock the key down once, then retry:

```bash
chmod 600 "/home/shehin/Downloads/ssh-key-2026-10-27 (1).key"
```

Type `exit` to leave the server and return to the laptop.

---

## 2. Upload / sync music to the server (rsync)

Run this **on the laptop** (not inside an SSH session). It copies new/changed
files up and skips ones already there.

```bash
rsync -av --progress --exclude='.Trash*' \
  -e 'ssh -i "/home/shehin/Downloads/ssh-key-2026-10-27 (1).key"' \
  "/home/shehin/Music/Flac/" \
  ubuntu@140.245.229.48:~/navidrome/music/
```

What each piece means:

- `rsync` — smart copy; only sends what's missing or changed, resumes if cut off.
- `-a` — *archive*: recurse into folders and preserve structure/timestamps.
- `-v` — *verbose*: print what it's doing.
- `--progress` — show a progress bar per file.
- `--exclude='.Trash*'` — skip trash folders.
- `-e 'ssh -i "<key>"'` — use SSH with your key for the transfer.
- `"/home/shehin/Music/Flac/"` — the **source** on the laptop. The **trailing
  slash matters**: with it, the *contents* of `Flac/` go into the destination;
  without it, the `Flac` folder itself would be nested inside.
- `ubuntu@...:~/navidrome/music/` — the **destination** on the server.

Note: don't add `-z` (compression) — FLAC is already compressed, so it only
wastes CPU. Don't add `--delete` either: it would remove server files that
aren't in the laptop's folder.

To copy just one folder, point the source at it, e.g.
`"/home/shehin/Music/Flac/hope/"` → `...:~/navidrome/music/hope/`.

**Folder names are identities.** The feeder (§4) knows a folder by its exact
name, spaces included (`transcend ` really has a trailing space). Renaming a
folder on the server makes it look like a brand-new folder, which gets its own
new playlist. Moving or renaming a *file* makes it a new song to Navidrome.

---

## 3. Make Navidrome see the new music

Navidrome **watches** the music folder and picks up new files about 5 seconds
after they land. On top of that it does a full scan **every hour** as a backstop.
Usually you do nothing.

If something doesn't appear, force a rescan by restarting it. SSH in first, then:

```bash
cd ~/navidrome && docker compose restart navidrome
```

- `cd ~/navidrome` — go to the folder holding `docker-compose.yml`.
- `docker compose restart navidrome` — restart the container; it rescans the
  music folder on startup.

Watch what it did:

```bash
docker logs navidrome 2>&1 | grep -iE "scan|added|error" | tail -30
```

- `docker logs navidrome` — print the container's log.
- `2>&1` — include error output.
- `grep -iE "..."` — keep only lines mentioning scan/added/error (`-i` ignore
  case, `-E` extended patterns).
- `tail -30` — last 30 matching lines.

---

## 4. Folder → playlist links (folderlinks)

The feeder lives in `~/navidrome/folderlinks/` on the server and runs every
15 minutes. Each run it:

- reads Navidrome's database (read-only) to see which folder every song is in;
- for each **linked** folder, appends songs it has **never seen before** to that
  folder's playlist, and remembers them as seen;
- for a **brand-new folder**, creates a playlist named after it with every song
  in it (or, if a playlist of that exact name already exists, adopts that one and
  adds only what it lacks), then links the two;
- for a folder linked to **nothing**, notes new songs as seen and adds them
  nowhere;
- skips a song that's already in the playlist (you added it on the phone first),
  so nothing is ever doubled;
- if a linked playlist was **deleted**, unlinks the folder instead of
  recreating the playlist.

All writes go through Navidrome's API, so the playlist is stamped as changed and
the phone picks up the addition on its next open (§5).

The files:

- `folderlinks.py` — the script.
- `state.json` — its memory: each folder, the playlist it feeds, every song it
  has seen. **Back this up with the database** (§7).
- `.env` — the Navidrome login it writes with (`ND_USER=`, `ND_PASS=`), readable
  by you only.
- `run.log` — what each run did.

### The links as agreed (2026-10-30)

Every folder feeds the playlist of the same name, except:

| Folder | Feeds |
|---|---|
| `aot` | `attack on titan` |
| `#ipod_originals` | `ipod originals` |
| `dream_core` | `dream_core#1` |
| `memory reboot` | `memory_reboot` |
| `original classics` | `original_classics#1` |
| `original volume #5` / `7` / `8` | `original_volume#5` / `#7` / `#8` |
| `original_#phonk2` | `original_phonk#2` |
| `tokyo ghoul` | `tokyo_ghoul` |
| `transcend ` (trailing space) | `transcend` |
| `vlc`, `gen`, `liminal`, `mellow` | **nothing** — their songs went into other lists by hand |

`over drive` is fed by no folder; it's a hand-made mix.

### Everyday commands (SSH in, then `cd ~/navidrome/folderlinks`)

See every folder and what it feeds:

```bash
python3 folderlinks.py --list
```

See what the next run would do, without doing it:

```bash
python3 folderlinks.py --dry-run
```

Run it now instead of waiting for the quarter hour:

```bash
python3 folderlinks.py
```

Point a folder at an existing playlist, or at nothing (quote names with spaces):

```bash
python3 folderlinks.py --link "vlc" "south"
python3 folderlinks.py --unlink "vlc"
```

Changing a link never moves songs by itself — only songs that arrive afterwards
follow the new link.

What it has done lately:

```bash
tail -30 run.log
```

**To stop a new folder becoming a playlist**, link it before the next run:
upload the folder, then straight away `--unlink "<folder>"` (it has to be on the
server for the command to accept it). Or let it be created and delete the
playlist on the server — the feeder unlinks and never brings it back.

### One-time setup (only if `--list` works but nothing ever runs)

The feeder needs the Navidrome login that owns your playlists (`nik1357f`) and
a cron entry. On the server:

```bash
cd ~/navidrome/folderlinks
read -rsp 'Navidrome password: ' P; echo
(umask 077; printf 'ND_USER=nik1357f\nND_PASS=%s\n' "$P" > .env); unset P
python3 folderlinks.py && echo "auth ok"
(crontab -l 2>/dev/null; echo '*/15 * * * * cd $HOME/navidrome/folderlinks && python3 folderlinks.py >> run.log 2>&1') | crontab -
```

Check the cron entry with `crontab -l`. If you change the Navidrome password,
rewrite `.env` the same way.

### Retired: `~/gen_playlists.sh`

The old script wrote a `.m3u8` file into every folder. Don't run it. Navidrome no
longer imports playlist files (`ND_AUTOIMPORTPLAYLISTS: "false"`), so they'd only
be clutter in the music folders. Safe to delete: `rm ~/gen_playlists.sh`.

---

## 5. How the phone and the server stay in step (Glass)

Syncing happens on Wi-Fi (or on mobile data, if you allowed it in Settings).

**First open after installing Glass** — a full sync, once: the whole song list
(a few requests, about 500 songs each), every playlist, your likes. On an empty
phone the server's playlists are taken as they are. Cover art fills in afterwards
in the background.

**Every open, and every return to the app** — cheap checks:

- *Has the server's song count changed?* If yes, Glass compares the server's whole
  song list with what it holds: new songs are added, songs deleted from the
  server are dropped (a local copy on the phone stays). This is what makes a song
  added to an *existing* folder show up in Search.
- *Is there a playlist on the server the phone doesn't have?* It's brought down.
- *Has a playlist been changed on the server* (web UI edit, or the folder
  feeder)? Glass merges just that playlist: adds and removals from both sides are
  kept.
- *Has the phone changed anything?* It's pushed up.

**Leaving the app** — the phone's edits are pushed up. Any playlist that changed
on the server in the meantime is merged first, so a web-UI edit can't be
overwritten.

**Pull down on Home** — forces a full sync, including likes from the server.

**Likes** — liking on the phone stars the song on the server straight away (and
retries later if you were offline). A star added in the web UI reaches the phone
on a full sync (pull down on Home).

**Search** (the Search tab) looks through the phone's songs and the server's
songs together. The phone's own songs are listed first, then server-only ones.
A song you hold on both appears once.

**Songs that exist only on the phone** stay in the phone's playlist but can't be
added to the server's copy. If a playlist holds a song the server has under the
same title but Glass couldn't tell which file it is, that playlist isn't pushed
and Settings says *"Not synced — songs didn't match the server: …"*.

---

## 6. Check on things

How many music files are actually on the server:

```bash
find ~/navidrome/music -type f \( -iname '*.flac' -o -iname '*.mp3' \) | wc -l
```

- `find ... -iname '*.flac'` — list every FLAC (and MP3) under the music folder.
- `wc -l` — count the lines (i.e., the files).

How many tracks Navidrome has indexed — open `https://glassstream.duckdns.org`
in a browser (the Songs count), or read it from the log line that mentions
`"tracks":`.

Folders and their playlists: `python3 ~/navidrome/folderlinks/folderlinks.py --list`.

Free disk space on the server:

```bash
df -h /
```

Is Navidrome running:

```bash
docker ps
```

---

## 7. Back up the Navidrome database

The database holds playlists, likes and play counts; the feeder's `state.json`
holds which songs it has already handed out. Snapshot both before any big change.
On the server:

```bash
STAMP=$(date +%F-%H%M)
sudo cp ~/navidrome/data/navidrome.db ~/navidrome/data/navidrome.db.bak-$STAMP
cp ~/navidrome/folderlinks/state.json ~/navidrome/folderlinks/state.json.bak-$STAMP
```

- `sudo` — needed because the database file is owned by root.
- `cp <src> <dst>` — copy; `$STAMP` stamps both backups with the same date and
  time so they belong together.

List your backups:

```bash
ls -la ~/navidrome/data/*.bak-* ~/navidrome/folderlinks/*.bak-*
```

To roll back: stop Navidrome, copy a backup over the live DB (and the matching
`state.json`), start it:

```bash
cd ~/navidrome && docker compose stop navidrome
sudo cp ~/navidrome/data/navidrome.db.bak-YYYY-MM-DD-HHMM ~/navidrome/data/navidrome.db
cp ~/navidrome/folderlinks/state.json.bak-YYYY-MM-DD-HHMM ~/navidrome/folderlinks/state.json
docker compose start navidrome
```

After a rollback the phone may still hold newer playlist edits; it will push
them up again on its next open.

---

## 8. Reference — the plumbing (already set up; here if it breaks)

**Navidrome itself** is a Docker container defined in
`~/navidrome/docker-compose.yml`. This whole file *is* the server — if you ever
rebuild the box, recreate it and you're back:

```yaml
services:
  navidrome:
    image: deluan/navidrome:latest
    container_name: navidrome
    restart: unless-stopped
    ports:
      - "4533:4533"
    environment:
      ND_SCANNER_SCHEDULE: 1h
      ND_SESSIONTIMEOUT: 24h
      ND_LOGLEVEL: info
      ND_AUTOIMPORTPLAYLISTS: "false"
      ND_SUBSONIC_DEFAULTREPORTREALPATH: "true"
    volumes:
      - "./data:/data"
      - "./music:/music:ro"
```

Run it from `~/navidrome` with `docker compose up -d`. What the settings do:

- `ND_SCANNER_SCHEDULE: 1h` — the hourly backstop scan. (The older name
  `ND_SCANSCHEDULE` is ignored by 0.64 — it silently disabled the hourly scan
  until 2026-10-30.)
- `ND_AUTOIMPORTPLAYLISTS: "false"` — playlist files (`.m3u`, `.m3u8`) found in the
  music folders are **not** turned into playlists. Playlists live only in the
  database, edited from the phone, the web UI or the feeder.
- `ND_SUBSONIC_DEFAULTREPORTREALPATH: "true"` — the API reports each song's real
  path (`/music/aot/…flac`). Glass uses the file name to tell apart songs whose
  tags are identical (`FREAKED OUT` vs `FREAKED OUT 2`); without this,
  playlists can point at the wrong copy.
- `./music:/music:ro` — the music is read-only to Navidrome; it can never change
  your files.
- `./data` — the database and settings. That's the folder to back up (§7).

Rebuilding the box also means restoring `~/navidrome/folderlinks/` (script,
`state.json`, `.env`) and the cron entry from §4.

**Ports open** to the internet: `80`, `443`, `4533`. These live in two places,
and both must be open: the Oracle **console** (VCN → subnet → Security List →
ingress rules) and the box's own firewall. The box firewall rules must sit
*above* the `REJECT` line — check with `sudo iptables -S INPUT`.
`4533` is Navidrome **without HTTPS** — logins over it are not encrypted. The app
and browser use `https://glassstream.duckdns.org` (443), so 4533 can be closed
in both places whenever you like; the feeder talks to Navidrome inside the box
and doesn't need it open.

**HTTPS** is Caddy, config at `/etc/caddy/Caddyfile`:

```
glassstream.duckdns.org {
    reverse_proxy localhost:4533
}
```

Restart it with `sudo systemctl restart caddy`; check it with
`sudo journalctl -u caddy --no-pager -n 20`. The certificate renews itself.

**DuckDNS** maps `glassstream.duckdns.org` → `140.245.229.48`. If the server's
IP ever changes (e.g., the instance is recreated), log in at duckdns.org and
update the IP, or the domain stops resolving.

---

## 9. Cheat sheet — "I downloaded new music, now what?"

**A new album/folder:** put it in the laptop's `Flac` folder and rsync up (§2).
That's all. Within about 15 minutes the feeder creates a playlist named after the
folder; open Glass and it's there, songs and all. Rename or trim it from either
side.

**A song for a folder that already exists** (say a missing track for `aot`):
put it in that folder in `Flac`, rsync up. Within about 15 minutes it's appended
to the folder's playlist (`attack on titan`); open Glass and it's in Search and in
the playlist. If the folder feeds nothing (`vlc`, `gen`, `liminal`, `mellow`) it
shows in Search only — add it to a playlist yourself.

**A song for a playlist that isn't tied to a folder** (`over drive`, Liked): upload
it to any folder, then add it to the playlist on the phone or in the web UI.

Upload command (on the laptop):

```bash
rsync -av --progress --exclude='.Trash*' \
  -e 'ssh -i "/home/shehin/Downloads/ssh-key-2026-10-27 (1).key"' \
  "/home/shehin/Music/Flac/" ubuntu@140.245.229.48:~/navidrome/music/
```

---

## 10. Scenarios — what's safe, what to do

**You have local files not yet on the server.**
They exist in one place only, so don't delete them yet. Put them in the `Flac`
folder, rsync up (§2) — now there's a second copy on the server, and only then is
it safe to delete the local one. Your data is fine as long as it's in the `Flac`
master or on the server; the only danger is deleting the last copy before it's
uploaded.

**You have music on the server not yet on the phone/laptop.**
Nothing to worry about — it's on the server. The phone sees it on its next open
and can stream it, add it to a playlist, or download it for offline. If you want
a local master of server-only songs, pull them *down* (same rsync, ends swapped —
server → laptop):

```bash
rsync -av --progress \
  -e 'ssh -i "/home/shehin/Downloads/ssh-key-2026-10-27 (1).key"' \
  ubuntu@140.245.229.48:~/navidrome/music/ "/home/shehin/Music/Flac/"
```

**The same song is on both the phone and the server.**
It's deduped: one entry, plays from the local file. Deleting the local copy is
safe — the entry resolves to the server copy and streams. Nothing to do.

**You edited a playlist in the web UI.**
Fine. The phone merges it on its next open and keeps its own edits too.

**You removed a song the feeder added.**
It stays removed. The feeder only ever hands out a song once.

**You want to delete a whole playlist.**
Deletion doesn't sync yet, so the order matters. Delete it in the **web UI
first**, then on the **phone** straight after, before changing anything else in
Glass. (Phone first: the server's copy comes back on the
next open. Server only: the phone pushes it back up.) If the playlist was fed by
a folder, the feeder unlinks it on its own.

**A playlist looks short after you deleted local files.**
If those songs are on the server, they come back as server copies (the app
recorded their identity when you added them). If they were only ever local and
deleted without uploading — that is the one case that's gone. Upload before
deleting, always.

**Fresh phone, or you reinstalled the app.**
The first open does one full sync. On an empty phone it restores your playlists
from the server. Because playlists now live on the server too, a reinstall is no
longer risky for them — but songs that exist **only** on the phone still go with
the app, so upload those first. Sideloading a new build *over the top* (an
update) keeps everything and skips the full sync.

**A new song from Telegram you want to keep.**
Download it on the phone, add it to a playlist (its identity is recorded then),
upload the same file to the server (§2), and only then delete the local copy. The
playlist then streams it from the server. Put it in a folder that feeds the same
playlist, or one that feeds nothing — the feeder skips songs already in the
playlist, so it won't be doubled either way.

**You want to rename a folder on the server.**
Better not. The feeder would see a brand-new folder and make a new playlist for
it, and how Navidrome treats the moved songs already in your playlists hasn't
been tested here. If it has happened: back up first (§7), delete the new playlist
(web UI, then phone), `--link` the new folder name to the old playlist (§4), and
check the old playlist still plays.

---

## 11. Maintenance (every so often)

- Keep the `Flac` master safe — a second copy on the PC or an external drive. One
  copy on a free VM is not a backup.
- Back up the Navidrome database **and** `state.json` (§7) before any big change,
  and now and then regardless.
- Glance at the feeder's log: `tail -30 ~/navidrome/folderlinks/run.log`. Errors
  there usually mean the password in `.env` changed.
- Watch server disk with `df -h /` on the server, especially after big uploads.
- If the server's IP ever changes (the instance is recreated), update it at
  duckdns.org or the domain stops resolving (§8).
- The phone's play-cache trims itself at ~2 GB; pinned downloads are uncapped —
  clear either from Settings if space runs short.
