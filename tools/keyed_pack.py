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

Needs the `cryptography` package (pip install cryptography).
"""
import argparse
import glob
import hashlib
import os
import secrets
import struct
import sys
import time

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
    args = ap.parse_args()
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
