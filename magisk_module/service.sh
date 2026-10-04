#!/system/bin/sh
# Wait for boot completion
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

MODDIR=${0%/*}
BIN="$MODDIR/vendor/bin/moto_fod_bridge"

# Ensure executable permissions
chmod 755 "$BIN"

# Check if daemon is already running before spawning
if ! pgrep -f "$BIN" >/dev/null; then
    "$BIN" > /data/local/tmp/moto_fod_bridge.log 2>&1 &
fi
