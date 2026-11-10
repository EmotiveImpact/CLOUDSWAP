#!/usr/bin/env python3
"""Generate source anchors for review, not a proof of runtime support."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('checkout', type=Path)
a = p.parse_args()
targets = {
 'bsd/kern/kern_sysctl.c': ['SYSCTL_STRING(_vm, OID_AUTO, swapfileprefix'],
 'bsd/kern/kern_newsysctl.c': ['if (from_kernel && !(oid->oid_kind & CTLFLAG_KERN))', 'error = mac_system_check_sysctlbyname'],
 'bsd/sys/sysctl.h': ['#define CTLFLAG_KERN'],
 'bsd/vm/dp_backing_file.c': ['macx_swapon(', 'macx_swapoff('],
 'bsd/vm/vm_compressor_backing_file.c': ['vm_swapfile_open(const char *path, vnode_t *vp)', 'mnt_kern_flag & MNTK_NOSWAP', 'vm_swapfile_io(vnode_t vp', 'vnode_pagein(vp', 'vnode_pageout(vp'],
 'osfmk/vm/vm_compressor_backing_store.c': ['swapfilename[MAX_SWAPFILENAME_LEN', 'snprintf(swf->swp_path', 'vm_swap_get(c_segment_t', 'vm_swap_put(vm_offset_t'],
}
anchors = []
for path, needles in targets.items():
    raw = (a.checkout / path).read_bytes()
    lines = raw.decode().splitlines()
    for needle in needles:
        hits = [i for i, line in enumerate(lines, 1) if needle in line]
        anchors.append({'file': path, 'file_sha256': hashlib.sha256(raw).hexdigest(),
                        'search': needle, 'lines': hits, 'state': 'found' if hits else 'missing'})
commit = subprocess.check_output(['git', '-C', str(a.checkout), 'rev-parse', 'HEAD'], text=True).strip()
print(json.dumps({'commit': commit, 'kind': 'source_anchors_not_runtime_validation', 'anchors': anchors}, indent=2))
if any(x['state'] == 'missing' for x in anchors):
    raise SystemExit(1)
