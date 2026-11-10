#!/usr/bin/env bash
set -euo pipefail
lab=$(cd -- "$(dirname -- "$0")" && pwd)
work=$1
version=$2
mkdir -p "$work/root"/{bin,dev,proc,sys,modules}
cp /bin/busybox "$work/root/bin/busybox"
for applet in sh mount insmod stty sleep mkswap swapon mkdir poweroff; do
    ln -s busybox "$work/root/bin/$applet"
done
install -m 755 "$lab/init" "$work/root/init"
cc -O2 -Wall -Wextra -Werror -static "$lab/probe.c" -o "$work/root/probe"
sudo mknod "$work/root/dev/console" c 5 1
printf 'set -eu\n' > "$work/root/load-modules"
for driver in virtio_pci virtio_blk; do
    modprobe --show-depends --set-version "$version" "$driver"
done > "$work/dependencies"
while read -r action module rest; do
    [[ $action == insmod ]] || continue
    name=$(basename "$module" | sed -E 's/\.(zst|xz|gz)$//')
    target="$work/root/modules/$name"
    [[ ! -f $target ]] || continue
    case $module in
        *.zst) zstd -dc -- "$module" > "$target" ;;
        *.xz) xz -dc -- "$module" > "$target" ;;
        *.gz) gzip -dc -- "$module" > "$target" ;;
        *) cp -- "$module" "$target" ;;
    esac
    printf 'insmod /modules/%s\n' "$name" >> "$work/root/load-modules"
done < "$work/dependencies"
(cd "$work/root" && find . -print0 | cpio --quiet -0 -o -H newc) | gzip > "$work/initrd.gz"
