#!/data/data/com.termux/files/usr/bin/bash

# ==============================================================================
# Automated Motorola / GSI Local-HBM UDFPS Bridge Porting Tool for Termux
# ==============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}======================================================"${NC}
echo -e "${CYAN}   Motorola/GSI Local-HBM UDFPS Bridge Auto-Porter   "${NC}
echo -e "${CYAN}======================================================"${NC}
echo ""

# ------------------------------------------------------------------------------
# 0. Check Root & Environment Setup
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}[!] This script requires root access to inspect devices and HALs.${NC}"
    echo -e "${YELLOW}[*] Relaunching with su...${NC}"
    exec su -c "bash $0 $@"
fi

echo -e "${GREEN}[✓] Root access granted.${NC}"

# Check for required tools
for tool in clang++ zip git; do
    if ! command -v $tool &> /dev/null; then
        echo -e "${YELLOW}[*] Installing missing dependency: $tool...${NC}"
        pkg install $tool -y
    fi
done

# Ensure C++ source exists
if [ ! -f "src/moto_fod_bridge.cpp" ]; then
    echo -e "${RED}[X] Error: src/moto_fod_bridge.cpp not found. Please run this script from the root of the repository.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Detect Input Event & Keycodes
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 1/6] Detecting Fingerprint Input Event Node...${NC}"
echo -e "${YELLOW}👉 Touch and hold the fingerprint sensor area on your screen now...${NC}"
echo -e "${YELLOW}   (Waiting 7 seconds for touch events)${NC}"

# Capture getevent output for 7 seconds
GE_LOG="/tmp/getevent_test.log"
getevent -l > "$GE_LOG" &
GE_PID=$!
sleep 7
kill $GE_PID 2>/dev/null || true

# Parse log for input node
DETECTED_EVENT=$(grep -E "BTN_TOUCH|BTN_TRIGGER_HAPPY|02c0|704" "$GE_LOG" | head -n 1 | awk '{print $1}' | tr -d ':')

if [ -z "$DETECTED_EVENT" ]; then
    echo -e "${RED}[!] Could not automatically detect input node during touch.${NC}"
    read -p "Enter your input event node manually (e.g., /dev/input/event8): " DETECTED_EVENT
else
    echo -e "${GREEN}[✓] Detected Input Node: $DETECTED_EVENT${NC}"
fi

# Ask keycode preference
echo -e "Which keycode did your touch trigger?"
echo "1) BTN_TRIGGER_HAPPY (704 / 0x2c0) [Default]"
echo "2) BTN_TOUCH (330 / 0x140)"
echo "3) Custom Keycode"
read -p "Select option [1-3]: " KEY_CHOICE

case $KEY_CHOICE in
    2) CHOSEN_KEY="330" ;;
    3) read -p "Enter custom keycode (decimal): " CHOSEN_KEY ;;
    *) CHOSEN_KEY="704" ;;
esac

# ------------------------------------------------------------------------------
# 2. Detect FOD Sysfs Node
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 2/6] Detecting FOD Sysfs Gesture Node...${NC}"

SYSFS_NODES=$(find /sys -iname "*fod*" 2>/dev/null | grep -i "gesture" || true)

if [ -z "$SYSFS_NODES" ]; then
    SYSFS_NODES=$(find /sys -iname "*goodix*" 2>/dev/null | grep -i "fod" || true)
fi

if [ -n "$SYSFS_NODES" ]; then
    DETECTED_SYSFS=$(echo "$SYSFS_NODES" | head -n 1)
    echo -e "${GREEN}[✓] Found FOD Sysfs Node: $DETECTED_SYSFS${NC}"
else
    echo -e "${YELLOW}[!] Automatic FOD sysfs search failed.${NC}"
    DETECTED_SYSFS="/sys/devices/platform/goodix_ts.0/gesture/fod_en"
    read -p "Enter FOD sysfs node path [$DETECTED_SYSFS]: " USER_SYSFS
    [ -n "$USER_SYSFS" ] && DETECTED_SYSFS=$USER_SYSFS
fi

# ------------------------------------------------------------------------------
# 3. Detect Biometric Service & Library (With GSI Fallback Support)
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 3/6] Detecting Active Biometric Service & Library...${NC}"

# Check running processes to see if GSI or Stock daemon is active
RUNNING_SERVICE=$(ps -A | grep -E "fingerprint|biometric" | awk '{print $NF}' | head -n 1 || true)

if [ -n "$RUNNING_SERVICE" ]; then
    echo -e "${GREEN}[✓] Active Fingerprint Process: $RUNNING_SERVICE${NC}"
fi

# Priority library candidates: GSI native vendor HALs first, then Motorola extensions
POSSIBLE_LIBS=(
    "/vendor/lib64/hw/android.hardware.biometrics.fingerprint@2.1-service-jv.so"
    "/vendor/lib64/hw/android.hardware.biometrics.fingerprint@2.1-service.so"
    "/vendor/lib64/hw/fingerprint.default.so"
    "/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so"
)

DETECTED_LIB=""
for lib in "${POSSIBLE_LIBS[@]}"; do
    if [ -f "$lib" ]; then
        DETECTED_LIB="$lib"
        echo -e "${GREEN}[✓] Target HAL Library Matched: $DETECTED_LIB${NC}"
        break
    fi
done

if [ -z "$DETECTED_LIB" ]; then
    echo -e "${YELLOW}[!] Target HAL library not found in default paths. Searching /vendor/lib64...${NC}"
    FOUND_LIBS=$(find /vendor/lib64/ -name "*fingerprint*" 2>/dev/null || true)
    if [ -n "$FOUND_LIBS" ]; then
        DETECTED_LIB=$(echo "$FOUND_LIBS" | head -n 1)
        echo -e "${YELLOW}[!] Selected fallback library: $DETECTED_LIB${NC}"
    else
        DEFAULT_FALLBACK="/vendor/lib64/hw/android.hardware.biometrics.fingerprint@2.1-service-jv.so"
        read -p "Enter vendor fingerprint library path [$DEFAULT_FALLBACK]: " USER_LIB
        DETECTED_LIB=${USER_LIB:-$DEFAULT_FALLBACK}
    fi
fi

# ------------------------------------------------------------------------------
# 4. Interactive Local-HBM (LHBM) DRM Parameter Calibration
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 4/6] Calibrating DRM Local-HBM (LHBM) Display Parameters...${NC}"

# Compile temporary test executable
cat << 'EOF' > /tmp/test_lhbm.c
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>

struct disp_param_req {
    uint32_t param_id;
    int32_t value;
};

#define DRM_IOCTL_MDSS_DISP_PARAM 0xc008649f

int main(int argc, char **argv) {
    if (argc != 5) {
        printf("Usage: %s <drm_dev> <p0> <p1> <p2>\n", argv[0]);
        return 1;
    }

    int fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open drm device failed");
        return 1;
    }

    struct disp_param_req req;
    req.param_id = 0; req.value = atoi(argv[2]);
    ioctl(fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

    req.param_id = 1; req.value = atoi(argv[3]);
    ioctl(fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

    req.param_id = 2; req.value = atoi(argv[4]);
    ioctl(fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

    close(fd);
    return 0;
}
EOF

clang /tmp/test_lhbm.c -o /tmp/test_lhbm

DRM_DEV="/dev/dri/card0"
if [ ! -c "$DRM_DEV" ]; then
    read -p "Enter DRM device node [/dev/dri/card0]: " USER_DRM
    DRM_DEV=${USER_DRM:-"/dev/dri/card0"}
fi

PARAM_PRESETS=(
    "2 2 0"  # Boston / G85 default
    "1 1 0"  # Alternative OLED
    "2 1 0"  # Variant 3
    "1 2 0"  # Variant 4
)

WORKING_P0=2
WORKING_P1=2
WORKING_P2=0

echo -e "${YELLOW}Starting Local-HBM panel test. Watch your screen closely!${NC}"

LHBM_CONFIRMED=false
for preset in "${PARAM_PRESETS[@]}"; do
    echo ""
    echo -e "${CYAN}Testing DRM Parameters: $preset ...${NC}"
    /tmp/test_lhbm "$DRM_DEV" $preset
    sleep 1
    
    read -p "Did the fingerprint area / screen illuminate with Local-HBM high brightness? (y/N): " CONFIRM
    
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        read -r WORKING_P0 WORKING_P1 WORKING_P2 <<< "$preset"
        LHBM_CONFIRMED=true
        
        # Reset display back to normal
        /tmp/test_lhbm "$DRM_DEV" $WORKING_P0 0 $WORKING_P2 2>/dev/null || true
        echo -e "${GREEN}[✓] Confirmed LHBM Parameters: P0=$WORKING_P0, P1=$WORKING_P1, P2=$WORKING_P2${NC}"
        break
    else
        # Reset display before next test
        /tmp/test_lhbm "$DRM_DEV" 2 0 0 2>/dev/null || true
    fi
done

if [ "$LHBM_CONFIRMED" = false ]; then
    echo -e "${YELLOW}[!] None of the preset values worked.${NC}"
    read -p "Enter custom LHBM parameters (p0 p1 p2) [e.g. 2 2 0]: " CUSTOM_P
    if [ -n "$CUSTOM_P" ]; then
        read -r WORKING_P0 WORKING_P1 WORKING_P2 <<< "$CUSTOM_P"
    fi
fi

# ------------------------------------------------------------------------------
# 5. Automatically Patch C++ Source File
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 5/6] Patching src/moto_fod_bridge.cpp with discovered values...${NC}"

# Backup original cpp file
cp src/moto_fod_bridge.cpp src/moto_fod_bridge.cpp.bak

# Update values in C++ source using sed
sed -i "s|/dev/input/event[0-9]*|$DETECTED_EVENT|g" src/moto_fod_bridge.cpp
sed -i "s|/sys/devices/platform/goodix_ts[^\"]*|$DETECTED_SYSFS|g" src/moto_fod_bridge.cpp
sed -i "s|/vendor/lib64/[^\"]*\.so|$DETECTED_LIB|g" src/moto_fod_bridge.cpp
sed -i "s|/dev/dri/card[0-9]*|$DRM_DEV|g" src/moto_fod_bridge.cpp

# Patch LHBM parameters inside C++ array if present
sed -i "s|req.value = [0-9]*; // p0|req.value = $WORKING_P0; // p0|g" src/moto_fod_bridge.cpp
sed -i "s|req.value = [0-9]*; // p1|req.value = $WORKING_P1; // p1|g" src/moto_fod_bridge.cpp

echo -e "${GREEN}[✓] src/moto_fod_bridge.cpp successfully updated!${NC}"

# ------------------------------------------------------------------------------
# 6. Build Executable and Generate Magisk Module
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[Step 6/6] Compiling Binary and Building Magisk Module...${NC}"

mkdir -p magisk_module/vendor/bin
mkdir -p out

# Compile binary
clang++ -std=c++17 -O3 \
    src/moto_fod_bridge.cpp \
    -o magisk_module/vendor/bin/moto_fod_bridge \
    -lpthread -ldl

if [ -f "magisk_module/vendor/bin/moto_fod_bridge" ]; then
    echo -e "${GREEN}[✓] Compilation successful!${NC}"
else
    echo -e "${RED}[X] Compilation failed. Check errors above.${NC}"
    exit 1
fi

# Package module ZIP
if [ -f "zip_module.sh" ]; then
    chmod +x zip_module.sh
    ./zip_module.sh
else
    echo -e "${YELLOW}[*] Zipping module...${NC}"
    cd magisk_module
    zip -r ../out/moto_fod_bridge_module.zip ./*
    cd ..
fi

echo ""
echo -e "${GREEN}======================================================"${NC}
echo -e "${GREEN}🎉 PORTING COMPLETE!${NC}"
echo -e "${GREEN}======================================================"${NC}
echo -e "Your customized Magisk/KSU module has been built in the ${CYAN}out/${NC} directory."
echo -e "Flash the ZIP in Magisk / KernelSU / APatch and reboot!"
