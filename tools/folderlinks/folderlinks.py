#!/usr/bin/env python3
"""Feed new songs in a music folder to the playlist linked to that folder.

Not a smart playlist: every playlist stays an ordinary, editable one. The script
remembers each song it has seen per folder and only ever APPENDS songs that are new
to the folder since its last run, so a song you remove from a playlist (on the phone
or in the web UI) stays removed. A folder that appears for the first time gets a new
playlist named after it. A folder linked to nothing (null) is watched but never fed.

Reads Navidrome's database read-only to see which folder each song lives in; all
writes go through the Subsonic API so Navidrome stamps the playlist as changed and
Glass merges the addition on its next open.

State: state.json next to this file. Credentials: .env next to this file
(ND_USER=..., ND_PASS=...), mode 600.

  folderlinks.py --init       seed state from the current library (changes nothing on the server)
  folderlinks.py --dry-run    print what a run would do, write nothing
  folderlinks.py              run
  folderlinks.py --link FOLDER PLAYLIST   point a folder at an existing playlist
  folderlinks.py --unlink FOLDER          stop a folder feeding anything
  folderlinks.py --list                   show every folder and what it feeds

Changing a link never adds songs by itself: only songs that arrive afterwards move.
"""
import hashlib, json, os, secrets, sqlite3, sys, time, urllib.parse, urllib.request
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, "state.json")
DB = os.path.join(HERE, "..", "data", "navidrome.db")
BASE = "http://127.0.0.1:4533/rest"

# Folder -> playlist name, as agreed on 2026-10-30. Folders whose songs other playlists
# absorbed by hand (vlc -> south / favourites, gen, liminal, mellow) feed nothing.
# 'transcend ' carries the trailing space the folder really has.
INITIAL_LINKS = {
    "#ipod_originals": "ipod originals",
    "aot": "attack on titan",
    "cs01_vibes": "cs01_vibes",
    "dream": "dream",
    "dream 3": "dream 3",
    "dream soda": "dream soda",
    "dream_2": "dream_2",
    "dream_core": "dream_core#1",
    "hindi": "hindi",
    "hope": "hope",
    "hope_2": "hope_2",
    "jujutsu kaisen": "jujutsu kaisen",
    "liminal spaces": "liminal spaces",
    "memory reboot": "memory_reboot",
    "original classics": "original_classics#1",
    "original volume #5": "original_volume#5",
    "original volume 7": "original_volume#7",
    "original volume 8": "original_volume#8",
    "original_#phonk2": "original_phonk#2",
    "south": "south",
    "tokyo ghoul": "tokyo_ghoul",
    "transcend ": "transcend",
    "vlc": None,
    "gen": None,
    "liminal": None,
    "mellow": None,
}


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def library():
    """{folder: [(song_id, path)]} for every present song, ordered by path."""
    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=30)
    rows = db.execute("select id, path from media_file where missing = 0 order by path").fetchall()
    playlists = dict(db.execute("select name, id from playlist").fetchall())
    members = defaultdict(set)
    for pid, sid in db.execute("select playlist_id, media_file_id from playlist_tracks"):
        members[pid].add(sid)
    db.close()
    folders = defaultdict(list)
    for sid, path in rows:
        parts = path.strip("/").split("/")
        if len(parts) < 2:                 # a file at the library root has no folder
            continue
        folders[parts[0]].append((sid, path))
    return folders, playlists, members


class Api:
    def __init__(self):
        env = {}
        with open(os.path.join(HERE, ".env")) as f:
            for line in f:
                if "=" in line and not line.lstrip().startswith("#"):
                    k, v = line.rstrip("\n").split("=", 1)
                    env[k.strip()] = v
        self.user, self.password = env["ND_USER"], env["ND_PASS"]

    def call(self, method, params):
        salt = secrets.token_hex(6)
        token = hashlib.md5((self.password + salt).encode()).hexdigest()
        q = [("u", self.user), ("t", token), ("s", salt), ("v", "1.16.1"),
             ("c", "folderlinks"), ("f", "json")] + params
        url = f"{BASE}/{method}?{urllib.parse.urlencode(q)}"
        with urllib.request.urlopen(url, timeout=60) as r:
            body = json.load(r)["subsonic-response"]
        if body.get("status") != "ok":
            raise RuntimeError(f"{method}: {body.get('error')}")
        return body


def load_state():
    with open(STATE) as f:
        return json.load(f)


def save_state(state):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1, ensure_ascii=False, sort_keys=True)
    os.replace(tmp, STATE)


def init():
    if os.path.exists(STATE):
        sys.exit(f"{STATE} exists; refusing to reseed over it")
    folders, playlists, _ = library()
    state = {"folders": {}}
    for name, songs in sorted(folders.items()):
        if name not in INITIAL_LINKS:
            sys.exit(f"folder {name!r} has no agreed link; add it to INITIAL_LINKS first")
        target = INITIAL_LINKS[name]
        if target is not None and target not in playlists:
            sys.exit(f"playlist {target!r} for folder {name!r} not found")
        state["folders"][name] = {
            "playlist": playlists[target] if target else None,
            "playlistName": target,
            "seen": sorted(sid for sid, _ in songs),
        }
    missing = set(INITIAL_LINKS) - set(folders)
    if missing:
        sys.exit(f"agreed folders not on the server: {sorted(missing)}")
    save_state(state)
    linked = sum(1 for f in state["folders"].values() if f["playlist"])
    seen = sum(len(f["seen"]) for f in state["folders"].values())
    log(f"seeded {len(state['folders'])} folders ({linked} linked), {seen} songs marked seen")


def run(dry):
    state = load_state()
    folders, playlists, members = library()
    ids_by_name = playlists
    existing_ids = set(playlists.values())
    api = None if dry else Api()
    if api:
        status = api.call("getScanStatus", [])["scanStatus"]
        if status.get("scanning"):
            log("scan in progress; trying again next run")
            return

    for name, songs in sorted(folders.items()):
        entry = state["folders"].get(name)
        if entry is None:
            # A folder seen for the first time: its own playlist, every song in it.
            pname = name.strip()
            ids = [sid for sid, _ in songs]
            if pname in ids_by_name:
                # A playlist of that name already exists (made on the phone first):
                # adopt it and add only what it lacks.
                pid = ids_by_name[pname]
                add = [i for i in ids if i not in members[pid]]
                log(f"new folder {name!r}: adopt playlist {pname!r}, add {len(add)} of its {len(ids)} songs")
                if api and add:
                    api.call("updatePlaylist", [("playlistId", pid)] + [("songIdToAdd", i) for i in add])
            else:
                log(f"new folder {name!r}: create playlist {pname!r} with {len(ids)} songs")
                pid = None
                if api:
                    body = api.call("createPlaylist", [("name", pname)] + [("songId", i) for i in ids])
                    pid = body["playlist"]["id"]
            if api:
                state["folders"][name] = {"playlist": pid, "playlistName": pname, "seen": sorted(ids)}
                save_state(state)
            continue

        seen = set(entry["seen"])
        new = [(sid, path) for sid, path in songs if sid not in seen]
        if not new:
            continue
        pid = entry["playlist"]
        if pid is None:
            log(f"{name!r}: {len(new)} new, folder feeds nothing; marking seen")
        elif pid not in existing_ids:
            # The playlist was deleted on purpose; don't bring it back.
            log(f"{name!r}: linked playlist {entry.get('playlistName')!r} is gone; unlinking, {len(new)} new marked seen")
            entry["playlist"] = None
        else:
            # Skip songs already in the playlist: the phone may have put one there
            # before this run, and appending it again would double it.
            add = [(sid, path) for sid, path in new if sid not in members[pid]]
            for _, path in add:
                log(f"{name!r}: + {path.split('/')[-1]} -> {entry.get('playlistName')!r}")
            if len(add) < len(new):
                log(f"{name!r}: {len(new) - len(add)} new already in {entry.get('playlistName')!r}")
            if api and add:
                api.call("updatePlaylist", [("playlistId", pid)] + [("songIdToAdd", sid) for sid, _ in add])
        if api:
            entry["seen"] = sorted(seen | {sid for sid, _ in new})
            save_state(state)


def relink(folder, target):
    state = load_state()
    folders, playlists, _ = library()
    if folder not in folders:
        sys.exit(f"no folder {folder!r} on the server (names are exact, spaces included)")
    if target is not None and target not in playlists:
        sys.exit(f"no playlist named {target!r}")
    entry = state["folders"].setdefault(folder, {"seen": sorted(sid for sid, _ in folders[folder])})
    entry["playlist"] = playlists[target] if target else None
    entry["playlistName"] = target
    save_state(state)
    log(f"{folder!r} -> {target!r}" if target else f"{folder!r} -> nothing")


def show():
    state = load_state()
    folders, playlists, _ = library()
    alive = set(playlists.values())
    for name in sorted(set(folders) | set(state["folders"])):
        e = state["folders"].get(name)
        if e is None:
            what = "(new - becomes its own playlist on the next run)"
        elif e["playlist"] is None:
            what = "nothing"
        elif e["playlist"] not in alive:
            what = f"{e.get('playlistName')!r} (deleted - unlinks on the next run)"
        else:
            what = repr(e.get("playlistName"))
        print(f"{name!r:28} {len(folders.get(name, [])):4} songs -> {what}")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--link"] and len(args) == 3:
        relink(args[1], args[2])
    elif args[:1] == ["--unlink"] and len(args) == 2:
        relink(args[1], None)
    elif args[:1] == ["--list"]:
        show()
    elif "--init" in sys.argv:
        init()
    else:
        try:
            run(dry="--dry-run" in sys.argv)
        except Exception as e:             # one line in run.log, not a traceback every 15 min
            log(f"FAILED: {e}")
            sys.exit(1)
