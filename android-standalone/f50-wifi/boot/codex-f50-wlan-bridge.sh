#!/system/bin/sh
set -u
export PATH=/system/bin:/system/xbin
umask 022
log=/dev/f50-wlan-bridge.log
exec >"$log" 2>&1
chcon u:object_r:system_file:s0 "$log" || true
report() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

jar=$(sha256sum /apex/com.android.wifi/javalib/service-wifi.jar)
if [ "${jar%% *}" != ac1698cbfe73ae03e6497df42127943a4cb06f73f34f35955e72a96c506dd95e ]; then
    report 'Wi-Fi patch unavailable'
    exit 0
fi
[ ! -e /data/local/tmp/f50-ifconfig-guard-disabled ] || exit 0
read -r uptime idle </proc/uptime
uptime=${uptime%%.*}
[ "$uptime" -ge 25 ] || sleep "$((25 - uptime))"
# A charger has no USB host: B28 can remain in the charging configuration.
# Address protection is independent of the gadget; keep USB setup untouched.
[ "$(getprop sys.boot_completed)" = 1 ] || { report 'system boot not ready'; exit 1; }
netd_hash=$(sha256sum /system/bin/netd)
[ "${netd_hash%% *}" = edfea436579c95f39dd43ec5f3dc458ebc091ad60fed57c5174ead3d771448f3 ] || exit 1
guard=$1
guard_hash=$(sha256sum "$guard")
[ "${guard_hash%% *}" = a70ae318081b6d789fd72e856f06a2862b2992b2efa74ce36711cb4c64b632e0 ] || exit 1
root=/dev/f50-ifconfig-overlay
mkdir -p "$root/upper" "$root/work"
chcon u:object_r:system_file:s0 "$root" "$root/upper" "$root/work"
chmod 0755 "$root" "$root/upper"
cp "$guard" "$root/upper/ifconfig"
chmod 0755 "$root/upper/ifconfig"
chcon u:object_r:toolbox_exec:s0 "$root/upper/ifconfig"
/system/bin/ifconfig lo >"$root/original-loopback"
if ! mount -t overlay overlay -o "lowerdir=/system/bin,upperdir=$root/upper,workdir=$root/work" /system/bin; then
    report 'command overlay mount failed'
    exit 1
fi
if ! /system/bin/ifconfig lo >"$root/guard-loopback"; then
    umount /system/bin
    report 'command forwarding failed, overlay removed'
    exit 1
fi
touch /dev/f50-ifconfig-ready
chcon u:object_r:system_file:s0 /dev/f50-ifconfig-ready
logcat -v threadtime -s F50Sta:I > /dev/f50-ifconfig-events.log 2>&1 &
capture=$!
chcon u:object_r:system_file:s0 /dev/f50-ifconfig-events.log || true
report 'command overlay installed after system boot'
report 'waiting for Wi-Fi client mode'
flag=/dev/f50-ifconfig-sta
intervals=0
stable=0
while true; do
    intervals=$((intervals + 1))
    if [ "$(getprop init.svc.hostapd)" != running ] &&
       cmd wifi status | grep -qx 'Wifi is enabled'; then
        master=$(readlink /sys/class/net/wlan0/master 2>/dev/null || true)
        if [ "${master##*/}" = br0 ]; then
            ip link set dev wlan0 nomaster && report 'detached client wlan0 from hotspot bridge'
        fi
        if [ -z "$(readlink /sys/class/net/wlan0/master 2>/dev/null || true)" ]; then
            if [ ! -e "$flag" ]; then
                touch "$flag"
                chcon u:object_r:system_file:s0 "$flag"
                report 'enabled protection for netd wlan0 clear'
            fi
            if ip -4 route show table wlan0 2>/dev/null | grep -q '^default '; then
                stable=$((stable + 1))
                if [ "$stable" -ge 30 ] && [ -n "$capture" ]; then
                    report 'Wi-Fi route remained stable for 30 samples'
                    kill "$capture"
                    capture=""
                fi
            else
                stable=0
            fi
        fi
    else
        rm -f "$flag"
        stable=0
    fi
    sleep 3
done
