#!/system/bin/sh
MODDIR=${0%/*}
BIN="$MODDIR/vendor/bin/moto_fod_bridge"

# Wait until boot is fully completed
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done

sleep 3

# Kill any stale runs
killall -9 moto_fod_bridge vndservice 2>/dev/null || true
umount /vendor/bin/vndservice 2>/dev/null || true

# Mount binary to vendor space to satisfy Bionic Linker namespace
mount --bind "$BIN" /vendor/bin/vndservice 2>/dev/null || true
chmod 755 /vendor/bin/vndservice
chcon u:object_r:vendor_file:s0 /vendor/bin/vndservice 2>/dev/null || true

# Initialize fresh log for this boot
echo "[*] Initializing Moto Native LHBM FOD Bridge..." > /data/local/tmp/fod_bridge.log

# Launch daemon loop
(
    while true; do
        if ! pidof vndservice >/dev/null 2>&1 && ! pidof moto_fod_bridge >/dev/null 2>&1; then
            /vendor/bin/vndservice >> /data/local/tmp/fod_bridge.log 2>&1
        fi
        sleep 5
    done
) &
