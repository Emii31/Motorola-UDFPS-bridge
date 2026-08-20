#!/bin/bash
set -e
mkdir -p out
cd magisk_module
zip -r9 ../out/Moto_Native_Local_HBM_FOD_Bridge_v4.zip ./*
cd ..
echo "[+] Flashable Magisk zip generated -> out/Moto_Native_Local_HBM_FOD_Bridge_v4.zip"
