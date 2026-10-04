#!/data/data/com.termux/files/usr/bin/bash

export PATH=/data/data/com.termux/files/usr/bin:$PATH

OUT_ZIP="Motorola_UDFPS_Bridge_v4.zip"
rm -f "$OUT_ZIP"

if [ -d "magisk_module" ]; then
    cd magisk_module
    zip -r "../$OUT_ZIP" ./*
    cd ..
    echo "[✓] Module packaged successfully: $OUT_ZIP"
else
    echo "[X] Error: magisk_module directory not found!"
    exit 1
fi
