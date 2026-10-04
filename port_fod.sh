#!/data/data/com.termux/files/usr/bin/bash

export PATH=/data/data/com.termux/files/usr/bin:$PATH

if [ "$EUID" -ne 0 ]; then
    exec su -c "export PATH=/data/data/com.termux/files/usr/bin:\$PATH; bash $0 $@"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPORT_FILE="fod_port_report.txt"
rm -f "$REPORT_FILE"

log_report() { echo "$1" >> "$REPORT_FILE"; }

log_report "=== Motorola Universal GSI FOD Report ==="
log_report "Date: $(date)"
log_report "Device: $(getprop ro.product.manufacturer) $(getprop ro.product.model) ($(getprop ro.product.device))"
log_report "----------------------------------------"

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE} Motorola Universal GSI FOD Hardware Scanner & Porter ${NC}"
echo -e "${BLUE}======================================================${NC}"

DEVICE_CODENAME=$(getprop ro.product.device)
if [ "$1" == "--profile" ] && [ -n "$2" ]; then
    PROF_FILE="profiles/$2.conf"
    if [ -f "$PROF_FILE" ]; then
        echo -e "${GREEN}[✓] Loading requested profile: $PROF_FILE${NC}"
        source "$PROF_FILE"
    else
        echo -e "${RED}[X] Profile $PROF_FILE not found! Exiting.${NC}"
        log_report "Status: ERROR (Profile $2 not found)"
        exit 1
    fi
elif [ "$DEVICE_CODENAME" == "boston" ]; then
    echo -e "${GREEN}[✓] Detected 'boston' hardware (Moto G Stylus 5G 2024). Loading profiles/boston.conf${NC}"
    source "profiles/boston.conf"
fi

# 1. Device-Agnostic Input Discovery
if [ -z "$INPUT_NODE" ]; then
    echo -e "\n${BLUE}[Step 1/5] Scanning Input Devices...${NC}"
    for ev in /dev/input/event*; do
        NAME=$(getevent -p "$ev" 2>/dev/null | grep "name:" | cut -d'"' -f2)
        if echo "$NAME" | grep -i -E "fingerprint|goodix|fod" >/dev/null; then
            INPUT_NODE="$ev"
            echo -e "${GREEN}[✓] Discovered Sensor Node: $ev ($NAME)${NC}"
            break
        fi
    done
fi

if [ -n "$INPUT_NODE" ] && [ -z "$TARGET_KEYCODE" ]; then
    echo -e "${YELLOW}👉 Touch and hold the fingerprint sensor on screen now (5 sec test)...${NC}"
    
    # Capture raw numeric event code directly from getevent
    HEX_CODE=$(getevent -c 5 "$INPUT_NODE" 2>/dev/null | grep " 0001 " | head -n 1 | awk '{print $3}')
    
    if [ -n "$HEX_CODE" ]; then
        TARGET_KEYCODE=$((16#$HEX_CODE))
        echo -e "${GREEN}[✓] Discovered Numeric Keycode: $TARGET_KEYCODE (Raw Hex: 0x$HEX_CODE)${NC}"
    fi
fi

if [ -z "$INPUT_NODE" ] || [ -z "$TARGET_KEYCODE" ]; then
    echo -e "\n${RED}[X] Unknown Device / Input Discovery Failed!${NC}"
    echo -e "${RED}[X] Could not auto-detect fingerprint input node or target keycode.${NC}"
    echo -e "${YELLOW}👉 Supply a valid profile: 'bash port_fod.sh --profile <profile_name>'${NC}"
    log_report "Status: DISCOVERY FAILED (Input Node / Keycode Unverified)"
    exit 1
fi

log_report "Input Device: $INPUT_NODE (Keycode: $TARGET_KEYCODE)"

# 2. Sysfs FOD Control Discovery (No implicit Boston fallback)
if [ -z "$SYSFS_FOD_EN" ]; then
    echo -e "\n${BLUE}[Step 2/5] Locating Sysfs Control Node...${NC}"
    SYSFS_FOD_EN=$(find /sys -iname "*fod_en*" 2>/dev/null | head -n 1)
fi

if [ -z "$SYSFS_FOD_EN" ]; then
    echo -e "${YELLOW}[!] Warning: No Sysfs FOD control node discovered.${NC}"
    SYSFS_FOD_EN="/dev/null"
    log_report "Sysfs Node: NONE (DRM Engine primary)"
else
    echo -e "${GREEN}[✓] Discovered Sysfs Node: $SYSFS_FOD_EN${NC}"
    log_report "Sysfs Node: $SYSFS_FOD_EN"
fi

# 3. Display Driver Engine
DRM_CARD_NODE=${DRM_CARD_NODE:-"/dev/dri/card0"}
P0=${LHBM_PARAM_P0:-2}
P1=${LHBM_PARAM_P1:-2}
P2=${LHBM_PARAM_P2:-0}
log_report "Display Engine: DRM $DRM_CARD_NODE [P0=$P0, P1=$P1, P2=$P2]"

# 4. Fingerprint Backend Selection (Strict Fail-Closed)
FINGERPRINT_LIB=${FINGERPRINT_LIB:-"/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so"}
if [ -f "$FINGERPRINT_LIB" ]; then
    FP_BACKEND="motorola_hidl"
else
    echo -e "\n${RED}[X] Error: Required Motorola fingerprint library ($FINGERPRINT_LIB) not found!${NC}"
    log_report "Status: FAILED (Missing Motorola HIDL Library)"
    exit 1
fi
log_report "Fingerprint Backend: $FP_BACKEND"

# 5. Header Generation
echo -e "\n${BLUE}[Step 5/5] Generating Header: include/device_config.h ...${NC}"
mkdir -p include

cat << EOF > include/device_config.h
#ifndef DEVICE_CONFIG_H
#define DEVICE_CONFIG_H

#define CONFIG_INPUT_NODE "$INPUT_NODE"
#define CONFIG_TARGET_KEYCODE $TARGET_KEYCODE

#define CONFIG_SYSFS_FOD_EN "$SYSFS_FOD_EN"
#define CONFIG_DRM_CARD_NODE "$DRM_CARD_NODE"

#define CONFIG_LHBM_PARAM_P0 $P0
#define CONFIG_LHBM_PARAM_P1 $P1
#define CONFIG_LHBM_PARAM_P2 $P2

#define CONFIG_WATCHDOG_TIMEOUT_SEC 3

#define CONFIG_FINGERPRINT_BACKEND "$FP_BACKEND"
#define CONFIG_FINGERPRINT_LIB_PATH "$FINGERPRINT_LIB"

#endif // DEVICE_CONFIG_H
EOF

echo -e "${GREEN}[✓] Header include/device_config.h successfully generated!${NC}"

if [ -f "build.sh" ]; then bash build.sh; fi
if [ -f "zip_module.sh" ]; then bash zip_module.sh; fi

echo -e "\n${GREEN}[✓] Porting complete. Diagnostic report written to: $REPORT_FILE${NC}"
