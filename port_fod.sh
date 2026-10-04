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
log_report "Manufacturer: $(getprop ro.product.manufacturer)"
log_report "Model: $(getprop ro.product.model)"
log_report "Device Codename: $(getprop ro.product.device)"
log_report "Android Version: $(getprop ro.build.version.release)"
log_report "------------------------------------"

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE} Motorola GSI FOD Framework Hardware Scanner & Porter ${NC}"
echo -e "${BLUE}======================================================${NC}"

# ------------------------------------------------------------------------------
# 1. Broad EV_KEY Input Scanner
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[Step 1/5] Scanning Input Devices...${NC}"
DETECTED_EVENT=""
CONFIRMED_KEYCODE=""

for ev in /dev/input/event*; do
    NAME=$(getevent -p "$ev" 2>/dev/null | grep "name:" | cut -d'"' -f2)
    if echo "$NAME" | grep -i -E "fingerprint|goodix|fod" >/dev/null; then
        DETECTED_EVENT="$ev"
        echo -e "${GREEN}[✓] Discovered Candidate Node: $ev ($NAME)${NC}"
        log_report "Input Node: $ev ($NAME)"
        break
    fi
done

if [ -n "$DETECTED_EVENT" ]; then
    echo -e "${YELLOW}👉 Touch and hold the fingerprint sensor on screen now (5 sec test)...${NC}"
    EV_LOG="/tmp/ev_test.log"
    getevent -l "$DETECTED_EVENT" > "$EV_LOG" &
    GE_PID=$!
    sleep 5
    kill $GE_PID 2>/dev/null || true

    # Extract any generated EV_KEY event code during touch test
    CAPTURED_KEY=$(grep "EV_KEY" "$EV_LOG" | head -n 1 | awk '{print $3}')
    if [ -n "$CAPTURED_KEY" ]; then
        if [ "$CAPTURED_KEY" == "KEY_02c0" ] || [ "$CAPTURED_KEY" == "02c0" ] || [ "$CAPTURED_KEY" == "BTN_TRIGGER_HAPPY5" ]; then
            CONFIRMED_KEYCODE="704"
        elif [ "$CAPTURED_KEY" == "BTN_TOUCH" ] || [ "$CAPTURED_KEY" == "0140" ]; then
            CONFIRMED_KEYCODE="330"
        else
            CONFIRMED_KEYCODE="704" # Default for Motorola
        fi
        echo -e "${GREEN}[✓] Detected Active Keycode: $CONFIRMED_KEYCODE ($CAPTURED_KEY)${NC}"
        log_report "Keycode Detected: $CONFIRMED_KEYCODE ($CAPTURED_KEY)"
    fi
fi

if [ -z "$DETECTED_EVENT" ] || [ -z "$CONFIRMED_KEYCODE" ]; then
    echo -e "${YELLOW}[!] Discovery incomplete. Loading reference profile 'boston'...${NC}"
    if [ -f "profiles/boston.conf" ]; then source profiles/boston.conf; fi
    DETECTED_EVENT=${INPUT_NODE:-"/dev/input/event10"}
    CONFIRMED_KEYCODE=${TARGET_KEYCODE:-"704"}
    log_report "Input Node Fallback: $DETECTED_EVENT (Keycode: $CONFIRMED_KEYCODE)"
fi

# ------------------------------------------------------------------------------
# 2. FOD Sysfs Node Discovery & Verification
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[Step 2/5] Locating FOD Sysfs Control Node...${NC}"
DETECTED_SYSFS=$(find /sys -iname "*fod_en*" 2>/dev/null | head -n 1)

if [ -n "$DETECTED_SYSFS" ] && [ -w "$DETECTED_SYSFS" ]; then
    echo -e "${GREEN}[✓] Verified Writable Sysfs Node: $DETECTED_SYSFS${NC}"
    log_report "Sysfs FOD Node: $DETECTED_SYSFS (Verified)"
else
    DETECTED_SYSFS="/sys/devices/platform/goodix_ts.0/gesture/fod_en"
    echo -e "${YELLOW}[!] Defaulting Sysfs Node: $DETECTED_SYSFS${NC}"
    log_report "Sysfs FOD Node: $DETECTED_SYSFS (Fallback)"
fi

# ------------------------------------------------------------------------------
# 3. DRM Display Engine & Parameter Calibration
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[Step 3/5] Calibrating Display Local-HBM (LHBM) Engine...${NC}"
DRM_NODE="/dev/dri/card0"
P0=2; P1=2; P2=0

if [ -c "$DRM_NODE" ]; then
    echo -e "${GREEN}[✓] DRM Node Found ($DRM_NODE). Testing DRM IOCTL presets...${NC}"

cat << 'EOF' > /tmp/test_lhbm.c
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define DRM_IOCTL_MDSS_DISP_PARAM 0xc008649f

struct disp_param_req {
    uint32_t param_id;
    int32_t value;
};

int main(int argc, char **argv) {
    if (argc != 4) return 1;
    int fd = open("/dev/dri/card0", O_RDWR);
    if (fd < 0) return 1;

    struct disp_param_req req;
    req.param_id = 0; req.value = atoi(argv[1]);
    ioctl(fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

    req.param_id = 1; req.value = atoi(argv[2]);
    ioctl(fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

    req.param_id = 2; req.value = atoi(argv[3]);
    ioctl(fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

    close(fd);
    return 0;
}
EOF

    clang /tmp/test_lhbm.c -o /tmp/test_lhbm
    PRESETS=("2 2 0" "1 1 0" "2 1 0")

    for preset in "${PRESETS[@]}"; do
        echo -e "${YELLOW}Testing DRM Preset: $preset ...${NC}"
        /tmp/test_lhbm $preset
        read -p "Did the fingerprint icon illuminate in high brightness? (y/N): " RESP
        if [[ "$RESP" =~ ^[Yy]$ ]]; then
            P0=$(echo $preset | awk '{print $1}')
            P1=$(echo $preset | awk '{print $2}')
            P2=$(echo $preset | awk '{print $3}')
            echo -e "${GREEN}[✓] Confirmed DRM Parameters: P0=$P0, P1=$P1, P2=$P2${NC}"
            break
        fi
    done
    /tmp/test_lhbm 0 0 0 2>/dev/null || true
    log_report "Display Engine: Qualcomm DRM ($DRM_NODE) [P0=$P0, P1=$P1, P2=$P2]"
else
    echo -e "${YELLOW}[!] DRM Node not found. Operating in Sysfs mode.${NC}"
    log_report "Display Engine: Sysfs Fallback Mode"
fi

# ------------------------------------------------------------------------------
# 4. Fingerprint Vendor Shared Library Check
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[Step 4/5] Checking Vendor Fingerprint Shared Libraries...${NC}"
FINGERPRINT_LIB="/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so"

if [ -f "$FINGERPRINT_LIB" ]; then
    echo -e "${GREEN}[✓] Verified Motorola HIDL v1.0 Library: $FINGERPRINT_LIB${NC}"
    log_report "Fingerprint HAL: Motorola HIDL v1.0 ($FINGERPRINT_LIB)"
else
    echo -e "${YELLOW}[!] Motorola HIDL v1.0 library missing. Bridge will handle LHBM toggling.${NC}"
    log_report "Fingerprint HAL: Missing / Unverified"
fi

# ------------------------------------------------------------------------------
# 5. Generate Header: include/device_config.h
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[Step 5/5] Generating Header: include/device_config.h ...${NC}"
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

#define CONFIG_FINGERPRINT_LIB_PATH "$FINGERPRINT_LIB"

#endif // DEVICE_CONFIG_H
EOF

echo -e "${GREEN}[✓] Header include/device_config.h successfully generated!${NC}"
log_report "Status: CONFIGURATION GENERATED SUCCESSFULLY"

# Trigger Build & Packaging Pipeline
if [ -f "build.sh" ]; then bash build.sh; fi
if [ -f "zip_module.sh" ]; then bash zip_module.sh; fi

echo -e "\n${GREEN}[✓] Hardware diagnostic report written to: $REPORT_FILE${NC}"
