"""Catalogues the Apple Loops installed with Logic Pro / GarageBand and the
Final Cut Pro sound effects: tempo, key, category, beat count, duration.
Writes tools/build/loops.json for mix_soundtrack.py."""
import json, os, struct

ROOT = "/Library/Audio/Apple Loops/Apple"
HERE = os.path.dirname(os.path.abspath(__file__))


def chunks(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"caff":
        return {}
    pos, out = 8, {}
    while pos + 12 <= len(data):
        ctype = data[pos:pos + 4].decode("latin1")
        size = struct.unpack(">q", data[pos + 4:pos + 12])[0]
        body = data[pos + 12: pos + 12 + size] if size >= 0 else data[pos + 12:]
        out.setdefault(ctype, []).append(body)
        if size < 0:
            break
        pos += 12 + size
    return out


def main():
    rows = []
    for dirpath, _, files in os.walk(ROOT):
        for fn in files:
            if not fn.lower().endswith((".caf", ".aif", ".aiff")):
                continue
            path = os.path.join(dirpath, fn)
            try:
                c = chunks(path)
            except Exception:
                continue
            meta = {}
            for key in ("uuid", "info"):
                for body in c.get(key, []):
                    raw = body[16:] if key == "uuid" else body
                    if len(raw) < 4:
                        continue
                    parts = raw[4:].split(b"\x00")
                    for k, v in zip(parts[0::2], parts[1::2]):
                        k = k.decode("utf8", "replace")
                        if k and k not in meta:
                            meta[k] = v.decode("utf8", "replace")
            dur = None
            if "desc" in c:
                d = c["desc"][0]
                sr = struct.unpack(">d", d[:8])[0]
                bytes_per_packet = struct.unpack(">I", d[16:20])[0]
                if "pakt" in c:
                    frames = struct.unpack(">q", c["pakt"][0][8:16])[0]
                elif "data" in c and bytes_per_packet:
                    frames = (len(c["data"][0]) - 4) // bytes_per_packet
                else:
                    frames = None
                if frames:
                    dur = frames / sr
            beats = int(meta.get("beat count", "0") or 0)
            rows.append(dict(
                pack=os.path.relpath(dirpath, ROOT).split("/")[0], name=fn[:-4], path=path,
                cat=meta.get("category", ""), sub=meta.get("subcategory", ""),
                key=meta.get("key signature", ""), ktype=meta.get("key type", ""), beats=beats,
                dur=round(dur, 3) if dur else None,
                bpm=round(beats * 60 / dur, 2) if dur and beats else None,
                desc=meta.get("descriptors", ""), genre=meta.get("genre", ""),
            ))
    os.makedirs(os.path.join(HERE, "build"), exist_ok=True)
    with open(os.path.join(HERE, "build", "loops.json"), "w") as f:
        json.dump(rows, f, indent=0)
    print(len(rows), "loops catalogued")


if __name__ == "__main__":
    main()
