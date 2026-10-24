#!/bin/sh
# Mirror Android ueventd-created input/USB nodes into the Droidspaces devtmpfs.
# Droidspaces mirrors GPU nodes but not /dev/input/event* or /dev/bus/usb/*,
# so udev only creates dangling symlinks. This creates the missing character
# nodes from sysfs when hardware access is enabled.
set -eu

[ -d /sys/class/input ] || exit 0
install -d -m 0755 /dev/input

for sys in /sys/class/input/event*; do
    [ -r "$sys/dev" ] || continue
    name=${sys##*/}
    node="/dev/input/$name"
    [ -e "$node" ] && continue
    mm=$(cat "$sys/dev" 2>/dev/null) || continue
    major=${mm%%:*}
    minor=${mm##*:}
    [ -n "$major" ] && [ -n "$minor" ] || continue
    mknod "$node" c "$major" "$minor" 2>/dev/null || continue
    chmod 660 "$node" 2>/dev/null || true
    chown root:input "$node" 2>/dev/null || true
done

if [ -r /sys/class/input/mice/dev ] && [ ! -e /dev/input/mice ]; then
    mm=$(cat /sys/class/input/mice/dev 2>/dev/null) || mm=""
    if [ -n "$mm" ]; then
        major=${mm%%:*}
        minor=${mm##*:}
        mknod /dev/input/mice c "$major" "$minor" 2>/dev/null || true
        chmod 660 /dev/input/mice 2>/dev/null || true
        chown root:input /dev/input/mice 2>/dev/null || true
    fi
fi

# Android's /dev/bus/usb is also ueventd-created and absent from devtmpfs.
# Recreate the /dev/bus/usb/BBB/DDD nodes from sysfs busnum/devnum.
if [ -d /sys/bus/usb/devices ]; then
    usb_group=root
    getent group usb >/dev/null 2>&1 && usb_group=usb
    install -d -m 0755 /dev/bus/usb
    for sys in /sys/bus/usb/devices/*; do
        [ -r "$sys/dev" ] || continue
        [ -r "$sys/busnum" ] || continue
        [ -r "$sys/devnum" ] || continue
        bus=$(cat "$sys/busnum" 2>/dev/null) || continue
        num=$(cat "$sys/devnum" 2>/dev/null) || continue
        mm=$(cat "$sys/dev" 2>/dev/null) || continue
        major=${mm%%:*}
        minor=${mm##*:}
        [ -n "$bus" ] && [ -n "$num" ] && [ -n "$major" ] && [ -n "$minor" ] || continue
        dir=$(printf '/dev/bus/usb/%03d' "$bus")
        node=$(printf '%s/%03d' "$dir" "$num")
        install -d -m 0755 "$dir"
        [ -e "$node" ] && continue
        mknod "$node" c "$major" "$minor" 2>/dev/null || continue
        chmod 660 "$node" 2>/dev/null || true
        chown "root:${usb_group}" "$node" 2>/dev/null || true
    done
fi
