#!/system/bin/sh
MODDIR=${0%/*}
# Wait for boot to complete
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
done
# Launch the FOD bridge in background
nohup $MODDIR/system/bin/moto_fod_bridge >/dev/null 2>&1 &
