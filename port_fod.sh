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

log_report() {
    echo "$1" >> "$REPORT_FILE"
}

log_report "=== Motorola GSI FOD Port Report ==="
log_report "Date: $(date)"
log_report "Model: $(getprop ro.product.model)"
log_report "Device Codename: $(getprop ro.product.device)"
log_report "Android Version: $(getprop ro.build.version.release)"
log_report "------------------------------------"

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE} Motorola GSI FOD Framework Hardware Scanner & Porter ${NC}"
echo -e "${BLUE}======================================================${NC}"

# Step 1: Input Event Scanner
echo -e "\n${BLUE}[Step 1/4] Scanning Input Devices...${NC}"
DETECTED_EVENT=""
CONFIRMED_KEYCODE=""

# Scan device nodes for fingerprint capability
for ev in /dev/input/event*; do
    NAME=$(getevent -p "$ev" 2>/dev/null | grep "name:" | cut -d'"' -f2)
    if echo "$NAME" | grep -i -E "fingerprint|goodix|fod" >/dev/null; then
        DETECTED_EVENT="$ev"
        log_report "Input Device: $ev ($NAME)"
        break
    fi
done

if [ -n "$DETECTED_EVENT" ]; then
    echo -e "${GREEN}[✓] Candidate Input Node Found: $DETECTED_EVENT${NC}"
    echo -e "${YELLOW}👉 Touch the fingerprint sensor on screen now (5 sec test)...${NC}"
    
    EV_LOG="/tmp/ev_test.log"
    getevent -l "$DETECTED_EVENT" > "$EV_LOG" &
    GE_PID=$!
    sleep 5
    kill $GE_PID 2>/dev/null || true

    if grep -q "02c0" "$EV_LOG" || grep -q "704" "$EV_LOG"; then
        CONFIRMED_KEYCODE="704"
        echo -e "${GREEN}[✓] Verified Keycode 704 (BTN_TRIGGER_HAPPY)${NC}"
        log_report "Keycode: 704 (BTN_TRIGGER_HAPPY) - VERIFIED"
    elif grep -q "0140" "$EV_LOG" || grep -q "330" "$EV_LOG"; then
        CONFIRMED_KEYCODE="330"
        echo -e "${GREEN}[✓] Verified Keycode 330 (BTN_TOUCH)${NC}"
        log_report "Keycode: 330 (BTN_TOUCH) - VERIFIED"
    fi
fi

if [ -z "$DETECTED_EVENT" ] || [ -z "$CONFIRMED_KEYCODE" ]; then
    echo -e "${YELLOW}[!] Verification incomplete. Checking reference profile 'boston'...${NC}"
    if [ -f "profiles/boston.conf" ]; source profiles/boston.conf; fi
    DETECTED_EVENT=${INPUT_NODE:-"/dev/input/event10"}
    CONFIRMED_KEYCODE=${TARGET_KEYCODE:-"704"}
    log_report "Input Device Fallback: $DETECTED_EVENT (Keycode: $CONFIRMED_KEYCODE)"
fi

# Step 2: FOD Sysfs Node
echo -e "\n${BLUE}[Step 2/4] Locating FOD Sysfs Control Node...${NC}"
DETECTED_SYSFS=$(find /sys -iname "*fod_en*" 2>/dev/null | head -n 1)
if [ -z "$DETECTED_SYSFS" ]; then
    DETECTED_SYSFS="/sys/devices/platform/goodix_ts.0/gesture/fod_en"
fi
log_report "Sysfs FOD Control: $DETECTED_SYSFS"

# Step 3: DRM / Display Engine Verification
echo -e "\n${BLUE}[Step 3/4] Verifying Display Engine...${NC}"
DRM_NODE="/dev/dri/card0"
P0=2; P1=2; P2=0

if [ -c "$DRM_NODE" ]; then
    log_report "Display Backend: Qualcomm DRM Engine ($DRM_NODE)"
else
    log_report "Display Backend: Sysfs Fallback Engine"
fi

# Step 4: Generate Configuration Header
echo -e "\n${BLUE}[Step 4/4] Generating Header: include/device_config.h...${NC}"
mkdir -p include

cat << EOF > include/device_config.h
#ifndef DEVICE_CONFIG_H
#define DEVICE_CONFIG_H

#define CONFIG_INPUT_NODE "$DETECTED_EVENT"
#define CONFIG_TARGET_KEYCODE $CONFIRMED_KEYCODE

#define CONFIG_SYSFS_FOD_EN "$DETECTED_SYSFS"
#define CONFIG_DRM_CARD_NODE "$DRM_NODE"

#define CONFIG_LHBM_PARAM_P0 $P0
#define CONFIG_LHBM_PARAM_P1 $P1
#define CONFIG_LHBM_PARAM_P2 $P2

#define CONFIG_WATCHDOG_TIMEOUT_SEC 3

#endif // DEVICE_CONFIG_H
EOF

log_report "Status: CONFIGURATION GENERATED SUCCESSFULLY"

# Compilation & Packaging
bash build.sh
bash zip_module.sh

echo -e "\n${GREEN}[✓] Diagnostic report saved to: $REPORT_FILE${NC}"
