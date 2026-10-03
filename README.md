# Motorola Native Local-HBM UDFPS Bridge

<p align="center">
  <img src="https://img.shields.io/badge/Android-GSI-green?style=for-the-badge" alt="Android GSI">
  <img src="https://img.shields.io/badge/Motorola-UDFPS-blue?style=for-the-badge" alt="Motorola UDFPS">
  <img src="https://img.shields.io/badge/Local--HBM-Native-orange?style=for-the-badge" alt="Local HBM">
  <img src="https://img.shields.io/badge/Magisk-Module-red?style=for-the-badge" alt="Magisk">
  <img src="https://img.shields.io/badge/C%2B%2B17-purple?style=for-the-badge" alt="C++17">
</p>

> A small native C++ bridge that restores optical **under-display fingerprint (UDFPS/FOD)** functionality on supported Motorola devices running a **GSI ROM**, by using the existing vendor fingerprint stack and the panel's native Local-HBM mechanism.

---

## 📖 Table of Contents

- [1. The Story](#1-the-story)
- [2. What Was Actually Broken](#2-what-was-actually-broken)
- [3. The Solution](#3-the-solution)
- [4. How the Bridge Works](#4-how-the-bridge-works)
- [5. Prerequisites](#5-prerequisites)
- [6. Automated One-Command Setup & Porting (Recommended)](#6-automated-one-command-setup--porting-recommended)
- [7. Manual Porting to Your Device](#7-manual-porting-to-your-device)
  - [7.1 Find the FOD Input Event & Keycode](#71-find-the-fod-input-event--keycode)
  - [7.2 Find the FOD Sysfs Node](#72-find-the-fod-sysfs-node)
  - [7.3 Find the Fingerprint Library & GSI Service Fallbacks](#73-find-the-fingerprint-library--gsi-service-fallbacks)
  - [7.4 Find the Display DRM Node](#74-find-the-display-drm-node)
  - [7.5 Calibrate Local-HBM Parameters](#75-calibrate-local-hbm-parameters)
  - [7.6 Update the C++ Source](#76-update-the-c-source)
- [8. Build the Project](#8-build-the-project)
- [9. Build the Magisk Module](#9-build-the-magisk-module)
- [10. Install the Module](#10-install-the-module)
- [11. Test the Fingerprint](#11-test-the-fingerprint)
- [12. Troubleshooting](#12-troubleshooting)
- [13. Boston Reference Values](#13-boston-reference-values)
- [14. Repository Structure](#14-repository-structure)
- [15. Contributing](#15-contributing)
- [16. License](#16-license)
- [17. Disclaimer](#17-disclaimer)

---

# 1. The Story

This project started with a very simple problem after running a **GSI on a Motorola device with an optical fingerprint sensor**.

The GSI detected the fingerprint sensor incorrectly and treated it like a fingerprint sensor mounted on the back of the phone, showing the icon in the wrong location.

### The first problem

The first thing I fixed was the UDFPS position using a framework/SystemUI overlay:

- The fingerprint icon appeared in the correct position.
- Android understood that the fingerprint sensor was under the display.
- The UI looked correct.

But the fingerprint still did **not** work. That led to the second problem.

---

# 2. What Was Actually Broken

The fingerprint icon was now in the correct place, but touching it did nothing useful.

There was:

- ❌ No Local-HBM illumination.
- ❌ No proper optical capture.
- ❌ Fingerprint enrollment failed.
- ❌ Fingerprint unlocking failed.

An optical fingerprint sensor needs the display to illuminate the area above the sensor so it can read the reflected light from your finger.

On stock Motorola firmware, several components work together:


Motorola Display
       ↓
Local-HBM
       ↓
Fingerprint Sensor
       ↓
Motorola Fingerprint HAL
       ↓
TrustZone / TEE

The GSI could display the fingerprint UI, but it did not know how to trigger Motorola's proprietary hardware behavior or talk to the active vendor fingerprint daemon.
3. The Solution
Instead of replacing or porting a massive donor HAL, this bridge acts as a lightweight C++ middleware between GSI biometric sessions, display DRM controls, input events, and vendor fingerprint libraries:
                GSI / AOSP
                    │
                    ▼
            UDFPS Fingerprint UI
                    │
                    ▼
          Biometric Session Events
                    │
                    ▼
             Native C++ Bridge
              /             \
             ▼               ▼
     FOD Touch Event       Local-HBM
             │               │
             └───────┬───────┘
                     ▼
  Motorola / GSI Biometric Fingerprint HAL
                     │
                     ▼
                TrustZone / TEE
                     │
                     ▼
             Optical Fingerprint

4. How the Bridge Works
The bridge handles four main tasks:
 * Watch the Android Biometric Session: Streams logcat for biometric session state (arm/disarm) across system transitions (lockscreen, launcher, apps).
 * Detect Touch Input: Intercepts kernel input events (/dev/input/eventX) for fingerprint touch signals (e.g., keycode 704 / BTN_TRIGGER_HAPPY).
 * Trigger DRM Local-HBM: Sends DRM_IOCTL_MDSS_DISP_PARAM ioctl commands to /dev/dri/card0 to toggle hardware-level high brightness on panel pixels over the sensor area.
 * Communicate with HAL: Calls sendFodEvent(0) / sendFodEvent(1) on the active vendor fingerprint HAL daemon (with fallback support for standard AOSP/Goodix/Jiiov services like android.hardware.biometrics.fingerprint@2.1-service-jv.so).
5. Prerequisites
Before starting, ensure you have:
 * A Motorola device with an optical UDFPS/FOD sensor.
 * A working GSI ROM installed with a UDFPS overlay applied.
 * Root access (Magisk, KernelSU, or APatch).
 * Termux installed.
 * Basic familiarity with terminal commands.
6. Automated One-Command Setup & Porting (Recommended)
An automated tool (port_fod.sh) is included to interactively inspect your hardware, auto-detect touch keycodes, find sysfs nodes, probe running HAL services, calibrate Local-HBM display parameters, update src/moto_fod_bridge.cpp, compile the C++ binary, and build a flashable Magisk ZIP!
Step-by-Step Instructions to Run the Auto-Porter
 * Open Termux on your device.
 * Clone the repository and enter the directory:
   git clone [https://github.com/Emii31/Motorola-UDFPS-bridge.git](https://github.com/Emii31/Motorola-UDFPS-bridge.git)
cd Motorola-UDFPS-bridge

 * Run the automated script:
   bash port_fod.sh

> Note on Root Privileges: The script will automatically request root (su) and configure Termux's execution environment. If you enter su manually before running the script, make sure to execute it with Termux's bash binary path:
> /data/data/com.termux/files/usr/bin/bash port_fod.sh
> 
> 
What the Automated Script Does:
 * Auto-installs dependencies: Automatically fetches clang, git, and zip via pkg if missing.
 * Auto-detects Touch Node & Keycode: Prompts you to hold your finger on the sensor for 7 seconds, then parses /tmp/getevent_test.log to automatically distinguish between keycode 704 (BTN_TRIGGER_HAPPY) and 330 (BTN_TOUCH).
 * Locates Sysfs Gesture Path: Automatically scans /sys for active fod_en or Goodix gesture control nodes.
 * GSI HAL Probing: Scans active background processes (ps) and vendor HAL paths to properly target both Motorola extensions (com.motorola.hardware.biometric.fingerprint@1.0.so) and native GSI fallback services (android.hardware.biometrics.fingerprint@2.1-service-jv.so).
 * Interactive Local-HBM Calibration: Compiles a temporary C binary (test_lhbm.c) and flashes display parameters (2 2 0, 1 1 0, etc.) sequentially. You visually confirm which preset illuminates your panel!
 * Auto-Patching & Build: Modifies src/moto_fod_bridge.cpp with your device's exact discovered parameters, compiles moto_fod_bridge, and packages out/moto_fod_bridge_module.zip.
7. Manual Porting to Your Device
If you prefer to inspect and port values manually instead of using port_fod.sh, follow these steps.
7.1 Find the FOD Input Event & Keycode
Run getevent -l in root shell:
su
getevent -l

Touch the fingerprint sensor. Identify the input node (e.g., /dev/input/event10) and keycode (e.g., 704 / 0x2c0 or 330 / 0x140).
In src/moto_fod_bridge.cpp:
int fd = open("/dev/input/event10", O_RDONLY | O_NONBLOCK);
if (ev.type == EV_KEY && (ev.code == 704 || ev.code == 0x2c0))

7.2 Find the FOD Sysfs Node
Search for your device's FOD enable sysfs node:
find /sys -iname "*fod*" 2>/dev/null

In src/moto_fod_bridge.cpp:
static const char* FOD_EN_NODE = "/sys/devices/platform/goodix_ts.0/gesture/fod_en";

7.3 Find the Fingerprint Library & GSI Service Fallbacks
Locate your vendor fingerprint shared library:
su -c 'ls -l /vendor/lib64/ | grep -i fingerprint'

 * Stock Motorola HAL: /vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
 * GSI / Vendor Service Fallbacks: /vendor/lib64/hw/android.hardware.biometrics.fingerprint@2.1-service-jv.so
In src/moto_fod_bridge.cpp:
static const char* TARGET_LIB = "/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so";

7.4 Find the Display DRM Node
Check your display node (typically /dev/dri/card0):
ls -l /dev/dri/

7.5 Calibrate Local-HBM Parameters
Create test_lhbm.c:
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

Compile and test presets as root:
clang test_lhbm.c -o test_lhbm
su
./test_lhbm 2 2 0

Verify if the screen illuminated the fingerprint circle.
7.6 Update the C++ Source
Update the values in src/moto_fod_bridge.cpp manually if not using port_fod.sh.
8. Build the Project
Run the build script to compile the binary:
chmod +x build.sh
./build.sh

This compiles src/moto_fod_bridge.cpp with C++17 optimizations into magisk_module/vendor/bin/moto_fod_bridge.
9. Build the Magisk Module
Generate the flashable Magisk/KernelSU ZIP module:
chmod +x zip_module.sh
bash zip_module.sh

The output file will be generated in out/:
out/moto_fod_bridge_module.zip

10. Install the Module
 * Open Magisk, KernelSU, or APatch.
 * Go to Modules → Install from storage.
 * Select out/moto_fod_bridge_module.zip.
 * Flash the module and reboot.
11. Test the Fingerprint
 * Enrollment: Go to Settings → Security → Fingerprint. Verify that touching the sensor area triggers Local-HBM illumination and reads your print.
 * Lockscreen Unlock: Lock your phone and touch the FOD circle. Verify:
   Touch detected → Local-HBM ON → sendFodEvent(0) → Optical Capture (~160ms) → Local-HBM OFF → sendFodEvent(1)

 * General Usage: Verify that normal screen touches while scrolling or typing do not trigger Local-HBM when no biometric session is active.
12. Troubleshooting
 * bash: inaccessible or not found when using su:
   Android's native root shell does not include Termux paths in its $PATH. Execute the script with the explicit path:
   /data/data/com.termux/files/usr/bin/bash port_fod.sh

 * Fingerprint icon is on the back of the phone:
   This is a framework overlay issue, not a bridge issue. Apply a SystemUI/UDFPS overlay for your device first.
 * dlopen failed or GSI Service Silent Crash:
   Custom GSIs often run the standard vendor service android.hardware.biometrics.fingerprint@2.1-service-jv.so instead of Motorola extension HALs. port_fod.sh handles this auto-detection during Step 3.
13. Boston Reference Values
Reference configuration values for Motorola Boston:
| Component | Boston Reference Value |
|---|---|
| FOD Input Node | /dev/input/event10 |
| Keycode | 704 / 0x2c0 (BTN_TRIGGER_HAPPY) |
| Sysfs Gesture Node | /sys/devices/platform/goodix_ts.0/gesture/fod_en |
| DRM Device | /dev/dri/card0 |
| Local-HBM Presets | param0=2, param1=2, param2=0 |
| HAL Library | /vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so |
14. Repository Structure
Motorola-UDFPS-bridge/
│
├── src/
│   └── moto_fod_bridge.cpp      # Main C++ Native Bridge
│
├── magisk_module/
│   ├── module.prop              # Magisk module metadata
│   ├── service.sh               # Late-start service daemon launcher
│   ├── META-INF/                # Module installer scripts
│   └── vendor/
│       └── bin/
│           └── moto_fod_bridge  # Compiled binary output
│
├── port_fod.sh                  # Interactive automated porter & builder
├── build.sh                     # Manual C++ compiler script
├── zip_module.sh                # Module packager script
├── LICENSE
└── README.md

15. Contributing
Ported this bridge to another Motorola device? Submit a PR or open an issue with your device specifications:
Device:
Android / GSI Version:
FOD Input Node:
Keycode:
DRM Local-HBM Parameters:
HAL Library / Service:

16. License
Licensed under the MIT License.
17. Disclaimer
This software modifies display driver parameters and low-level biometric hardware interfaces. Use at your own risk. Always maintain a stock boot/vendor backup before flashing custom hardware modules.

