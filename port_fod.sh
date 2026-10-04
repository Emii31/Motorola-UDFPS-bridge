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
# 0. Check & Install Dependencies
# ------------------------------------------------------------------------------
echo -e "${BLUE}[Step 0/6] Checking required toolchain dependencies...${NC}"
MISSING_PKGS=()
command -v clang++ >/dev/null 2>&1 || MISSING_PKGS+=("clang")
command -v git >/dev/null 2>&1 || MISSING_PKGS+=("git")
command -v zip >/dev/null 2>&1 || MISSING_PKGS+=("zip")

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo -e "${YELLOW}[!] Installing missing dependencies: ${MISSING_PKGS[*]}...${NC}"
    pkg update -y && pkg install "${MISSING_PKGS[@]}" -y
else
    echo -e "${GREEN}[✓] All dependencies (clang++, git, zip) are installed.${NC}"
fi

# ------------------------------------------------------------------------------
# 1. Detect Input Event Node & Keycode Automatically
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 1/6] Detecting Fingerprint Input Event Node & Keycode...${NC}"
echo -e "${YELLOW}👉 Touch and hold the fingerprint sensor area on your screen now...${NC}"
echo -e "${YELLOW}   (Waiting 7 seconds for touch events)${NC}"

GE_LOG="/tmp/getevent_test.log"
getevent -l > "$GE_LOG" &
GE_PID=$!
sleep 7
kill $GE_PID 2>/dev/null || true

DETECTED_EVENT=$(grep -E "BTN_TOUCH|BTN_TRIGGER_HAPPY|02c0|0140|704" "$GE_LOG" | head -n 1 | awk '{print $1}' | tr -d ':')

if [ -z "$DETECTED_EVENT" ]; then
    echo -e "${YELLOW}[!] Auto-detection timed out. Defaulting to /dev/input/event10${NC}"
    DETECTED_EVENT="/dev/input/event10"
else
    echo -e "${GREEN}[✓] Detected Input Node: $DETECTED_EVENT${NC}"
fi

if grep -q -E "02c0|BTN_TRIGGER_HAPPY" "$GE_LOG"; then
    CHOSEN_KEY="704"
    echo -e "${GREEN}[✓] Automatically detected Keycode: 704 (BTN_TRIGGER_HAPPY)${NC}"
elif grep -q -E "0140|BTN_TOUCH" "$GE_LOG"; then
    CHOSEN_KEY="330"
    echo -e "${GREEN}[✓] Automatically detected Keycode: 330 (BTN_TOUCH)${NC}"
else
    CHOSEN_KEY="704"
    echo -e "${YELLOW}[!] Keycode not matched in log. Defaulting to 704 (BTN_TRIGGER_HAPPY)${NC}"
fi

# ------------------------------------------------------------------------------
# 2. Detect FOD Sysfs Gesture Node
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 2/6] Detecting FOD Sysfs Gesture Node...${NC}"
DETECTED_SYSFS=$(find /sys -iname "*fod_en*" 2>/dev/null | head -n 1)

if [ -z "$DETECTED_SYSFS" ]; then
    DETECTED_SYSFS="/sys/devices/platform/goodix_ts.0/gesture/fod_en"
    echo -e "${YELLOW}[!] Could not locate active sysfs node. Defaulting to $DETECTED_SYSFS${NC}"
else
    echo -e "${GREEN}[✓] Found FOD Sysfs Node: $DETECTED_SYSFS${NC}"
fi

# ------------------------------------------------------------------------------
# 3. Detect Display Hardware Interface
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 3/6] Detecting Display Hardware Interface...${NC}"

DRM_NODE="/dev/dri/card0"
if [ -c "$DRM_NODE" ]; then
    echo -e "${GREEN}[✓] Qualcomm DRM Node Found: $DRM_NODE${NC}"
else
    echo -e "${YELLOW}[!] DRM Node not found. Checking MediaTek / Sysfs HBM nodes...${NC}"
    SYSFS_HBM=$(find /sys -iname "*hbm*" 2>/dev/null | head -n 1)
    if [ -n "$SYSFS_HBM" ]; then
        echo -e "${GREEN}[✓] Found Sysfs HBM Fallback Node: $SYSFS_HBM${NC}"
    fi
fi

# ------------------------------------------------------------------------------
# 4. Calibrate Local-HBM Parameters Interactively
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 4/6] Calibrating DRM Local-HBM (LHBM) Display Parameters...${NC}"

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

PRESETS=(
    "2 2 0"
    "1 1 0"
    "2 1 0"
    "1 2 0"
)

PARAM_P0="2"
PARAM_P1="2"
PARAM_P2="0"

for preset in "${PRESETS[@]}"; do
    echo ""
    echo -e "${YELLOW}Testing DRM Parameters: $preset ...${NC}"
    /tmp/test_lhbm $preset
    read -p "Did the fingerprint area / screen illuminate with Local-HBM high brightness? (y/N): " RESP
    if [[ "$RESP" =~ ^[Yy]$ ]]; then
        PARAM_P0=$(echo $preset | awk '{print $1}')
        PARAM_P1=$(echo $preset | awk '{print $2}')
        PARAM_P2=$(echo $preset | awk '{print $3}')
        echo -e "${GREEN}[✓] Confirmed LHBM Parameters: P0=$PARAM_P0, P1=$PARAM_P1, P2=$PARAM_P2${NC}"
        break
    else
        /tmp/test_lhbm 0 0 0 2>/dev/null || true
    fi
done

# Turn off test illumination
/tmp/test_lhbm 0 0 0 2>/dev/null || true

# ------------------------------------------------------------------------------
# 5. Patch Source Code
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 5/6] Patching src/moto_fod_bridge.cpp with discovered values...${NC}"

sed -i "s|static const char\* INPUT_EVENT_NODE = .*;|static const char\* INPUT_EVENT_NODE = \"$DETECTED_EVENT\";|" src/moto_fod_bridge.cpp
sed -i "s|static int TARGET_KEYCODE = .*;|static int TARGET_KEYCODE = $CHOSEN_KEY;|" src/moto_fod_bridge.cpp
sed -i "s|static const char\* SYSFS_FOD_EN = .*;|static const char\* SYSFS_FOD_EN = \"$DETECTED_SYSFS\";|" src/moto_fod_bridge.cpp
sed -i "s|static int PARAM_P0 = .*;|static int PARAM_P0 = $PARAM_P0;|" src/moto_fod_bridge.cpp
sed -i "s|static int PARAM_P1 = .*;|static int PARAM_P1 = $PARAM_P1;|" src/moto_fod_bridge.cpp
sed -i "s|static int PARAM_P2 = .*;|static int PARAM_P2 = $PARAM_P2;|" src/moto_fod_bridge.cpp

echo -e "${GREEN}[✓] src/moto_fod_bridge.cpp successfully updated!${NC}"

# ------------------------------------------------------------------------------
# 6. Compile & Package Module
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 6/6] Compiling Binary and Building Magisk Module...${NC}"

mkdir -p magisk_module/vendor/bin
mkdir -p out

clang++ -std=c++17 -O3 \
    src/moto_fod_bridge.cpp \
    -o magisk_module/vendor/bin/moto_fod_bridge \
    -lpthread -ldl

if [ -f "magisk_module/vendor/bin/moto_fod_bridge" ]; then
    echo -e "${GREEN}[✓] Compilation successful!${NC}"
else
    echo -e "${RED}[X] Compilation failed. Check compiler errors.${NC}"
    exit 1
fi

if [ -f "zip_module.sh" ]; then
    sed -i '1s|.*|#!/data/data/com.termux/files/usr/bin/bash|' zip_module.sh
    bash zip_module.sh
fi

echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}🎉 PORTING COMPLETE!${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "Your customized Magisk/KSU module has been built."
echo -e "Flash the ZIP in Magisk / KernelSU / APatch and reboot."
echo ""
echo -e "${YELLOW}💡 Live Debugging Commands:${NC}"
echo -e "If you flash the module and need to debug:"
echo -e "  ${BLUE}su -c '/vendor/bin/moto_fod_bridge --debug'${NC} (Live Terminal Diagnostics)"
echo -e "  ${BLUE}su -c '/vendor/bin/moto_fod_bridge --log'${NC}   (Saves to /sdcard/fod_bridge_debug.log)"
