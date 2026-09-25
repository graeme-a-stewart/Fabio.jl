"""Regenerate test/silx_url_cases.jl and test/numpy_slice_cases.jl from silx and numpy.

The expected values in those files come from the reference implementation, never from
typing them in (see STATUS.md). Run from the repository root with silx and numpy available:

    uv run --with silx --with numpy python3 test/generate_silx_cases.py

silx's `url.py` needs nothing beyond the standard library, so any silx version whose
`DataUrl` should be matched will do. The header of each generated file records which one.
"""
import logging
import os

import numpy as np
import silx
from silx.io.url import DataUrl

logging.disable(logging.CRITICAL)
HERE = os.path.dirname(os.path.abspath(__file__))

cases = [
 "fabio:///data/image.edf?slice=2", "fabio:///C:/data/image.edf?slice=2",
 "silx:///data/image.h5?path=/data/dataset&slice=1,5", "silx:///data/image.h5::path=/data/dataset&slice=1,5",
 "silx:///data/image.edf?/scan_0/detector/data", "silx:///C:/data/image.h5?/scan_0/detector/data",
 "silx:./image.h5", "fabio:./image.edf", "silx:image.h5", "fabio:image.edf", "image.edf",
 "./foo/bar/image.edf", "foo/bar/image.edf", "/data/image.edf", "C:/data/image.edf",
 "/foo/foobar.h5?/foo/bar", "C:/foo/foobar.h5?path=/foo/bar&slice=5,1",
 "silx:/foo/foobar.h5?path=/foo/bar&slice=5,1", "silx:C:/foo/foobar.h5?path=/foo/bar&slice=5,1",
 "", "foo:/foo/foobar.h5?path=/foo/bar&slice=5,1", "/a.h5?path=/b&slice=5,1", "/a.h5?path=/b&slice=2:5",
 "/a.h5?path=/b&slice=::2", "/a.h5?path=/b&slice=...", "/a.h5?path=/b&slice=:", "/a.h5?path=/b&slice=5,,1",
 "/a.h5?path=/b&slice=", "http://hsds-server.tld/home/file", "http://hsds-server.tld:8080/home/file",
 "http://hsds-server.tld/home/file?/foo/bar", "silx://my_file.hdf5?path=/path/to/data&slice=not_a_slice",
 # extra edge cases
 "/data/scan.h5::/entry/data", "fabio:/users/foo/image.edf::[0]", "silx:/a.h5::/b/c", "/a.h5?path=/b&slice=-1,::-1,1:-2:3",
 "/a.h5?slice=3", "silx:/a.h5?slice=3", "fabio:/a.edf?path=/x", "fabio:/a.edf?slice=1,2",
 "/a.h5?path=/b%20c&slice=+2", "/a.h5?path=/b+c", "/a.h5?path=/x&path=/y", "/a.h5?path=/x&foo=1",
 "SILX:/a.h5?/b", "d:/a.edf", "file:/a.edf", "relative.h5::/entry", "/a.h5?slice= 3 ,1_0",
 "/a.h5?path=/b&slice=1:2:3:4", "/a.h5?path=/b&slice=1:x", "silx:///a.h5?path=/b&slice=..., 0",
 "/a.h5??/b", "/a b.h5::/c d",
 "//host?x", "//server/share/x.h5::/e", "/\u00e9:x.h5?/a", "silx:///\u00e9/x.h5?/b", "\u00e9.h5::/d",
 "silx:\u00e9:/x", "?/b", "::/b", "C:/x::/y",
]
def enc(s):
    if s is None: return None
    out=[]
    for x in s:
        if x is Ellipsis: out.append(["..."])
        elif isinstance(x, slice): out.append([x.start, x.stop, x.step])
        else: out.append(x)
    return out
res=[]
for c in cases:
    u=DataUrl(c)
    res.append(dict(text=c, valid=u.is_valid(), absolute=u.is_absolute(), scheme=u.scheme(), file_path=u.file_path(),
        data_path=u.data_path(), data_slice=enc(u.data_slice()), reason=u.invalid_reason))
built=[]
for (fp,dp,sl,sc) in [("./foo.h5","/",(5,1),"silx"),("/foo.h5","/",(5,1),"silx"),("C:/foo.h5","/",(5,1),"silx"),
   ("/foo.h5","/",(5,1,Ellipsis,slice(None)),"silx"),("/foo.h5",None,1,"silx"),("/foo.h5",None,(1,),"silx"),
   ("/foo.h5",None,slice(None),"silx"),("/foo.h5",None,slice(1,None),"silx"),("/foo.h5",None,slice(None,-2),"silx"),
   ("/foo.h5",None,slice(1,None,3),"silx"),("/foo.h5",None,slice(None,2,3),"silx"),("/foo.h5",None,slice(None,None,3),"silx"),
   ("/foo.h5",None,slice(1,2,3),"silx"),("/foo.h5",None,(1,slice(1,2)),"silx"),("rel.edf",None,(2,),"fabio"),
   ("/a.h5","/entry",None,None),("/a.h5",None,None,None),("/a.h5","/entry",(0,),None)]:
    u=DataUrl(file_path=fp,data_path=dp,data_slice=sl,scheme=sc)
    s = sl if isinstance(sl, tuple) or sl is None else (sl,)
    built.append(dict(file_path=fp,data_path=dp,data_slice=enc(s),scheme=sc,path=u.path(),valid=u.is_valid(),reason=u.invalid_reason))

def jstr(s):
    if s is None:
        return "nothing"
    import json
    return json.dumps(s).replace("$", "\\$")


def jslice(s):
    if s is None:
        return "nothing"
    out = []
    for x in s:
        if x == ["..."]:
            out.append("SliceEllipsis()")
        elif isinstance(x, list):
            out.append("SliceRange(%s)" % ", ".join("nothing" if v is None else str(v) for v in x))
        else:
            out.append(str(x))
    return "(" + ", ".join(out) + ("," if len(out) == 1 else "") + ")"


lines = [
    "# Generated from silx %s's `silx.io.url.DataUrl` by test/generate_silx_cases.py, which runs" % silx.version,
    "# each string through it and records what it reports. Do not edit by hand: regenerate instead.",
    "# Fields: text, valid, absolute, scheme, file_path, data_path, data_slice, invalid_reason.",
    "const SILX_PARSED_URLS = [",
]
for r in res:
    lines.append("    (%s, %s, %s, %s, %s, %s, %s, %s)," % (
        jstr(r["text"]), str(r["valid"]).lower(), str(r["absolute"]).lower(), jstr(r["scheme"]),
        jstr(r["file_path"]), jstr(r["data_path"]), jslice(r["data_slice"]), jstr(r["reason"])))
lines += [
    "]",
    "",
    "# DataUrl built from parts, and the text silx's `DataUrl.path()` gives for it.",
    "# Fields: file_path, data_path, data_slice, scheme, path, valid, invalid_reason.",
    "const SILX_BUILT_URLS = [",
]
for r in built:
    lines.append("    (%s, %s, %s, %s, %s, %s, %s)," % (
        jstr(r["file_path"]), jstr(r["data_path"]), jslice(r["data_slice"]), jstr(r["scheme"]),
        jstr(r["path"]), str(r["valid"]).lower(), jstr(r["reason"])))
lines.append("]")
with open(os.path.join(HERE, "silx_url_cases.jl"), "w") as f:
    f.write("\n".join(lines) + "\n")

a = np.arange(60).reshape(3, 4, 5)
texts = ["0", "2", "-1", "1,2", "1,2,3", "-1,-1,-1", ":", "...", "1:", ":2", "::2", "::-1", "-2:", "1:-1",
         "5:1:-1", "::-2", "10:", "-10:", "0:0", "3:1", "...,0", "...,::-1", "0,...", "1,...,2", ":,1", ":,:,4",
         "::-1,::-1,::-1", "1:3,::2,-3:", "0,:,2:100", "-3", "2,-4,::3", "1:1:-1", ":-100", "-100:100:7"]
rows = []
for t in texts:
    r = a[DataUrl("/a.h5?path=/d&slice=" + t).data_slice()]
    rows.append((t, list(np.shape(r)), [int(x) for x in np.ravel(r)]))
out = [
    "# numpy %s's answer for each URL slice on `np.arange(60).reshape(3, 4, 5)`, generated by" % np.__version__,
    "# test/generate_silx_cases.py: the slice is parsed by silx's `DataUrl` and applied by numpy.",
    "# Fields: slice text, numpy shape, values in C order. Do not edit by hand: regenerate instead.",
    "const NUMPY_SLICES = [",
]
for t, s, v in rows:
    out.append('    ("%s", (%s), [%s]),' % (t, ", ".join(map(str, s)) + ("," if len(s) == 1 else ""), ", ".join(map(str, v))))
out.append("]")
with open(os.path.join(HERE, "numpy_slice_cases.jl"), "w") as f:
    f.write("\n".join(out) + "\n")
print(len(res), "parsed,", len(built), "built,", len(rows), "slices")
