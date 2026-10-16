"""Verify native PE64 import directories and report code/overlay sizes."""
import hashlib
import json
import struct
import sys
from pathlib import Path

p = Path(sys.argv[1])
b = p.read_bytes()
def u16(o): return struct.unpack_from("<H", b, o)[0]
def u32(o): return struct.unpack_from("<I", b, o)[0]
pe = u32(60)
assert b[pe:pe+4] == b"PE\0\0", "Not a PE image"
opt = pe + 24
assert u16(pe+4) == 0x8664 and u16(opt) == 0x20b, "Not x64 PE32+"
assert u32(opt+108) >= 14, "Missing import directory entries"
directories = {}
for name, index in (("import",1),("bound_import",11),("iat",12),("delay_import",13)):
    address, size = struct.unpack_from("<II", b, opt+112+index*8)
    directories[name] = {"rva":address,"size":size}
sections = []
table = opt + u16(pe+20)
raw_end = u32(opt+60)
for i in range(u16(pe+6)):
    s = table+i*40
    name = b[s:s+8].split(b"\0",1)[0].decode("ascii")
    virtual, rva, raw, offset = struct.unpack_from("<IIII",b,s+8)
    sections.append({"name":name,"virtual_bytes":virtual,"raw_bytes":raw,"raw_offset":offset})
    raw_end=max(raw_end,offset+raw)
report={"path":str(p.resolve()),"bytes":len(b),"sha256":hashlib.sha256(b).hexdigest(),
        "directories":directories,"sections":sections,"overlay_bytes":len(b)-raw_end,
        "import_free":all(v==0 for item in directories.values() for v in item.values())}
print(json.dumps(report,indent=2))
sys.exit(0 if report["import_free"] and report["overlay_bytes"] == 0 else 1)
