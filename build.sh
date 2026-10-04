#!/data/data/com.termux/files/usr/bin/bash

export PATH=/data/data/com.termux/files/usr/bin:$PATH

mkdir -p magisk_module/vendor/bin

echo "[*] Compiling Universal Motorola UDFPS Bridge C++ Daemon..."

clang++ -std=c++17 -O3 \
    -Iinclude \
    src/moto_fod_bridge.cpp \
    src/display/drm_backend.cpp \
    src/display/sysfs_backend.cpp \
    src/fingerprint/motorola_hidl_backend.cpp \
    src/fingerprint/aosp_hidl_backend.cpp \
    -o magisk_module/vendor/bin/moto_fod_bridge \
    -lpthread -ldl

if [ -f "magisk_module/vendor/bin/moto_fod_bridge" ]; then
    echo "[✓] Compilation succeeded: magisk_module/vendor/bin/moto_fod_bridge"
else
    echo "[X] Compilation failed!"
    exit 1
fi
