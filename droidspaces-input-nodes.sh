#!/bin/sh
# Mirror Android ueventd-created input nodes into the Droidspaces devtmpfs.
# Droidspaces mirrors GPU nodes but not /dev/input/event*, so udev only creates
# dangling by-id/by-path symlinks. This creates the missing character nodes
# from sysfs when hardware access is enabled.
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
