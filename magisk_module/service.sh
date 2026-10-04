#!/system/bin/sh
# Late-start service daemon launcher

while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

MODDIR=${0%/*}
BIN="$MODDIR/vendor/bin/moto_fod_bridge"

chmod 755 "$BIN"

# Non-destructive process monitoring
if ! pgrep -f "$BIN" >/dev/null; then
    "$BIN" > /data/local/tmp/moto_fod_bridge.log 2>&1 &
fi
