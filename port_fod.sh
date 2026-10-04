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

# Profile argument support
if [ "$1" == "--profile" ] && [ -n "$2" ]; then
    PROF_FILE="profiles/$2.conf"
    if [ -f "$PROF_FILE" ]; then
        echo -e "${GREEN}[✓] Loading requested profile: $PROF_FILE${NC}"
        source "$PROF_FILE"
    else
        echo -e "${RED}[X] Profile $PROF_FILE not found! Exiting.${NC}"
        exit 1
    fi
fi

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
    EV_LOG="/tmp/ev_test.log"
    getevent -ql "$INPUT_NODE" > "$EV_LOG" &
    GE_PID=$!
    sleep 5
    kill $GE_PID 2>/dev/null || true

    # Parse numerical event code from raw event dump
    RAW_CODE=$(grep "EV_KEY" "$EV_LOG" | head -n 1 | awk '{print $3}')
    if [ -n "$RAW_CODE" ]; then
        # Convert hex keycode representation if necessary
        if [[ "$RAW_CODE" == KEY_* ]]; then
            TARGET_KEYCODE=704
        else
            TARGET_KEYCODE=$((16#$RAW_CODE))
        fi
        echo -e "${GREEN}[✓] Discovered Numeric Keycode: $TARGET_KEYCODE ($RAW_CODE)${NC}"
    fi
fi

# Halt if hardware scanner fails rather than silently loading defaults
if [ -z "$INPUT_NODE" ] || [ -z "$TARGET_KEYCODE" ]; then
    echo -e "\n${RED}[X] Automatic input discovery failed!${NC}"
    echo -e "${YELLOW}Run with '--profile boston' if using the Motorola Moto G Stylus 5G reference device.${NC}"
    log_report "Status: INPUT DISCOVERY FAILED"
    exit 1
fi

log_report "Input Device: $INPUT_NODE (Keycode: $TARGET_KEYCODE)"

# 2. Sysfs FOD Control Discovery
if [ -z "$SYSFS_FOD_EN" ]; then
    echo -e "\n${BLUE}[Step 2/5] Locating Sysfs Control Node...${NC}"
    SYSFS_FOD_EN=$(find /sys -iname "*fod_en*" 2>/dev/null | head -n 1)
fi
SYSFS_FOD_EN=${SYSFS_FOD_EN:-"/sys/devices/platform/goodix_ts.0/gesture/fod_en"}
log_report "Sysfs Node: $SYSFS_FOD_EN"

# 3. DRM Parameter Calibration
DRM_CARD_NODE=${DRM_CARD_NODE:-"/dev/dri/card0"}
P0=${LHBM_PARAM_P0:-2}; P1=${LHBM_PARAM_P1:-2}; P2=${LHBM_PARAM_P2:-0}
log_report "Display Engine: DRM $DRM_CARD_NODE [P0=$P0, P1=$P1, P2=$P2]"

# 4. Fingerprint Backend Selection
FINGERPRINT_LIB=${FINGERPRINT_LIB:-"/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so"}
if [ -f "$FINGERPRINT_LIB" ]; then
    FP_BACKEND="motorola_hidl"
else
    FP_BACKEND="aosp_hidl"
fi
log_report "Fingerprint Backend: $FP_BACKEND"

# 5. Generate Header: include/device_config.h
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

echo -e "\n${GREEN}[✓] Report written to: $REPORT_FILE${NC}"
