#!/usr/bin/env python3
"""Encrypt a texture pack so it only opens next to the game it was made from.

The pack's replacement textures are derived from the game's own art, so a
plain copy of replace/ is a loose copy of that art. This tool turns every
replace/<hash>.dds into <hash>.edds, encrypted with a key that is derived
from the ORIGINAL texture's pixels (the dump the game wrote), and the game
derives the same key from the texture it has just loaded. Nobody holds a
pack-wide key: each file opens only for someone whose game is loading that
very texture. Whoever receives the pack needs no dump folder.

Format of an .edds file (read by the SDK's LoadKeyedDds):
    0   magic "F2TXPK01"
    8   nonce, 12 bytes (random per file)
    20  GCM tag, 16 bytes
    36  the DDS file, AES-256-GCM encrypted
key = SHA-256("F2TXPK01" || untiled base level of the original texture),
where the untiled base level is exactly the payload of the dump file (the
bytes after its DDS header). The 16-character hash in the file name is the
authenticated associated data, so a file cannot be renamed to another hash.

Usage:
  python tools/keyed_pack.py encrypt <pack_root> --out <folder>
      Writes <folder>/replace/<hash>.edds for every replace/<hash>.dds that
      has a dump (textures without a dump are reported and skipped).
  python tools/keyed_pack.py decrypt <pack_root> <folder> --out <folder2>
      Round trip for checking: opens every .edds with the dumps and writes
      the DDS back. The result must be byte-identical to replace/.
  python tools/keyed_pack.py verify <pack_root> <folder>
      Opens every .edds in memory and compares it with replace/.
  python tools/keyed_pack.py split <folder> --out <dist> --version N
      Packs <folder>/replace/*.edds into 16 stored zips by the first hex
      digit of the hash (so a later pack version changes only the parts
      whose textures changed) and writes manifest.json beside them: the
      launcher downloads the parts it lists, checks each SHA-256 and
      unpacks them into textures\replace. Sign the manifest for release
      with `dotnet run --project tools/sparrow-sign -- sign manifest.json`
      (see docs/TEXTURE_PACK_DOWNLOAD.md).

Needs the `cryptography` package (pip install cryptography).
"""
import argparse
import datetime
import glob
import hashlib
import json
import os
import secrets
import struct
import sys
import time
import zipfile

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b'F2TXPK01'
NONCE_BYTES = 12
TAG_BYTES = 16
DDS_MAGIC = b'DDS '


def dump_payload(path):
    """The bytes the game hashed: a dump's data after its DDS header."""
    with open(path, 'rb') as fh:
        data = fh.read()
    if data[:4] != DDS_MAGIC or len(data) < 128:
        raise ValueError(f'{path}: not a DDS file')
    header_size = struct.unpack_from('<I', data, 4)[0]
    if header_size != 124:
        raise ValueError(f'{path}: unexpected DDS header size {header_size}')
    offset = 4 + 124
    four_cc = data[84:88]
    if four_cc == b'DX10':
        offset += 20
    return data[offset:]


def derive_key(payload):
    return hashlib.sha256(MAGIC + payload).digest()


def find_dumps(pack_root):
    dumps = {}
    for path in glob.glob(os.path.join(pack_root, 'dump', '*.dds')):
        name = os.path.basename(path)
        if len(name) >= 16:
            dumps[name[:16].upper()] = path
    return dumps


def hash_of(path):
    return os.path.basename(path)[:16].upper()


def encrypt_file(src, dst, key, hash_hex):
    with open(src, 'rb') as fh:
        plain = fh.read()
    nonce = secrets.token_bytes(NONCE_BYTES)
    # AESGCM.encrypt returns ciphertext || tag.
    sealed = AESGCM(key).encrypt(nonce, plain, hash_hex.encode('ascii'))
    cipher, tag = sealed[:-TAG_BYTES], sealed[-TAG_BYTES:]
    tmp = dst + '.tmp'
    with open(tmp, 'wb') as fh:
        fh.write(MAGIC)
        fh.write(nonce)
        fh.write(tag)
        fh.write(cipher)
    os.replace(tmp, dst)
    return len(plain)


def decrypt_bytes(data, key, hash_hex):
    if data[:8] != MAGIC or len(data) < 8 + NONCE_BYTES + TAG_BYTES:
        raise ValueError('not a keyed pack file')
    nonce = data[8:8 + NONCE_BYTES]
    tag = data[8 + NONCE_BYTES:8 + NONCE_BYTES + TAG_BYTES]
    cipher = data[8 + NONCE_BYTES + TAG_BYTES:]
    return AESGCM(key).decrypt(nonce, cipher + tag, hash_hex.encode('ascii'))


def cmd_encrypt(args):
    dumps = find_dumps(args.pack_root)
    sources = sorted(glob.glob(os.path.join(args.pack_root, 'replace', '*.dds')))
    out_dir = os.path.join(args.out, 'replace')
    os.makedirs(out_dir, exist_ok=True)
    t0 = time.time()
    done = skipped = 0
    total_bytes = 0
    for n, src in enumerate(sources, 1):
        h = hash_of(src)
        dump = dumps.get(h)
        if not dump:
            print(f'  no dump for {h}, skipped')
            skipped += 1
            continue
        dst = os.path.join(out_dir, h + '.edds')
        if not args.force and os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src):
            done += 1
            continue
        key = derive_key(dump_payload(dump))
        total_bytes += encrypt_file(src, dst, key, h)
        done += 1
        if n % 500 == 0 or n == len(sources):
            print(f'  {n}/{len(sources)}  ({time.time() - t0:.0f} s)')
    print(f'{done} files written to {out_dir}, {skipped} skipped, '
          f'{total_bytes / 2**20:.0f} MB in {time.time() - t0:.0f} s')
    return 1 if skipped else 0


def check_all(args, write_dir=None):
    dumps = find_dumps(args.pack_root)
    files = sorted(glob.glob(os.path.join(args.folder, 'replace', '*.edds')))
    bad = 0
    t0 = time.time()
    for n, path in enumerate(files, 1):
        h = hash_of(path)
        try:
            key = derive_key(dump_payload(dumps[h]))
            with open(path, 'rb') as fh:
                plain = decrypt_bytes(fh.read(), key, h)
        except Exception as e:  # noqa: BLE001 - report and count every failure
            print(f'  {h}: {e}')
            bad += 1
            continue
        if write_dir:
            with open(os.path.join(write_dir, h + '.dds'), 'wb') as fh:
                fh.write(plain)
        else:
            with open(os.path.join(args.pack_root, 'replace', h + '.dds'), 'rb') as fh:
                if fh.read() != plain:
                    print(f'  {h}: differs from replace/')
                    bad += 1
        if n % 500 == 0 or n == len(files):
            print(f'  {n}/{len(files)}  ({time.time() - t0:.0f} s)')
    print(f'{len(files) - bad} of {len(files)} files open and match')
    return 1 if bad else 0


PACK_NAME = 'modern-textures'
PART_COUNT = 16
RELEASE_URL = 'https://github.com/gitgudscrub/Fable-2-Recomp/releases/download/{tag}/{name}'


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for block in iter(lambda: fh.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def cmd_split(args):
    files = sorted(glob.glob(os.path.join(args.folder, 'replace', '*.edds')))
    if not files:
        raise SystemExit(f'no .edds files under {args.folder}')
    os.makedirs(args.out, exist_ok=True)
    tag = f'textures-v{args.version}'
    groups = [[] for _ in range(PART_COUNT)]
    for path in files:
        groups[int(hash_of(path)[0], 16)].append(path)
    t0 = time.time()
    parts = []
    total = 0
    for index, group in enumerate(groups):
        name = f'{PACK_NAME}-v{args.version}-part{index:02d}.zip'
        dst = os.path.join(args.out, name)
        # Stored (the files are block-compressed and encrypted: nothing to
        # gain) and deterministic (fixed timestamps, sorted entries), so a
        # part whose textures did not change is byte-identical to the last
        # version's and the launcher can skip it by hash.
        with zipfile.ZipFile(dst, 'w', zipfile.ZIP_STORED) as zf:
            for path in group:
                info = zipfile.ZipInfo(os.path.basename(path), date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_STORED
                info.external_attr = 0o644 << 16
                with open(path, 'rb') as fh:
                    zf.writestr(info, fh.read())
        size = os.path.getsize(dst)
        total += size
        parts.append({'name': name, 'size': size, 'sha256': sha256_file(dst), 'files': len(group),
                      'url': RELEASE_URL.format(tag=tag, name=name)})
        print(f'  {name}: {len(group)} files, {size / 2**20:.0f} MB  ({time.time() - t0:.0f} s)')
    manifest = {
        'pack': PACK_NAME,
        'version': args.version,
        'game_profile': args.profile,
        'created': datetime.date.today().isoformat(),
        'file_format': 'F2TXPK01',
        'install_dir': 'textures/replace',
        'total_bytes': total,
        'file_count': len(files),
        'parts': parts,
    }
    manifest_path = os.path.join(args.out, 'manifest.json')
    with open(manifest_path, 'w', encoding='utf-8', newline='\n') as fh:
        json.dump(manifest, fh, indent=2)
        fh.write('\n')
    print(f'{len(files)} files in {PART_COUNT} parts, {total / 2**20:.0f} MB, manifest {manifest_path}')
    print(f'release tag: {tag}')
    return 0


def cmd_decrypt(args):
    out_dir = os.path.join(args.out, 'replace')
    os.makedirs(out_dir, exist_ok=True)
    return check_all(args, out_dir)


def cmd_verify(args):
    return check_all(args)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='command', required=True)
    p = sub.add_parser('encrypt', help='replace/*.dds -> <out>/replace/*.edds')
    p.add_argument('pack_root', help='folder holding dump/ and replace/')
    p.add_argument('--out', required=True, help='folder that receives replace/*.edds')
    p.add_argument('--force', action='store_true', help='rewrite files that are already up to date')
    p.set_defaults(func=cmd_encrypt)
    p = sub.add_parser('decrypt', help='<folder>/replace/*.edds -> <out>/replace/*.dds')
    p.add_argument('pack_root', help='folder holding dump/ (for the keys)')
    p.add_argument('folder', help='folder holding replace/*.edds')
    p.add_argument('--out', required=True)
    p.set_defaults(func=cmd_decrypt)
    p = sub.add_parser('verify', help='open every .edds and compare with replace/')
    p.add_argument('pack_root', help='folder holding dump/ and replace/')
    p.add_argument('folder', help='folder holding replace/*.edds')
    p.set_defaults(func=cmd_verify)
    p = sub.add_parser('split', help='<folder>/replace/*.edds -> <out>/*-partNN.zip + manifest.json')
    p.add_argument('folder', help='folder holding replace/*.edds (the encrypt output)')
    p.add_argument('--out', required=True, help='folder that receives the parts and manifest')
    p.add_argument('--version', type=int, required=True, help='pack version (release tag textures-v<N>)')
    p.add_argument('--profile', default='goty-us-eu', help='game profile the pack was made from')
    p.set_defaults(func=cmd_split)
    args = ap.parse_args()
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
