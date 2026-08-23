# Defects found in FabIO along the way

Recorded because they affect anyone using FabIO for these formats, and because several of them
are why a comparison had to be done indirectly.

- **MRC header fields.** FabIO reads all 56 header words as `Int32` and names only the first
  thirty, so the cell dimensions, density statistics and origin are meaningless and the `MAP`
  stamp is looked for at word 27 instead of word 53. Its own check that `MAP` reads back as
  `"MAP "` therefore never succeeds; it logs at info level and continues. This reader follows
  MRC2014, which the files confirm: `DMIN`, `DMAX` and `DMEAN` are stored statistics of the
  pixel data and agree with it to full float precision, and the cell angles read exactly 90°.
- **MRC frame access.** `get_frame(n)` and `getframe(n)` raise `AttributeError` for any frame,
  because both copy the deprecated `dim1` attribute onto a frame whose `data` is still `None`.
  Only `fabio.open(path, frame=n)` works.
- **MRC labels.** The ten 80-character labels are decoded as strict UTF-8, so two of the ten
  EMDB files tested cannot be opened at all. This reader maps bytes to codepoints.
- **MarCCD header.** `fabio.open` never exposes it. `TifImage.read` calls
  `MarccdImage._readheader`, which parses the 3072-byte struct into `self.header`, and then
  `_read_with_tiffio` overwrites `self.header` with the TIFF tags. Reaching the fields requires
  calling `marccdimage.interpret_header` directly.
- **Xcalibur cannot read anything.** `XcaliburImage.read` is the unmodified
  `templateimage.py` boilerplate: it ignores the file, builds a 50×60 array and then raises
  `AttributeError`, since the template's `self.uint16` is not an attribute. The struct
  definitions and `CcdCharacteristiscs.loads` beside it are complete and correct — nothing
  ever connected them to the reader.
- **Fit2D reals.** `hex_to(stg, "float")` never looks at `stg`; it returns a hardcoded constant
  of about 1e-4, so every real-valued field in every `.f2d` file reads back as the same number.
- **Fit2D block size.** For files not written in 512-byte blocks, the larger size is worked out
  and the file seeks back to the start, but the stale block already read is then parsed instead
  of the scan resuming.
- **Fit2D byte order.** `i` and `r` arrays are decoded in the machine's native order while `l`
  masks are decoded big-endian, in the same function, so the same file gives different pixels on
  different machines. Real files show little-endian is right for the arrays, which is what this
  package now does; on a big-endian machine FabIO would misread them.
- **Netpbm subformats.** In practice only P5 is readable: a plain P2 raises "Size spec in
  pnm-header does not match size of image data", a packed P4 raises `ValueError` from parsing
  binary as an integer, and a plain P1 raises "could not figure out what kind of pixels you
  have". All three are read here.
- **SPE frame count.** `SpeImage` never sets `_nframes`, so a two-frame file reports
  `nframes = 1` while its own header says `num_frames = 2`. Both frames are readable through
  `fabio.open(path, frame=n)`.
- **The older Eiger layout cannot be opened.** `EigerImage.read` collects the `/entry/data_01`,
  `data_02`, … datasets of the elder layout and then ends with
  `self._data = self.dataset[0][self.currentframe, :, :]` — three indices into a 2-D dataset —
  so `fabio.open` raises `ValueError: 3 indexing arguments for 2 dimensions` on exactly the
  files that code path exists to serve. Only `fabio.open(path, frame=n)` works, which is the
  same shape of defect as the MRC one above.
- **HDF5 detection assumes variable-length string attributes.** `_do_magic` decides the family
  with `str(creator).startswith("LIMA")`; when `creator` is stored as a *fixed-length* string
  h5py hands back `bytes`, `str()` of which is `"b'LIMA…'"`, so the test fails and the file is
  misdetected as Eiger. The Lambda branch of the same function decodes explicitly before
  comparing and is unaffected — the fix is applied in one branch and not the others.
- **The LImA reader breaks on those attributes too.** `LimaImage._readheader` calls
  `nxdata.split("/")` on the entry's `default` attribute, raising
  `TypeError: a bytes-like object is required, not 'str'` when it is fixed-length. Such a file
  cannot be read even with the format forced, rather than merely being misdetected.
- **The two densify implementations disagree.** For a sparsified frame, the Cython extension
  fills masked pixels with the dummy and writes the peak list afterwards, so a peak recorded at
  a masked pixel survives; the pure-numpy fallback writes the peaks first and then overwrites
  them with the dummy, losing it. The same file gives different pixels depending on whether
  FabIO's C extension was built. This package follows the Cython order, that being what a
  normal install runs.
- **densify has a dead no-background branch.** `if radius is None or background is None:
  mean_2d = numpy.zeros(radius.shape, ...)` reads `radius.shape` in the branch entered when
  `radius is None`, so a sparse file carrying no radial background raises
  `AttributeError: 'NoneType' object has no attribute 'shape'`. The Cython path handles the
  same file, but returns 0 rather than the dummy for masked pixels; this reader applies the
  dummy consistently, which is what `dummy` is for.
- **`previous_filename` counts below zero.** `previous_filename("img_0000.edf")` returns
  `img_-001.edf`: the number is decremented to −1 and then padded into the same four columns,
  sign included. No such file can exist, so the error is deferred to whatever tries to open it.
  This package throws instead, saying that there is nothing before the first file.
- **`convert` carries the source's layout description into the target.** `converters.py` says of
  itself that it "is for the moment empty (populated only with almost pass through anonymous
  functions)", and its header table holds exactly one entry — EDF to EDF, the identity. So
  converting an EDF to a CBF carries `Dim_1`, `Dim_2`, `DataType`, `ByteOrder` and `Size` into
  the CBF, where they describe nothing: checked, and all five arrive. It is misleading rather
  than corrupting — each format's writer regenerates its own — which is why this package strips
  them by `layoutkeys` instead.
- **A single-frame EDF cannot be opened by frame number.** `fabio.open("one.edf", frame=0)`
  raises `FileNotFoundError: 'one0000.edf'`: with only one frame in the file, the frame request
  falls through to the filename arithmetic and goes looking for a *file* number zero. Plain
  `fabio.open("one.edf")` works, and a single-frame CBF accepts `frame=0` without complaint, so
  this is EDF's frame handling rather than a general rule. It matters when iterating a mixed
  set of files by frame index, which is the natural way to write such a loop.
