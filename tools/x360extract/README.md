# x360extract

Command-line tool that extracts game content from Xbox 360 disc images (raw
ISO/rumb). Written for the Fable 2 GOTY recompile project, but it works on any
retail Xbox 360 disc that uses the GDFX filesystem.

The disc-reading logic lives in a reusable library in [`lib/`](lib/README.md)
(`X360ExtractCore.dll`). This CLI is a thin `Program.cs` on top of it, and the
Fable II launcher consumes the same library — so there is a single source of
truth for the GDFX / ISO 9660 / STFS readers.

## What it does

The tool reads the disc image directly (no mounting, no virtual drive):

1. **Scans for the GDFX header** (`MICROSOFT*XBOX*MEDIA` magic) — 64 MiB chunks,
   ~1 s on a 7.8 GB disc.
2. **Walks the GDFX directory tree** (variable-length entries,
   `0xFFFFFFFF`-terminated) starting at the root sector in the header.
3. **Reads each file's content** from the GDFX data region
   (`header_offset - 0x10000 + sector * 2048`) and writes it to disk.
4. **Copies every file byte-for-byte**, including STFS containers
   (PIRS/LIVE/CON packages) such as `nxeart` and
   `$SystemUpdate/su20076000_00000000`, which stay raw PIRS blobs — exactly
   how retail extraction tools present the GDFX tree. With `--unpack-stfs`,
   STFS file entries are instead expanded into a directory named after the
   entry (e.g. `nxeart/` containing `DashStyle`, `nxebg.jpg`, `nxeslot.jpg`).

Game data on these discs is stored as raw, unencrypted files — there is no
CAB/LZX layer to decode.

GDFX directories can span multiple 0x800-byte sectors (e.g. `data/audio` is
5 sectors / 213 entries on the Fable 2 GOTY disc). Entries are grouped per
sector with 0xFF padding at the end of each batch; the walker follows the
batch chain across sector boundaries up to the directory's declared size.

## Build

```
build.cmd                    self-contained single-file exe (default; ships
                             with the .NET 8 runtime, ~70 MB)
build.cmd dev                framework-dependent single-file exe (needs the
                             .NET 8 runtime installed)
build.cmd pack               pack the reusable library as a NuGet package
```

The cmd cleans the staged output and intermediate build dirs, then publishes
to `out\tooling\x360extract\` at the repo root:

```
out\tooling\x360extract\x360extract.exe
```

The default self-contained build runs on a clean Windows machine with no
.NET install — the same story as the launcher's default build. The single-file
exe bundles the `X360ExtractCore.dll` library inside it.

## Reusable library

`lib/` is a standalone .NET 8 class library (`X360ExtractCore.dll`, namespace
`X360Extract`) that does all the real work: the GDFX, ISO 9660 and STFS
readers plus a high-level `X360Disc` facade (`Open` / `Extract` /
`ExtractEntries` / `WriteFile` / `ListTree`). Any .NET project can use it:

- **Project reference** — `<ProjectReference
  Include="..\..\tools\x360extract\lib\X360Extract.Core.csproj" />`
- **NuGet package** — `build.cmd pack` produces
  `out\tooling\nuget\Fable2.X360Extract.<version>.nupkg`.
- **Copy the DLL** — drop `X360ExtractCore.dll` next to your project and add
  a `<Reference>`.

See [`lib/README.md`](lib/README.md) for the full API and examples.

## Usage

```
x360extract <iso> [options]          Extract game content from an Xbox 360 ISO
x360extract --list <iso>             List the GDFX file tree without extracting
x360extract <iso> --manifest <file>  Write a reference list (sha256 size path) of every file

Options:
  -o, --out <dir>       Output directory (default: current directory)
  --list                List the GDFX directory tree
  --manifest <file>     Hash every file on the disc into a reference list
  --files <a,b,c>       Only extract the named root entries (case-insensitive)
  --unpack-stfs         Expand STFS (PIRS/LIVE/CON) file entries into
                        directories (default: copy them as raw files)
  --quiet               Suppress progress output
  -h, --help            Show this help
```

Exit codes: `0` success, `1` usage error, `2` disc/format error (e.g. no
GDFX header found), `3` unexpected error.

### Examples

```bat
:: Inspect a disc without extracting anything
x360extract.exe "D:\discs\Fable II (GOTY).iso" --list

:: Extract everything into the project root
x360extract.exe "D:\discs\Fable II (GOTY).iso" -o .

:: Extract only the executable and the data tree
x360extract.exe "D:\discs\Fable II (GOTY).iso" -o . --files default.xex,data

:: Write the reference list the launcher's "Check game files" uses
x360extract.exe "D:\discs\Fable II (GOTY).iso" --manifest constants\disc-manifests\goty-us-eu.txt

:: Extract quietly (scriptable; progress goes nowhere, errors to stderr)
x360extract.exe "D:\discs\Fable II (GOTY).iso" -o C:\content --quiet
```

`--list` prints the full tree with sizes, e.g.:

```
GDFX header at 0FDA0000  (base 0FD90000)
Root sector: 001B387F  size: 2048

  dir  data
      dir  interactivecutscenes
          file interactivecutscenes.gdb  (795,682)
          ...
  dir  $SystemUpdate
      file su20076000_00000000  (7,938,048)
      file system.manifest  (2,100)
  file default.xex  (21,217,280)
  file nxeart  (1,433,600)
```

## Output layout

For the Fable 2 GOTY (USA/EU) disc, a full extraction produces exactly the
content root that `tools\stage_content.cmd` expects:

```
<out>\
├── default.xex              game executable (21 MB)
├── data\                    447 game asset files (worlds, audio, shaders,
│                            scripts, .bnk/.bik streams, dir.manifest, ...)
├── nxeart                   dashboard art package (raw 1.4 MB PIRS file)
└── $SystemUpdate\           system update package
    ├── su20076000_00000000  raw PIRS blob
    └── system.manifest      XMNP manifest
```

With `--unpack-stfs`, `nxeart` becomes a directory:

```
<out>\
├── default.xex
├── data\
├── nxeart\
│   ├── DashStyle
│   ├── nxebg.jpg
│   └── nxeslot.jpg
└── $SystemUpdate\
```

Verified: a default extraction is **byte-for-byte identical** (SHA-1 of all
451 files) to the output of the XexTool GUI on the same ISO.

Files are written with `FileMode.Create` — re-running over an existing output
tree overwrites each file in place but does **not** delete files that are no
longer in the disc tree. Remove the output directory first if you need a
pristine copy.

## Notes

- The input must be a full raw disc image (sector dump). A truncated or
  compressed image will not contain the GDFX data region.
- Extraction throughput is limited by disk reads: a full Fable 2 GOTY
  extraction (~371 files, 6.3 GB) takes a few seconds plus the one-time
  header scan.
- The tool is intentionally format-generic: it extracts whatever the GDFX
  tree contains, so it also works on other retail Xbox 360 titles
  (including discs whose data is in a `data.cab` — that is copied raw as a
  regular file).

## Source layout

| File | Role |
|---|---|
| `Program.cs` | CLI, GDFX header scan, tree walk/extraction driver |
| `Gdfx.cs` | GDFX filesystem reader (header, variable-length directory entries, file reads) |
| `Stfs.cs` | STFS (PIRS/LIVE/CON) container reader (used by `--unpack-stfs`) — hash-tree block addressing, file table, block streaming |
| `Iso9660.cs` | Raw image byte/sector reader (`IsoImage`) |
