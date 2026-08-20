#!/bin/bash
set -e
echo "[*] Compiling Motorola Native LHBM FOD Bridge..."
clang++ -std=c++17 -O3 src/moto_fod_bridge.cpp -o magisk_module/vendor/bin/moto_fod_bridge -lpthread -ldl
chmod 755 magisk_module/vendor/bin/moto_fod_bridge
echo "[+] Compiled successfully -> magisk_module/vendor/bin/moto_fod_bridge"
