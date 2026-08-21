# Performance

Measured on an 8-thread machine, against FabIO on the same files.

Decoding one 2048² AGI bitfield frame (Esperanto):

| | per frame |
|---|---|
| FabIO — its AGI decoder is pure Python; the Cython extension only covers compression | 793 ms |
| Fabio.jl, sequential | 9.7 ms |
| Fabio.jl, row-indexed across 8 threads | 1.2 ms |

Reading one 2300² PCK frame (mar345), end to end:

| | per frame |
|---|---|
| FabIO, with its Cython PCK decoder | 612 ms |
| Fabio.jl | 38 ms |

The PCK comparison is the fairer of the two, since here FabIO is compiled rather than
interpreted.

The threaded path uses the per-row offset table stored at the end of every AGI blob. FabIO
reads that table and discards it (`# read data components (row indices are ignored)`), which
forces its decoder to walk rows strictly in order. Keeping it also lets each row's start be
validated before use, and makes region-of-interest reads possible without decoding the whole
frame.

A full pass over 140 real files (2048², ~3.2 MB each) takes **0.99 s**.
