#!/usr/bin/env python3
# Lyrics for the dashboard music tab (quickshell/Lyrics.qml).
#   lyrics.py <artist> <title> <album> <duration-seconds>
# Prints one JSON line: {"status": "synced"|"plain"|"instrumental"|"none"|"error", "synced", "plain",
# "lines", "source"}.
# First choice: Apple Music's own time-synced lyrics, when Cider is playing this track, through
# Cider's local API (its amapi proxy, so no token of our own; "lines" carries each line's start
# and end, source "apple"). Otherwise LRCLIB (https://lrclib.net):
# tries /api/get (exact match), then /api/search, then a search with the title stripped of
# "(feat. ...)", "- Remastered" etc. and only the first artist. Busy/unreachable server -> a few
# retries, then "error" (not cached, Lyrics.qml retries later). Results (including "none", for a
# week) are cached in $XDG_CACHE_HOME/quickshell/lyrics/.
import hashlib, json, os, re, sys, time, urllib.error, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

API = "https://lrclib.net/api"
CIDER = "http://127.0.0.1:10767/api/v1"
TTML = "{http://www.w3.org/ns/ttml}"
UA = "quickshell-dashboard/1.0 (personal dotfiles; lyrics tab)"
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "quickshell", "lyrics")
NONE_TTL = 7 * 86400


class Unavailable(Exception):
    pass


def request(path, params, tries=3):
    url = API + path + "?" + urllib.parse.urlencode(params)
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=10) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code not in (429, 500, 502, 503, 504):
                raise Unavailable("HTTP %d" % e.code)
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            pass
        if attempt < tries - 1:
            time.sleep(1.5 * (attempt + 1))
    raise Unavailable("LRCLIB unreachable")


def norm(s):
    return re.sub(r"[^a-z0-9]+", "", s.lower())


def pick(results, artist, duration):
    best, best_score = None, None
    for r in results or []:
        if not (r.get("syncedLyrics") or r.get("plainLyrics") or r.get("instrumental")):
            continue
        diff = abs((r.get("duration") or 0) - duration) if duration > 0 and r.get("duration") else 0
        if diff > 8:
            continue
        score = (0 if r.get("syncedLyrics") else 1, 0 if norm(artist) and norm(artist) in norm(r.get("artistName", "")) else 1, diff)
        if best_score is None or score < best_score:
            best, best_score = r, score
    return best


def clean_title(t):
    t = re.sub(r"\s*[\(\[][^)\]]*[\)\]]", "", t)               # (feat. X), [Live], (Remastered 2011)
    t = re.sub(r"\s+-\s+.*$", "", t)                             # "Song - 2011 Remaster"
    return t.strip()


def first_artist(a):
    return re.split(r"\s*(?:,|&| and | feat\.? | ft\.? | x )\s*", a, maxsplit=1, flags=re.I)[0].strip()


def lookup(artist, title, album, duration):
    if duration > 0:
        r = request("/get", {"artist_name": artist, "track_name": title, "album_name": album, "duration": int(round(duration))})
        if r and (r.get("syncedLyrics") or r.get("plainLyrics") or r.get("instrumental")):
            return r, "get"
    r = pick(request("/search", {"artist_name": artist, "track_name": title}), artist, duration)
    if r:
        return r, "search"
    ct, fa = clean_title(title), first_artist(artist)
    if (ct, fa) != (title, artist) and ct:
        r = pick(request("/search", {"artist_name": fa, "track_name": ct}), fa, duration)
        if r:
            return r, "search"
    return None, ""


def cider_json(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(CIDER + path, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=4) as r:
        return json.load(r)


def ttml_time(s):
    # "3.357", "1:05.677", "1:02:03.5" (also "12.3s")
    secs = 0.0
    for part in s.rstrip("s").split(":"):
        secs = secs * 60 + float(part)
    return secs


def apple(title):
    """Apple Music lyrics for the track Cider is playing, if it is `title`; None when unavailable."""
    try:
        info = cider_json("/playback/now-playing").get("info") or {}
        if info.get("name") != title or not info.get("hasLyrics"):
            return None
        pp = info.get("playParams") or {}
        sid = str(pp.get("catalogId") or pp.get("id") or "")
        if not sid.isdigit():
            return None
        d = cider_json("/amapi/run-v3", {"path": "/v1/catalog/us/songs/%s/lyrics" % sid})
        ttml = d["data"]["data"][0]["attributes"]["ttml"]
        root = ET.fromstring(ttml)
    except (OSError, ValueError, KeyError, IndexError, TypeError, ET.ParseError):
        return None
    timed = root.get("{http://music.apple.com/lyric-ttml-internal}timing", "Line") != "None"
    lines = []
    for p in root.iter(TTML + "p"):
        text = re.sub(r"\s+", " ", "".join(p.itertext())).strip()
        if not text:
            continue
        try:
            lines.append({"t": round(ttml_time(p.get("begin")), 3), "e": round(ttml_time(p.get("end")), 3), "text": text})
        except (TypeError, ValueError):
            timed = False
            lines.append({"t": 0, "e": 0, "text": text})
    if not lines:
        return None
    plain = "\n".join(l["text"] for l in lines)
    if not timed:
        return {"status": "plain", "plain": plain, "source": "apple"}
    return {"status": "synced", "lines": lines, "plain": plain, "source": "apple"}


def main():
    artist, title, album = (sys.argv[1:4] + ["", "", ""])[:3]
    try:
        duration = float(sys.argv[4]) if len(sys.argv) > 4 else 0
    except ValueError:
        duration = 0
    if not title:
        print(json.dumps({"status": "none"}))
        return

    key = "\x1f".join([artist.lower(), title.lower(), album.lower(), str(int(round(duration)))])
    apple_path = os.path.join(CACHE, "am-" + hashlib.sha1(key.encode()).hexdigest() + ".json")
    path = os.path.join(CACHE, hashlib.sha1(key.encode()).hexdigest() + ".json")
    try:
        with open(apple_path) as f:
            print(json.dumps(json.load(f)))
            return
    except (OSError, ValueError):
        pass
    out = apple(title)
    if out:
        out["at"] = int(time.time())
        save(apple_path, out)
        print(json.dumps(out))
        return

    try:
        with open(path) as f:
            cached = json.load(f)
        if cached.get("status") != "none" or time.time() - cached.get("at", 0) < NONE_TTL:
            print(json.dumps(cached))
            return
    except (OSError, ValueError):
        pass

    try:
        r, source = lookup(artist, title, album, duration)
    except Unavailable as e:
        print(json.dumps({"status": "error", "detail": str(e)}))
        return

    if not r:
        out = {"status": "none"}
    elif r.get("instrumental"):
        out = {"status": "instrumental"}
    else:
        out = {"status": "synced" if r.get("syncedLyrics") else "plain",
               "synced": r.get("syncedLyrics") or "", "plain": r.get("plainLyrics") or ""}
    out["source"] = source
    out["at"] = int(time.time())
    save(path, out)
    print(json.dumps(out))


def save(path, out):
    try:
        os.makedirs(CACHE, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(out, f)
        os.replace(tmp, path)
    except OSError:
        pass


if __name__ == "__main__":
    main()
