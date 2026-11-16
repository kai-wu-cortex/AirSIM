#!/usr/bin/env python3
"""Prepare, never flash, an update for one verified MU3356 B28 base image.

The base includes a device owner's ADB public key. Neither base nor output belongs
in Git or a public release. Uses the MIT-licensed cpio/lz4 helpers from
https://github.com/joker-skills/f50pro-MacOS-tools/blob/main/bin/repack-init-boot.py.
"""
import argparse, hashlib, importlib.util, json, pathlib, struct
BASE_SHA256 = 'b37096de03d28c8cca7cfcb2588a7f2a5ebb013c20db6c6769d2370c9f58374c'
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--base',type=pathlib.Path,required=True)
p.add_argument('--repack-tool',type=pathlib.Path,required=True)
p.add_argument('--out',type=pathlib.Path,required=True)
a=p.parse_args()
assert not a.out.exists(), 'refusing to overwrite output'
img=a.base.read_bytes();assert hashlib.sha256(img).hexdigest()==BASE_SHA256, 'unrecognized base; do not flash'
assert img[:8]==b'ANDROID!' and struct.unpack_from('<I',img,8)[0]==0 and struct.unpack_from('<I',img,40)[0]==4
spec=importlib.util.spec_from_file_location('repack',a.repack_tool);repack=importlib.util.module_from_spec(spec);spec.loader.exec_module(repack)
size=struct.unpack_from('<I',img,12)[0]
original=repack.cpio_parse(repack.lz4_decompress(img[4096:4096+size]))
entries=[dict(e) for e in original];by_name={e['name'].decode():e for e in entries}
root=pathlib.Path(__file__).resolve().parent
changes={
 'overlay.d/codex-f50-wifi-autostart.rc':root/'boot/codex-f50-wifi-autostart.rc',
 'overlay.d/sbin/codex-f50-wifi-autostart.sh':root/'boot/codex-f50-wifi-autostart.sh',
 'overlay.d/sbin/codex-f50-wlan-bridge.sh':root/'boot/codex-f50-wlan-bridge.sh',
}
for name,path in changes.items():
 assert name in by_name
 by_name[name]['data']=path.read_bytes()
name='overlay.d/sbin/f50-wifi.dex';assert name not in by_name
entries.append(dict(name=name.encode(),mode=0o100644,uid=0,gid=0,data=(root/'build/f50-wifi.dex').read_bytes(),rmaj=0,rmin=0))
rd=repack.lz4_compress(repack.cpio_build(entries));new_end=repack.page_end(len(rd))
footer=img[-64:];assert footer[:4]==b'AVBf'
_,_,orig_size,vb_off,vb_size=struct.unpack('>IIQQQ',footer[4:36]);assert img[vb_off:vb_off+4]==b'AVB0'
new_vb=max(vb_off,new_end);assert new_vb+vb_size<=len(img)-64
out=bytearray(len(img));out[:4096]=img[:4096];struct.pack_into('<I',out,12,len(rd));out[4096:4096+len(rd)]=rd
out[new_vb:new_vb+vb_size]=img[vb_off:vb_off+vb_size];out[-64:]=footer
struct.pack_into('>QQQ',out,len(out)-64+12,new_end if orig_size==repack.page_end(size) else orig_size,new_vb,vb_size)
# Compare every original entry including USB ADB, original ifconfig, netd guard,
# framework patch, Magisk and owner public key. Only the explicit set may differ.
checked={e['name'].decode():e for e in repack.cpio_parse(repack.lz4_decompress(bytes(out[4096:4096+len(rd)])))}
for e in original:
 n=e['name'].decode()
 if n not in changes:assert checked[n]==e, 'unexpected change: '+n
 else:
  assert checked[n]['data']==changes[n].read_bytes()
  assert {k:v for k,v in checked[n].items() if k!='data'}=={k:v for k,v in e.items() if k!='data'}
assert set(checked)=={e['name'].decode() for e in original}|{name}
assert len(out)==len(img) and out[new_vb:new_vb+vb_size]==img[vb_off:vb_off+vb_size]
a.out.write_bytes(out);a.out.chmod(0o600)
report=dict(base_sha256=BASE_SHA256,output_sha256=hashlib.sha256(out).hexdigest(),bytes=len(out),changed=list(changes),added=[name],unchanged_entries=len(original)-len(changes),usb_adb_entries_unchanged=True,vbmeta_blob_unchanged=True)
a.out.with_suffix('.manifest.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
