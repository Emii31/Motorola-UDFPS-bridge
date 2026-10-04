#!/data/data/com.termux/files/usr/bin/bash

# Ensure Termux PATH is accessible under root
export PATH=/data/data/com.termux/files/usr/bin:$PATH

if [ "$EUID" -ne 0 ]; then
    echo "[!] Requesting root privileges..."
    exec su -c "export PATH=/data/data/com.termux/files/usr/bin:\$PATH; bash $0 $@"
fi

# Terminal Formatting Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}   Motorola/GSI Universal Local-HBM UDFPS Porter      ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo ""

# ------------------------------------------------------------------------------
# 0. Check Toolchain Dependencies
# ------------------------------------------------------------------------------
echo -e "${BLUE}[Step 0/5] Checking toolchain dependencies...${NC}"
MISSING_PKGS=()
command -v clang++ >/dev/null 2>&1 || MISSING_PKGS+=("clang")
command -v git >/dev/null 2>&1 || MISSING_PKGS+=("git")
command -v zip >/dev/null 2>&1 || MISSING_PKGS+=("zip")

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo -e "${YELLOW}[!] Installing missing dependencies: ${MISSING_PKGS[*]}...${NC}"
    pkg update -y && pkg install "${MISSING_PKGS[@]}" -y
else
    echo -e "${GREEN}[✓] Toolchain dependencies available.${NC}"
fi

# ------------------------------------------------------------------------------
# 1. Precise Input Node Detection
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 1/5] Identifying Fingerprint Input Node...${NC}"

# Scan device capabilities for fingerprint/goodix input devices
DETECTED_EVENT=$(getevent -lp 2>/dev/null | grep -B 5 -i -E "fingerprint|goodix|fod" | grep -o "/dev/input/event[0-9]*" | head -n 1)

if [ -z "$DETECTED_EVENT" ]; then
    echo -e "${YELLOW}[!] Device capability scan inconclusive. Waiting for touch test...${NC}"
    echo -e "${YELLOW}👉 Touch and hold the fingerprint sensor area on screen now (7 sec)...${NC}"
    
    GE_LOG="/tmp/getevent_test.log"
    getevent -l > "$GE_LOG" &
    GE_PID=$!
    sleep 7
    kill $GE_PID 2>/dev/null || true

    DETECTED_EVENT=$(grep -E "BTN_TRIGGER_HAPPY|02c0" "$GE_LOG" | head -n 1 | awk '{print $1}' | tr -d ':')
fi

if [ -z "$DETECTED_EVENT" ]; then
    DETECTED_EVENT="/dev/input/event10"
    echo -e "${YELLOW}[!] Defaulting input event path to: $DETECTED_EVENT${NC}"
else
    echo -e "${GREEN}[✓] Detected Fingerprint Input Node: $DETECTED_EVENT${NC}"
fi

CHOSEN_KEY="704"

# ------------------------------------------------------------------------------
# 2. FOD Sysfs Node Discovery
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 2/5] Locating FOD Gesture Sysfs Node...${NC}"
DETECTED_SYSFS=$(find /sys -iname "*fod_en*" 2>/dev/null | head -n 1)

if [ -z "$DETECTED_SYSFS" ]; then
    DETECTED_SYSFS="/sys/devices/platform/goodix_ts.0/gesture/fod_en"
    echo -e "${YELLOW}[!] Defaulting Sysfs Node path to: $DETECTED_SYSFS${NC}"
else
    echo -e "${GREEN}[✓] Discovered Sysfs FOD Node: $DETECTED_SYSFS${NC}"
fi

# ------------------------------------------------------------------------------
# 3. Display Interface Identification & Calibration Branch
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 3/5] Calibrating Display Local-HBM (LHBM) Engine...${NC}"

DRM_NODE="/dev/dri/card0"
PARAM_P0="2"
PARAM_P1="2"
PARAM_P2="0"

if [ -c "$DRM_NODE" ]; then
    echo -e "${GREEN}[✓] DRM Interface Found ($DRM_NODE). Testing DRM IOCTL Presets...${NC}"

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
        read -p "Did the screen fingerprint circle illuminate high-brightness? (y/N): " RESP
        if [[ "$RESP" =~ ^[Yy]$ ]]; then
            PARAM_P0=$(echo $preset | awk '{print $1}')
            PARAM_P1=$(echo $preset | awk '{print $2}')
            PARAM_P2=$(echo $preset | awk '{print $3}')
            echo -e "${GREEN}[✓] Confirmed DRM Parameters: P0=$PARAM_P0, P1=$PARAM_P1, P2=$PARAM_P2${NC}"
            break
        fi
    done
    /tmp/test_lhbm 0 0 0 2>/dev/null || true
else
    echo -e "${YELLOW}[!] DRM Node not found. Utilizing Sysfs Fallback Engines.${NC}"
fi

# ------------------------------------------------------------------------------
# 4. Generate Clean Device Configuration Header
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 4/5] Generating Header: include/device_config.h ...${NC}"
mkdir -p include

cat << EOF > include/device_config.h
#ifndef DEVICE_CONFIG_H
#define DEVICE_CONFIG_H

#define CONFIG_INPUT_NODE "$DETECTED_EVENT"
#define CONFIG_TARGET_KEYCODE $CHOSEN_KEY

#define CONFIG_SYSFS_FOD_EN "$DETECTED_SYSFS"
#define CONFIG_DRM_CARD_NODE "$DRM_NODE"

#define CONFIG_LHBM_PARAM_P0 $PARAM_P0
#define CONFIG_LHBM_PARAM_P1 $PARAM_P1
#define CONFIG_LHBM_PARAM_P2 $PARAM_P2

#endif // DEVICE_CONFIG_H
EOF

echo -e "${GREEN}[✓] Header generated without mutating repository source code!${NC}"

# ------------------------------------------------------------------------------
# 5. Build Binary & Package Module
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 5/5] Compiling and Packaging Magisk Module...${NC}"

mkdir -p magisk_module/vendor/bin
mkdir -p out

clang++ -std=c++17 -O3 \
    src/moto_fod_bridge.cpp \
    -o magisk_module/vendor/bin/moto_fod_bridge \
    -lpthread -ldl

if [ -f "magisk_module/vendor/bin/moto_fod_bridge" ]; then
    echo -e "${GREEN}[✓] Binary compilation succeeded!${NC}"
else
    echo -e "${RED}[X] Compilation failed.${NC}"
    exit 1
fi

if [ -f "zip_module.sh" ]; then
    sed -i '1s|.*|#!/data/data/com.termux/files/usr/bin/bash|' zip_module.sh
    bash zip_module.sh
fi

echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}🎉 PORTING & BUILD COMPLETE!${NC}"
echo -e "${GREEN}======================================================${NC}"
