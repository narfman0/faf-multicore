import pefile, struct, sys
EXE="/home/narfman0/.openclaw/workspace/faf/supcom_run/bin/ForgedAlliance_faf.exe"
pe=pefile.PE(EXE, fast_load=True)
base=pe.OPTIONAL_HEADER.ImageBase
# build a flat image: map VA->byte via sections; and a list of (va_start, data)
secs=[]
text_lo=text_hi=None
for s in pe.sections:
    va=base+s.VirtualAddress
    data=s.get_data()
    secs.append((va, data, s.Name.rstrip(b'\0').decode('latin1'), s.Characteristics))
    if b'.text' in s.Name:
        text_lo, text_hi = va, va+s.Misc_VirtualSize
print(f"imagebase=0x{base:x} .text=[0x{text_lo:x},0x{text_hi:x}]")

def find_str_va(name):
    tgt=(name+"\0").encode()
    out=[]
    for va,data,nm,ch in secs:
        i=data.find(tgt)
        while i>=0:
            out.append(va+i); i=data.find(tgt,i+1)
    return out

def read_dwords_at_va(va, count, before=1):
    for vstart,data,nm,ch in secs:
        if vstart<=va<vstart+len(data):
            off=va-vstart
            res=[]
            for k in range(-before, count):
                p=off+k*4
                if 0<=p<=len(data)-4:
                    res.append((va+k*4, struct.unpack('<I', data[p:p+4])[0]))
            return res
    return []

def scan_refs(target_va):
    key=struct.pack('<I', target_va)
    hits=[]
    for vstart,data,nm,ch in secs:
        i=data.find(key)
        while i>=0:
            hits.append((vstart+i, nm)); i=data.find(key,i+1)
    return hits

def in_text(v): return text_lo<=v<text_hi

for name in ["GetThreatAtPosition","CanBuildStructureAt","CanPathTo"]:
    print(f"\n==== {name} ====")
    for sva in find_str_va(name):
        print(f" string @ 0x{sva:x}")
        for refva, secn in scan_refs(sva):
            # look at neighbors of the reference for a code pointer (the C func)
            near=read_dwords_at_va(refva, 3, before=1)
            cand=[f"0x{v:x}" for (a,v) in near if in_text(v)]
            print(f"   ref @ 0x{refva:x} ({secn})  nearby-codeptrs: {cand}")
