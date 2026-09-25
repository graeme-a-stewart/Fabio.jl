# silx.io parity: gap analysis and phased plan

The goal: Fabio.jl should provide what [`silx.io`](https://silx.readthedocs.io/en/stable/modules/io/index.html)
provides. silx.io uses Python FabIO underneath, so it is a layer *on top of* the functionality
this package already ports.

This review is based on silx `main` at `8c282f4` (23 Sep 2026), `src/silx/io/`, and on
Fabio.jl at the close of Phase 4 (see [STATUS.md](../STATUS.md)).

---

## 1. What silx.io is

silx.io has one idea at its centre: **every file is presented as an h5py-like tree**. Code
built on silx (the viewer, PyMca, pyFAI's GUI, many beamline scripts) reads an EDF, a SPEC
file, a `.fio` file, an `.npy` file and a real HDF5 file through the same `Group`/`Dataset`
interface, and every one of them can be written out as HDF5/NeXus in the same layout.
Everything else in the package supports that idea: addressing data inside files (URLs), moving
trees in and out of HDF5, and interpreting NeXus `NXdata` groups.

| silx.io module | What it does |
|---|---|
| `utils.open` | Opens any supported file as an h5py-like object. Accepts `file::/path` and `file::/path[slice]`, and `http(s)://` for HSDS servers through h5pyd. |
| `utils.get_data` | Reads an array from a URL. Two schemes: `silx:` goes through `open` plus a NeXus path; `fabio:` calls `fabio.open` directly and uses the slice to pick a frame. With no scheme it tries both. |
| `url.DataUrl` | Parses and builds those URLs: scheme, file path, data path, data slice. Forms include `?path=&slice=`, the `::` shorthand, and relative paths. |
| `fabioh5.File` | **Shows a FabIO image, or a file series, as a NeXus tree** (layout in §3.2). Header values become typed per-frame vectors. EDF `motor_mne`/`motor_pos`/`counter_*` become positioners and counters, and `UB_*`/`sample_*` become an `NXsample`. |
| `commonh5` | An in-memory h5py-like tree: `File`, `Group`, `Dataset`, `LazyLoadableGroup/Dataset`, `SoftLink`, `attrs`, `visit`/`visititems`. Every non-HDF5 reader is built on it. |
| `_sliceh5.DatasetSlice` | A sliced view of a dataset, returned by `open("f::/d[0:10]")`. |
| `rawh5.NumpyFile` | `.npy`/`.npz` shown as a tree. |
| `convert.convert`, `write_to_h5` | Copies any `open`-able tree into an HDF5 file, with soft or hard links and dataset creation options such as compression and chunking. Behind the `silx convert` CLI, which also turns image *series* into a single HDF5 file. |
| `dictdump` | `dicttoh5`/`h5todict`, `dicttonx`/`nxtodict` (attributes encoded as `@name` keys), `dicttojson`, `dicttoini`, and a generic `dump`/`load`. The `dictdumplinks` subpackage serialises links into dicts: soft, external, **virtual datasets**, and **external raw-binary datasets whose targets are FabIO or TIFF files**. |
| `utils.rawfile_to_h5_external_dataset`, `vol_to_h5_external_dataset` | Make an HDF5 dataset that points at a raw binary file on disk, or a PyHST `.vol` plus its `.vol.info`. |
| `h5link_utils` | `external_dataset_info`: reports where an external or virtual dataset's bytes really live. |
| `nxdata` | `NXdata` parsing and validation: signal, axes, errors, auxiliary signals, `interpretation`, and `get_default` to follow `@default` down from `NXroot` and `NXentry`. `save_NXdata` writes one. |
| `specfile`, `spech5`, `specfilewrapper` | A SPEC file reader written in C (scans, labels, motors, MCA), shown as a NeXus tree, plus a PyMca-compatible API. |
| `fioh5` | DESY `.fio` scan files shown as a NeXus tree. |
| `utils.save1D`, `savetxt`, `savespec` | Writes 1D curves as SPEC, CSV, text or `.npy`. |
| `configdict` | Reads and writes INI-style configuration files with literal-evaluated values (PyMca `.cfg`). |
| `octaveh5` | Octave structs stored in HDF5. |
| `h5py_utils` | Retries on HDF5 errors (for files that are still being written), `File` with SWMR and locking management, `open_item`, `group_has_end_time`. |
| `utils` (misc) | `is_file/is_group/is_dataset/is_softlink/is_externallink`, `h5ls`, `visitall`, `iter_groups`, `match` (glob over tree paths), `supported_extensions`, `h5py_read_dataset/attribute` (string decoding). |

## 2. What Fabio.jl has that already covers part of this

| silx.io capability | Fabio.jl today | Coverage |
|---|---|---|
| Reading FabIO formats | 28 readers, 24 registry entries | ✅ full: this *is* the FabIO layer |
| `open("file.h5::/path")` for HDF5 image data | `splitfragment`, `NexusLike` flavours in `ext/hdf5/` | 🟡 read only, and only to get **image frames**. No general tree access, no slicing in the URL |
| `get_data("fabio:file::[i]")` | `readimage(path; frame=i)` | 🟡 same result, but there is no URL grammar |
| `supported_extensions()` | `Fabio.formats()`, registry `extensions` | 🟡 information exists; no helper returns glob patterns |
| Series (`file_series` input to `fabioh5`) | `FileSeries`, `open_series`, `seriespaths` | ✅ |
| Stacking frames for `detector_0/data` | `framestack(file)` | ✅ in memory only; no lazy or on-disk stack |
| Per-format header semantics | `Header` (raw), `ImageMetadata`/`normalise` (six quantities, 8 formats) | 🟡 no EDF motor/counter/UB mnemonic parsing, no per-frame typed vectors |
| Writing | `writeimage`/`convertimage` for 15 image formats, `fabio-convert` CLI | 🟡 **no HDF5/NeXus writer of any kind** |
| `.npy` | reader and writer | 🟡 no `.npz` |
| Transparent compression | `.gz` in core | 🟡 `.bz2`, `.xz`, `.zst` refused with a message. FabIO, and so silx, handles bz2 |
| Raw byte location of frames | `BinaryLayout` (offset, nbytes, codec, byte order) | ✅ the key ingredient for external-dataset links. silx has to reconstruct this from FabIO internals |
| h5py tree access | — (users call HDF5.jl directly) | ❌ |
| NeXus tree view of image files (`fabioh5`) | — | ❌ |
| Convert to HDF5 (`convert`, `silx convert`) | — | ❌ |
| `DataUrl` | — | ❌ |
| `NXdata` parse/write | `ext/hdf5/nexus.jl` finds detector metadata only | ❌ |
| dict ↔ HDF5 / NeXus | — | ❌ |
| External-binary / VDS links to image files | — | ❌ |
| SPEC, FIO | — | ❌ |
| 1D save, configdict, octaveh5, JSON/INI dump | — | ❌ |
| HDF5 retry / locking | — | ❌ (partly an HDF5.jl concern) |

## 3. Scope decisions

Not all of silx.io belongs in this package. Three tests decide it: (a) does it follow from
FabIO being underneath? (b) does it need to know about image formats? (c) does the Julia
ecosystem already do it?

### 3.1 Classification

| Item | Decision | Reason |
|---|---|---|
| NeXus tree view of image files (`fabioh5`) | **In scope, core** | This is what silx does *with* FabIO. It needs the registry, headers and series. |
| In-memory tree types (`commonh5`) | **In scope, core, minimal** | The tree view above needs them. Keep them small and HDF5-free, so the view works without `using HDF5`. |
| Convert image / series → HDF5/NeXus (`convert`, `silx convert`) | **In scope, HDF5 extension** | The most-used silx.io feature for beamline image data. |
| `DataUrl`, `get_data` | **In scope, core** | Pure string handling plus dispatch to readers that already exist. |
| External-binary and VDS links to image files (`dictdumplinks`, `rawfile_to_h5_external_dataset`) | **In scope, HDF5 extension** | `BinaryLayout` makes this cleaner here than in silx. |
| `NXdata` parse, `get_default`, `save_NXdata` | **In scope, HDF5 extension** | Needed to write valid NeXus output. Parsing lets the generic HDF5 reader find "the" image by following `@default`. |
| `dicttoh5`/`h5todict`/`dicttonx`/`nxtodict` | **In scope, HDF5 extension, as an internal layer made public** | The writer needs it anyway. `@attr` keys make it a NeXus-shaped dump format. |
| General `open` of arbitrary HDF5 as a tree | **Thin adapter only** | HDF5.jl already *is* the h5py of Julia. Wrap it so that tree functions (`visit`, `match`, `h5ls`) work the same on both kinds of tree. Do not re-export HDF5. |
| `.npz`, bz2/xz/zstd | **In scope, weak-dependency extensions** | FabIO/silx read them transparently. STATUS.md already names the codec extensions. |
| EDF motor/counter/UB parsing | **In scope, core** | Pure header interpretation. Also good for `ImageMetadata`. |
| SPEC (`specfile`, `spech5`) | **In scope, but last and self-contained** | Not an image format and not FabIO. But `silx.io.open` reads it, SPEC and EDF usually come from the same ESRF experiments, and EDF's `motor_mne` convention *is* SPEC's. A pure-Julia parser is about 600 lines. Could be split out to a `SpecFile.jl` later. |
| FIO (`fioh5`) | **In scope, low priority, with SPEC** | Small text format (about 300 lines), same tree shape. |
| `save1D`/`savetxt`/`savespec` | **SPEC writer only, with SPEC** | CSV and text are `DelimitedFiles`/CSV.jl territory. `savespec` belongs with the SPEC reader. |
| `configdict`, `dicttojson`, `dicttoini`, `dump`/`load` | **Out of scope** | TOML, JSON3.jl and IniFile.jl cover it. PyMca `.cfg` is not an X-ray *data* format. |
| `octaveh5` | **Out of scope** | Unrelated to detectors. MAT.jl exists. |
| `h5py_utils` retry, locking, SWMR | **Out of scope as a port; small helper in scope** | Locking and SWMR are HDF5.jl's job. A `retry` keyword on `openimage` for files still being written by a detector is worth keeping (Phase 6). |
| HSDS (`http(s)://` through h5pyd) | **Out of scope** | No Julia HSDS client. Revisit if one appears. |
| `specfilewrapper` (PyMca API) | **Out of scope** | Python compatibility shim. |

### 3.2 The target NeXus layout

This mirrors `silx.io.fabioh5.File` exactly, so files and scripts carry across:

```
/                              @NX_class=NXroot @default=scan_0 @creator @file_time @file_name
└── scan_0                     @NX_class=NXentry @default=image
    ├── instrument             @NX_class=NXinstrument
    │   ├── detector_0         @NX_class=NXdetector
    │   │   ├── data           (nframes, slow, fast) in numpy order; see axis note
    │   │   └── others/        every header key not claimed elsewhere, one per-frame vector each
    │   ├── positioners/       @NX_class=NXpositioner   (EDF motor_mne/motor_pos)
    │   └── file/              @NX_class=NXcollection
    │       └── scan_header    one string per frame, "key: value\n…"
    ├── measurement/           @NX_class=NXcollection   (EDF counter_mne/counter_pos)
    │   └── image_0/{data → detector_0/data, info → detector_0}   (soft links)
    ├── image                  @NX_class=NXdata @signal=data @interpretation=image|spectrum
    │   └── data → ../instrument/detector_0/data
    └── sample                 @NX_class=NXsample (only if UB_mne/sample_mne are present)
        ├── unit_cell_abc, unit_cell_alphabetagamma, unit_cell, ub_matrix
```

**Axis order needs no special handling.** A Julia `(fast, slow, frame)` array written with
HDF5.jl appears to h5py as `(frame, slow, fast)`. That is exactly the shape silx produces. So
`framestack`'s existing order is already the right on-disk order, and files written here will
be byte-identical in layout to silx's output. Reading silx-written files back through
`NexusLike{:hdf5}` works for the same reason.

**Type conversion of header values** follows `FabioReader._convert_value`. A key present in
every frame becomes a typed vector: `Int64` if every value parses as an integer, `Float64` if
every value parses as a number, otherwise strings. Space-separated numeric lists become 2-D.
Missing entries become NaN, `-1` or `""` depending on type. That logic belongs in the core
(`src/nexusview.jl`), not the HDF5 extension. It is a header operation, and doing it in the core
keeps the tree fully usable without HDF5.

## 4. Phased plan

Phase numbering continues from DESIGN.md §17 (Phases 1 to 4 are complete). Each phase ends in
a state that can be released on its own, with tests. Validation follows STATUS.md's rule: the
reference implementation generates the expected values. Here that is `uv run --with silx
--with fabio --with h5py`.

### Phase 5: Foundations — URLs, compression, EDF mnemonics  *(small, core only)*

Everything later depends on this phase. None of it needs HDF5.

1. **`DataUrl`** (`src/url.jl`): an immutable struct with `scheme`, `file_path`, `data_path`,
   `data_slice`. It parses every form in silx's `test_url.py`: `silx:`/`fabio:` schemes,
   `?path=…&slice=…`, the `::` shorthand, `[…]` slices, relative paths, Windows drive letters.
   `string(url)` produces the canonical form, and `isvalid(url)` gives a reason when it is not
   valid. Slices are stored **as written** (0-based, numpy syntax) and converted to Julia
   indices when used, so the URL text stays identical to silx's. Port `test_url.py` as a
   table-driven test.
2. **`getdata(url)`**. For `fabio:`, use `readimage` with `frame = slice + 1`. For `silx:`,
   defer to the Phase 6 tree. With no scheme, try both, as silx does. Until Phase 6 lands,
   `silx:` on a non-HDF5 file raises a clear `UnsupportedFormatError`.
3. **`splitfragment` accepts a trailing `[slice]`**, so `openimage("f.h5::/entry/data[3]")`
   and `readimage` pick the frame. This is backwards compatible.
4. **Compression extensions**: `FabioCodecBzip2Ext`, `FabioCodecXzExt` and
   `FabioCodecZstdExt` as weak dependencies, completing the stub in `src/source.jl:decompress`.
   Also do **detection by magic** (`BZh`, `\x1f\x8b`, `\xfd7zXZ`, `\x28\xb5\x2f\xfd`), which
   STATUS.md "What is next" item 3 already lists.
5. **EDF mnemonic parsing**: `edfmnemonics(hdr, "motor") -> OrderedDict{String,Union{String,Nothing}}`,
   following `EdfFabioReader._get_mnemonic_key` exactly, including the case where one list is
   longer than the other. Also `edfub(hdr) -> (abc, alphabetagamma, ub::Matrix)`.
6. `supported_extensions()` returns `"*.ext"` globs from the registry, as silx does.

*Exit:* all of silx's `test_url.py` cases pass. `getdata("fabio:…::[i]")` agrees with
`silx.io.get_data` on the committed fixtures. bz2 fixtures read.

### Phase 6: The tree model and the NeXus view of image files  *(core; the centrepiece)*

1. **`src/tree.jl`: a minimal, HDF5-free tree.**
   `abstract type TreeNode`, with `Group` (ordered children, `attrs::OrderedDict`), `Dataset`
   (eager array or scalar, plus `attrs`), `LazyDataset` (a closure plus `eltype`/`size`,
   read on first `getindex`) and `SoftLink` (a path).
   - The interface is Julia's, not h5py's: `keys`, `haskey`, `getindex(g, "a/b/c")` with
     absolute and relative paths, `attributes(node)`, `size`/`eltype`/`read` on datasets, and
     `getindex(ds, I...)` for slices that do not load the whole thing.
   - Walking: `visit(f, node)`, `walk` (the `visitall` equivalent), `match(g, "*/detector_*/data")`
     (glob), and `h5ls` / `show(::MIME"text/plain")`.
   - `isfile/isgroup/isdataset/islink` predicates.
   - Around 350 lines. Deliberately **not** `AbstractDict`, so `length` and iteration stay
     unambiguous. Revisit after use.
2. **`src/nexusview.jl`: `nexusview(path_or_file_or_series) -> Group`**, building the layout in
   §3.2.
   - `detector_0/data` is a `LazyDataset` over the open `ImageFile`/`FileSeries`. Taking a
     frame slice reads only that frame (`readframe!`), so viewing a 10,000-frame series costs
     nothing up front.
   - Header typing follows `FabioReader._convert_value`, as described in §3.2.
   - `others`, `positioners`, `measurement` counters and `sample` UB come from the Phase 5
     mnemonic parsing.
   - `interpretation = "spectrum"` for EDF files or series whose header has two or more keys
     starting with `MCA`, as `EdfFabioReader.is_spectrum` decides it (always `image` otherwise).
3. **`opentree(path)`**, the counterpart of `silx.io.open`:
   - an HDF5 file goes to the HDF5 adapter (item 4);
   - an image file or series goes to `nexusview`;
   - `.npy` gives a one-dataset tree;
   - `::/path` returns the sub-node;
   - `::/path[slice]` returns a sliced `LazyDataset`, the counterpart of `DatasetSlice`.
   It is do-block friendly and closes the underlying files.
4. **HDF5 adapter** in `ext/hdf5/tree.jl`: implements the tree interface over
   `HDF5.File`/`Group`/`Dataset` with no copying, so `visit`, `match` and `h5ls` work the same
   on real and virtual trees. Strings are decoded the way `h5py_read_dataset(decode_ascii=true)`
   does it.
5. `getdata("silx:…")` now works for every format.

*Exit:* for every committed fixture, the tree matches silx's `fabioh5.File` on the full set of
paths, attribute names and values, dataset dtypes and shapes, and position-sensitive checksums
of `data`. Build a Python script that dumps a `{path: (attrs, dtype, shape, checksum)}` JSON
from silx, and diff against the same dump from Julia. Include a series and an EDF with
motors, counters and UB (hand-made fixture, cross-checked through silx).

### Phase 7: HDF5/NeXus writing — `convert` and `dicttoh5`  *(HDF5 extension)*

1. **`writetree(h5file_or_path, tree; path="/", mode, link=:soft|:hard, overwrite=false, compress=…, chunk=…)`**
   is the counterpart of `write_to_h5`. It walks any `TreeNode` or HDF5 adapter node and
   writes groups, datasets, attributes and links. Strings go out as variable-length UTF-8, as
   in silx's `_attr_utf8`. `LazyDataset`s are written **frame by frame into a chunked dataset**
   (chunk = one frame), so converting a large series never holds the stack in memory. The
   `min_size` threshold for applying compression follows silx.
2. **`convert(infile_or_series, h5path; mode="w-", kwargs...)`** is `writetree(nexusview(infile))`.
   It is also reachable through `writeimage(path.h5, frame)` / `convertimage`, which adds
   **`NexusLike` as the 16th writable format**. `layoutkeys` is extended so the header
   translation stays consistent.
3. **Dict ↔ HDF5**: `dicttoh5(dict, file; path, mode, update=:add|:modify|:replace)` and
   `h5todict(file; path, exclude, attributes=false, dereference=true)`. `dicttonx`/`nxtodict`
   use silx's key syntax: `"@attr"`, `"dataset@attr"`, `">link"`. These sit on the tree layer
   (a `Dict` converts to a tree), so there is only one writer.
4. **`save_nxdata(file, path; signal, axes, errors, title, interpretation, …)`** follows
   `nxdata.save_NXdata`, and `nexusview` uses it for `scan_0/image`.
5. **CLI**: `fabio-convert --format hdf5` and a series-to-one-HDF5 mode (the `silx convert`
   case: `fabio-convert 'img_####.edf' -o scan.h5`). Existing options and exit codes are kept.

*Exit:* `h5diff`-level agreement with `silx convert` output for the Phase 6 fixtures (ignoring
`file_time`/`creator`). silx can read back what this package writes. The `dicttoh5`/`h5todict`
round-trip cases from silx's `test_dictdump.py` pass.

### Phase 8: Zero-copy linking — external datasets and VDS  *(HDF5 extension)*

This is where the architecture pays off. `BinaryLayout` already knows the byte offset, size,
element type and byte order of every uncompressed frame.

1. **`externallink(h5, path, source_or_series)`**: for formats whose frames use `RawBlob`
   (EDF, uncompressed TIFF, SPE, GE, raw Bruker, npy, MRC, Fit2D and others), write an HDF5
   dataset whose `external` storage lists `(file, offset, nbytes)` for each frame. The result
   is a `(fast, slow, nframes)` dataset that **copies no pixels**. The equivalent of
   `dictdumplinks._parse_fabio_targets` and `_parse_tiff_targets`. Mixed byte order across
   files, or a compressed codec, gives a clear error suggesting `convert`.
2. **`rawexternal(h5, path, binfile; dims, eltype, offset=0)`** and
   **`volexternal(h5, path, volfile; info=volfile*".info")`**, the equivalents of the two silx
   utilities.
3. **Virtual datasets**: `virtualstack(h5, path, sources::Vector{DataUrl})` stacks HDF5 sources
   (for example, per-file Eiger data) into one VDS, with silx's stacking rule: stack when
   ndim < 3, concatenate when ndim ≥ 3. This also closes the open STATUS.md question: VDS
   *reading* is still unproven. Writing VDS fixtures here gives the test that has been missing.
4. **`externalinfo(dataset)`**, the equivalent of `h5link_utils.external_dataset_info`.
5. Round-trip serialisation of these links in `h5todict`/`dicttoh5`, matching the
   `dictdumplinks` schemas, so a dict dump can describe them.

*Exit:* for each raw-codec format, reading the linked dataset through HDF5.jl **and through
h5py** equals the frames `readimage` returns, checked by position-sensitive checksum. VDS
written here reads correctly in h5py, and in `NexusLike{:eiger}` when the layout matches.

### Phase 9: NXdata reading and default-plot resolution  *(HDF5 extension)*

1. **`NXdata(group)`** parses `@signal`, `@axes` (including `"."`), `@AXISNAME_indices`,
   `errors`/`*_errors`, `@auxiliary_signals`, `@interpretation`, `@title`, and the
   `@SILX_style` scale types. It also provides `isvalid_nxdata(group)` with an
   `invalid_reason`, following `nxdata/parse.py`, and the classifications `iscurve`,
   `isimage`, `isstack`, `isvolume` and `isscatter`.
2. **`default_nxdata(file_or_group)`** follows `@default` down from `NXroot` and `NXentry` to an
   `NXdata`. This is the equivalent of `get_default`.
3. **Use it for image detection**: when `NexusLike{:hdf5}` meets a NeXus file, it opens the
   default `NXdata` signal *before* falling back to the "first ≥2-D numeric dataset"
   heuristic. That makes plain `readimage("anything.nxs")` return the dataset its author
   declared as the image.

*Exit:* the valid and invalid cases in silx's `test_nxdata.py` classify the same way.

### Phase 10: Non-image scan formats — SPEC and FIO  *(core, self-contained, optional)*

1. **SPEC reader** (`src/spec/`): file header (`#F #E #D #O #o #C`), scans (`#S #D #T/#M #G
   #Q #P #N #L`), data blocks, `@A`/`#@MCA` MCA spectra, and multiple scans with the same
   number (`"94.1"`/`"94.2"` keys, as in silx). It is lazy by scan: one pass indexes byte
   offsets, and scans parse on demand. Values are validated against silx's C `SpecFile`
   (`list`, `labels`, `motor_names`, `motor_positions`, `data`, `mca`).
2. **`specview(path)`** builds the `spech5` tree. `/<n>.<k>/title`, `start_time` (ISO 8601
   through `spec_date_to_iso8601`), `instrument/{specfile,positioners,mca_*}`,
   `measurement/…` and `sample/{ub_matrix,unit_cell…}` match `spech5`. With that, `opentree`,
   `getdata` and `convert` work on SPEC for free.
3. **`savespec(path, x, ys; labels, scan, command)`**, the SPEC half of `save1D`.
4. **FIO reader and `fioview`**: `%c` comments, `%p` parameters, `%d` column definitions and
   data, laid out as `fioh5` does it.

*Exit:* `h5diff` agreement between `convert(spec)` here and `silx convert` on silx's own test
SPEC strings (which are embedded in `test_specfile.py` and `test_spech5.py`, so no external data
is needed).

### Phase 11: Leftovers and polish

- **`.npz`** through a `ZipArchives.jl` weak dependency, readable by `openimage` (one frame
  set per array) and by `opentree` (one dataset per array), matching `rawh5.NumpyFile`.
- **`retry` keyword on `openimage`/`opentree`** for files that are still being written:
  retry on `CorruptFileError` or an HDF5 read error, with a timeout and back-off, for
  beamline pipelines that poll a detector's output. This is the useful part of `h5py_utils`,
  without the locking machinery.
- **Documenter pages**: "Coming from silx.io", a side-by-side table in the style of README's
  FabIO table, and a tutorial matching silx's `convert.rst`.
- **FileIO**: register `.h5`/`.nxs` saving through `convert` once Phase 7 exists.

## 5. Dependencies and risks

| Risk | Mitigation |
|---|---|
| The tree API grows into a second HDF5.jl | Keep it read-mostly and small. The adapter wraps HDF5.jl instead of copying it. Whatever the writer and `nexusview` don't need stays out. |
| The silx layout changes upstream | Pin the silx version in the comparison script, as STATUS.md pins FabIO 2026.6.0. Diff silx `fabioh5.py`/`spech5.py` at each bump. |
| External datasets are relative-path sensitive | Store paths relative to the HDF5 file, as silx's `normalize_ext_source_path` does. Test by moving the directory. |
| Header typing differs subtly from numpy's promotion | Generate the expected dtypes from silx, never by hand (STATUS.md process note). |
| SPEC scope creep (PyMca compatibility, `specfilewrapper`) | Keep it out of scope explicitly. Match `SpecFile`/`spech5` only. |

## 6. Suggested order and size

| Phase | Depends on | Rough size | Value |
|---|---|---|---|
| 5 Foundations | — | ~600 lines | Medium. Unblocks everything, and closes two STATUS.md items |
| 6 Tree + `nexusview` | 5 | ~1000 lines | **High**. The core silx concept |
| 7 HDF5 writing / `convert` | 6 | ~800 lines | **High**. The most-requested feature for image data |
| 8 External / VDS | 7 | ~500 lines | High for large datasets. Unique leverage from `BinaryLayout` |
| 9 NXdata read | 6 (adapter) | ~500 lines | Medium |
| 10 SPEC / FIO | 6, 7 | ~1200 lines | Medium, and only for users with SPEC data |
| 11 Polish | various | ~400 lines | Low to medium |

Phases 8 and 9 are independent of each other and can run in parallel after 7 (9 needs only
the Phase 6 adapter). Phase 10 can start any time after Phase 6.
