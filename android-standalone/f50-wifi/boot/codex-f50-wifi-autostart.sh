#!/system/bin/sh
set -u
umask 077
export PATH=/system/bin:/system/xbin
base=${1%/*}
data=/data/local/f50-wifi
[ ! -e /data/local/tmp/f50-wifi-autostart-disabled ] || exit 0
mkdir -p "$data" || exit 1
chmod 700 "$data"
[ ! -L "$data/service.log" ] || exit 1
[ ! -e "$data/service.log" ] || mv "$data/service.log" "$data/service.previous.log"
exec >"$data/service.log" 2>&1
payload="$base/f50-wifi.dex"
# Owner-authorized USB updates may atomically replace this shell-owned runtime.
# A partial/corrupt update uses the verified embedded copy instead.
if [ -f "$data/runtime.dex" ] && [ -f "$data/runtime.sha256" ]; then
    if (cd "$data" && sha256sum -c runtime.sha256 >/dev/null 2>&1); then
        payload="$data/runtime.dex"
    fi
fi
CLASSPATH="$payload" exec /system/bin/app_process -Xmx64m /system/bin --nice-name=airsim-wifi-config com.airsim.f50wifi.F50WifiServer "$data" --boot
