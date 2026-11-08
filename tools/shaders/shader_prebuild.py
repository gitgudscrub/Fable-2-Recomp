"""Shader pre-build list: lets a fresh install build every known pipeline up front.

The SDK's shader cache (cache/shaders/shareable/<title>.xsh + .xpso) holds the
game's shader code, which must not be committed. This tool turns a warm cache
into a pre-build list that holds only references into the game's own shader
banks, the small vertex-layout patches the Xbox D3D runtime applies to vertex
shaders, and the pipeline descriptions (render state + shader hashes). On a new
install, `restore` rebuilds the cache files from the player's own game data, and
the SDK then creates every pipeline at boot instead of stuttering in game.

usage:
  shader_prebuild.py build   --cache DIR --game-root DIR --out FILE [--xex-image FILE]
  shader_prebuild.py restore --prebuild FILE --game-root DIR --cache DIR [--force] [--xex-image FILE]
  shader_prebuild.py verify  --prebuild FILE --game-root DIR --cache DIR [--xex-image FILE]

--xex-image is the decrypted guest image made by tools/xex_image.py; it is only
needed for the few built-in shaders that live in default.xex, not in the banks.
"""
import argparse
import base64
import json
import os
import struct
import sys
import zlib
from collections import Counter

TITLE_ID = "4D5307F1"
BANKS = ("data/Shaders/ShadersRelease.sbk", "data/Shaders/Shaders.sbk")
XSH_HEADER_SIZE = 8  # "XESH" + version
FORMAT = 1


# --- game data sources -------------------------------------------------------

def read_bank(path):
    """Returns the unpacked entries of a "ShaderBankFile".

    Layout: header and constant-name metadata, a table of big-endian u32 entry
    offsets relative to the data start (the last value is the data length),
    then per entry a big-endian u32 size and that many bytes of zlib that ends
    with a sync flush instead of a final block.
    """
    d = open(path, "rb").read()
    if not d.startswith(b"ShaderBankFile"):
        raise ValueError("%s is not a shader bank" % path)
    size = len(d)
    for start in range(16, size - 8):
        if struct.unpack_from(">I", d, start - 4)[0] != size - start:
            continue
        n = struct.unpack_from(">I", d, start)[0]
        if start + 4 + n > size:
            continue
        try:
            zlib.decompressobj().decompress(d[start + 4:start + 4 + n])
        except zlib.error:
            continue
        break
    else:
        raise ValueError("%s: data section not found" % path)
    entries, pos = [], start
    while pos < size:
        n = struct.unpack_from(">I", d, pos)[0]
        entries.append(zlib.decompressobj().decompress(d[pos + 4:pos + 4 + n]))
        pos += 4 + n
    return entries


def load_sources(game_root, xex_image):
    """Returns {source name: bytes}, every place a shader's ucode can come from."""
    sources = {}
    for bank in BANKS:
        path = os.path.join(game_root, bank)
        if os.path.exists(path):
            for i, entry in enumerate(read_bank(path)):
                sources["%s#%d" % (bank, i)] = entry
    if xex_image:
        sources["xex"] = open(xex_image, "rb").read()
    if not sources:
        raise SystemExit("no shader banks found under %s" % game_root)
    return sources


# --- SDK cache files ---------------------------------------------------------

def read_xsh(path):
    x = open(path, "rb").read()
    header, records, off = x[:XSH_HEADER_SIZE], [], XSH_HEADER_SIZE
    while off + 12 <= len(x):
        ucode_hash, packed = struct.unpack_from("<QI", x, off)
        count = packed & 0x7FFFFFFF
        end = off + 12 + count * 4
        if end > len(x):
            break  # a record cut short when the game closed
        records.append({"hash": ucode_hash, "packed": packed, "ucode": x[off + 12:end]})
        off = end
    return header, records


def write_xsh(path, header, records):
    with open(path, "wb") as f:
        f.write(header)
        for r in records:
            f.write(struct.pack("<QI", r["hash"], r["packed"]))
            f.write(r["ucode"])


def cache_paths(cache_dir):
    return (os.path.join(cache_dir, TITLE_ID + ".xsh"),
            os.path.join(cache_dir, TITLE_ID + ".rtv.d3d12.xpso"))


# --- matching ----------------------------------------------------------------

class SourceIndex:
    """Finds where a shader's ucode sits in the sources, allowing patched dwords."""

    WINDOW = 16

    def __init__(self, sources):
        self.sources = sources
        self.windows = {}
        for name, data in sources.items():
            for off in range(0, len(data) - self.WINDOW + 1, 4):
                self.windows.setdefault(data[off:off + self.WINDOW], []).append((name, off))

    def locate(self, ucode):
        """Returns (source, offset, xor patches) for the best match, or None."""
        for name, data in self.sources.items():
            off = data.find(ucode)
            if off != -1 and off % 4 == 0:
                return name, off, []
        votes = Counter()
        for i in range(0, len(ucode) - self.WINDOW + 1, 4):
            for name, off in self.windows.get(ucode[i:i + self.WINDOW], ())[:8]:
                if off >= i:
                    votes[(name, off - i)] += 1
        for (name, off), _ in votes.most_common(4):
            base = self.sources[name][off:off + len(ucode)]
            if len(base) != len(ucode):
                continue
            patches = []
            for k in range(0, len(ucode), 4):
                a = struct.unpack_from(">I", ucode, k)[0]
                b = struct.unpack_from(">I", base, k)[0]
                if a != b:
                    patches.append([k // 4, a ^ b])
            # A real match differs only in patched fetch instructions.
            if len(patches) * 2 <= len(ucode) // 4:
                return name, off, patches
        return None


def apply(source_bytes, offset, dword_count, patches):
    ucode = bytearray(source_bytes[offset:offset + dword_count * 4])
    for index, xor in patches:
        value = struct.unpack_from(">I", ucode, index * 4)[0] ^ xor
        struct.pack_into(">I", ucode, index * 4, value)
    return bytes(ucode)


# --- commands ----------------------------------------------------------------

def cmd_build(args):
    xsh_path, xpso_path = cache_paths(args.cache)
    header, records = read_xsh(xsh_path)
    index = SourceIndex(load_sources(args.game_root, args.xex_image))
    shaders, missing = [], 0
    for r in records:
        found = index.locate(r["ucode"])
        entry = {"hash": "%016X" % r["hash"], "packed": r["packed"]}
        if found is None:
            entry["missing"] = True
            missing += 1
        else:
            entry["source"], entry["offset"], entry["patches"] = found
        shaders.append(entry)
    prebuild = {
        "format": FORMAT,
        "title": TITLE_ID,
        "xsh_header": header.hex(),
        "shaders": shaders,
        # Pipeline descriptions: render state and shader hashes only.
        "pipelines": base64.b64encode(open(xpso_path, "rb").read()).decode(),
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(prebuild, f, indent=0)
    patched = sum(1 for s in shaders if s.get("patches"))
    print("shaders: %d (%d exact, %d with vertex-layout patches, %d not in the game data)"
          % (len(shaders), len(shaders) - patched - missing, patched, missing))
    print("pipelines: %d" % ((os.path.getsize(xpso_path) - 12) // 72))
    print("wrote", args.out)


def rebuild_records(prebuild, sources):
    records, skipped = [], 0
    for s in prebuild["shaders"]:
        if s.get("missing") or s["source"] not in sources:
            skipped += 1
            continue
        count = s["packed"] & 0x7FFFFFFF
        ucode = apply(sources[s["source"]], s["offset"], count, s["patches"])
        records.append({"hash": int(s["hash"], 16), "packed": s["packed"], "ucode": ucode})
    return records, skipped


def cmd_restore(args):
    prebuild = json.load(open(args.prebuild))
    xsh_path, xpso_path = cache_paths(args.cache)
    if not args.force and (os.path.exists(xsh_path) or os.path.exists(xpso_path)):
        raise SystemExit("cache files already exist in %s (use --force to replace)" % args.cache)
    records, skipped = rebuild_records(prebuild, load_sources(args.game_root, args.xex_image))
    os.makedirs(args.cache, exist_ok=True)
    write_xsh(xsh_path, bytes.fromhex(prebuild["xsh_header"]), records)
    open(xpso_path, "wb").write(base64.b64decode(prebuild["pipelines"]))
    print("restored %d shaders (%d skipped) and the pipeline list into %s"
          % (len(records), skipped, args.cache))


def cmd_verify(args):
    """Checks that restore reproduces the cache's shaders byte for byte."""
    prebuild = json.load(open(args.prebuild))
    _, original = read_xsh(cache_paths(args.cache)[0])
    by_hash = {r["hash"]: r["ucode"] for r in original}
    records, skipped = rebuild_records(prebuild, load_sources(args.game_root, args.xex_image))
    bad = [r for r in records if by_hash.get(r["hash"]) != r["ucode"]]
    print("verified %d shaders, %d mismatched, %d skipped" % (len(records), len(bad), skipped))
    return 1 if bad else 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build")
    b.add_argument("--cache", required=True)
    b.add_argument("--game-root", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--xex-image")
    r = sub.add_parser("restore")
    r.add_argument("--prebuild", required=True)
    r.add_argument("--game-root", required=True)
    r.add_argument("--cache", required=True)
    r.add_argument("--force", action="store_true")
    r.add_argument("--xex-image")
    v = sub.add_parser("verify")
    v.add_argument("--prebuild", required=True)
    v.add_argument("--game-root", required=True)
    v.add_argument("--cache", required=True)
    v.add_argument("--xex-image")
    args = p.parse_args()
    return {"build": cmd_build, "restore": cmd_restore, "verify": cmd_verify}[args.command](args) or 0


if __name__ == "__main__":
    sys.exit(main())
