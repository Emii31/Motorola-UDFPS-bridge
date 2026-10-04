# Motorola Native Local-HBM UDFPS Bridge

```{=html}
<p align="center">
```
`<img src="https://img.shields.io/badge/Android-GSI-green?style=for-the-badge" alt="Android GSI">`{=html}
`<img src="https://img.shields.io/badge/Motorola-UDFPS-blue?style=for-the-badge" alt="Motorola UDFPS">`{=html}
`<img src="https://img.shields.io/badge/Local--HBM-Universal-orange?style=for-the-badge" alt="Local HBM">`{=html}
`<img src="https://img.shields.io/badge/Magisk-Module-red?style=for-the-badge" alt="Magisk">`{=html}
`<img src="https://img.shields.io/badge/C%2B%2B17-purple?style=for-the-badge" alt="C++17">`{=html}
```{=html}
</p>
```
> A native C++ bridge for restoring optical **under-display fingerprint
> (UDFPS/FOD)** functionality on supported Motorola devices running a
> **GSI ROM**, using device-specific vendor fingerprint interfaces and
> display Local-HBM controls.

------------------------------------------------------------------------

## 📖 Table of Contents

-   [1. The Story](#1-the-story)
-   [2. What Was Actually Broken](#2-what-was-actually-broken)
-   [3. The Solution](#3-the-solution)
-   [4. How the Bridge Works](#4-how-the-bridge-works)
-   [5. Universal Motorola Hardware
    Fallbacks](#5-universal-motorola-hardware-fallbacks)
-   [6. Prerequisites](#6-prerequisites)
-   [7. Automated One-Command Setup &
    Porting](#7-automated-one-command-setup--porting)
-   [8. Diagnostics & Logging](#8-diagnostics--logging)
-   [9. Manual Porting to Your Device](#9-manual-porting-to-your-device)
-   [10. Build & Installation](#10-build--installation)
-   [11. Testing the Fingerprint](#11-testing-the-fingerprint)
-   [12. Troubleshooting](#12-troubleshooting)
-   [13. Reference Devices](#13-reference-devices)
-   [14. Repository Structure](#14-repository-structure)
-   [15. License & Disclaimer](#15-license--disclaimer)

------------------------------------------------------------------------

# 1. The Story

When running a **GSI on a Motorola device with an optical fingerprint
sensor**, the GSI may detect the fingerprint hardware incorrectly,
sometimes presenting it as a physical or rear-mounted fingerprint
sensor.

The first step is usually fixing the framework/SystemUI UDFPS overlay so
the fingerprint icon appears in the correct location.

But that is only the visible part.

The display still needs to illuminate the small area above the optical
sensor, and the vendor fingerprint implementation still needs to receive
the correct FOD events.

This project was born from that problem:

1.  A Motorola optical-fingerprint device was running a GSI.
2.  The GSI showed the fingerprint sensor in the wrong place.
3.  A UDFPS overlay corrected the fingerprint icon position.
4.  The icon appeared correctly, but enrollment and unlocking still
    failed.
5.  The display did not provide the required Local-HBM illumination.
6.  Instead of replacing the complete vendor fingerprint stack, the
    project uses a small native bridge to connect the GSI biometric
    session with the existing vendor-side hardware interfaces.

The important idea is simple:

> **Fix the missing bridge between the GSI and the hardware instead of
> rebuilding the entire vendor fingerprint stack.**

------------------------------------------------------------------------

# 2. What Was Actually Broken

An optical fingerprint sensor needs the display to illuminate the area
directly above the sensor so the sensor can read reflected light.

A simplified stock implementation looks like:

``` text
Motorola Display / DRM / Panel
            │
            ▼
       Local-HBM
            │
            ▼
 Optical Fingerprint Sensor
            │
            ▼
       Vendor HAL
            │
            ▼
        TrustZone
```

On a GSI, the Android framework may correctly request authentication,
but the device-specific connection between the biometric framework, FOD
input event, display Local-HBM control, and Motorola fingerprint
implementation may be missing or incompatible.

That is why simply moving the fingerprint icon is often not enough.

------------------------------------------------------------------------

# 3. The Solution

This project provides a small native C++ middleware process.

``` text
                GSI / AOSP UI
                      │
                      ▼
             Biometric Session
                      │
                      ▼
             Native C++ Bridge
              /             \
             ▼               ▼
     FOD Touch Event       Local-HBM
             │            DRM / Sysfs
             │               │
             └───────┬───────┘
                     ▼
          Vendor Fingerprint Interface
                     │
                     ▼
             Optical Fingerprint
```

The bridge watches for biometric sessions, listens for the
fingerprint-related input event, enables Local-HBM while the finger is
being read, and sends the appropriate FOD event to the vendor
implementation.

This does **not** mean every Motorola device can use the exact same
binary unchanged. Different Motorola generations can have different
SoCs, display drivers, panel controls, touch controllers, fingerprint
libraries, HIDL interfaces, input event nodes, and sysfs paths.

The goal is to make the **porting process** easier and provide multiple
detection/control paths where possible.

------------------------------------------------------------------------

# 4. How the Bridge Works

The bridge performs four main jobs.

### 1. Monitor biometric sessions

It listens to relevant `logcat` output to determine when a fingerprint
authentication or enrollment session is active. This prevents normal
screen touches from unnecessarily triggering fingerprint hardware.

### 2. Detect FOD touch events

It monitors a Linux input event device such as `/dev/input/event10` and
watches the configured fingerprint-related keycode.

### 3. Control Local-HBM

When a fingerprint touch begins, the bridge attempts to enable the
configured display illumination method. Depending on the device, this
may be a Qualcomm DRM/MDSS ioctl, display sysfs, panel HBM node, or
another device-specific mechanism.

### 4. Notify the fingerprint implementation

The bridge sends the required FOD event to the vendor fingerprint
interface.

For the original Boston reference implementation, this uses Motorola's
`IMotoFingerPrint` HIDL interface and `sendFodEvent()`.

------------------------------------------------------------------------

# 5. Universal Motorola Hardware Fallbacks

Motorola devices are not identical. A solution that works on one phone
can fail on another because the display and fingerprint implementation
are different.

The porting system therefore allows multiple hardware paths.

> **Important:** These fallback paths are reference/detection targets,
> not a guarantee that every listed path is automatically supported by
> the current C++ binary. A new device may require source changes.

## A. Display Local-HBM Engines

Possible display control paths include:

### Qualcomm DRM / MDSS

``` text
/dev/dri/card0
```

The original Boston implementation uses:

``` text
DRM_IOCTL_MDSS_DISP_PARAM = 0xc008649f
```

### Display sysfs

Possible examples include:

``` text
/sys/class/drm/card0-DSI-1/dimlayer_hbm
/sys/devices/platform/soc/soc:qcom,dsi-display-primary/hbm
```

### Backlight / panel nodes

Possible examples include:

``` text
/sys/class/backlight/panel0-backlight/hbm_mode
```

The correct path and values must be verified on the target device. Do
not assume that a path from another Motorola model will work.

## B. Biometric HAL Libraries

Possible vendor-side fingerprint libraries may include:

``` text
/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
/vendor/lib64/hw/android.hardware.biometrics.fingerprint@2.1-service-jv.so
/vendor/lib64/hw/android.hardware.biometrics.fingerprint@2.1-service.so
/vendor/lib64/hw/fingerprint.default.so
```

### Important compatibility note

The current Boston reference implementation directly resolves
Motorola-specific HIDL symbols from
`com.motorola.hardware.biometric.fingerprint@1.0.so`.

Therefore, simply changing the `.so` path does **not** automatically
make the C++ code compatible with another fingerprint HAL. If the target
library exposes a different API or different symbols, the bridge must be
adapted to that implementation.

## C. Touch Keycodes

Possible fingerprint-related input events include:

``` text
704 / 0x2c0
330 / 0x140
```

The correct event node and keycode must be verified on the target
device. Do not assume `/dev/input/event10` is universal.

------------------------------------------------------------------------

# 6. Prerequisites

You should have:

-   A Motorola device with an optical UDFPS/FOD sensor.
-   A GSI/AOSP-based ROM.
-   Root access through Magisk, KernelSU, APatch, or an equivalent
    method.
-   A working UDFPS framework/SystemUI overlay, or at least the ability
    to configure one.
-   [Termux](https://f-droid.org/en/packages/com.termux/) or another
    Android terminal environment.
-   A complete backup or a reliable recovery/firmware restore method.
-   A USB/ADB connection is strongly recommended while testing.

For building:

-   Git
-   Clang/C++17 toolchain
-   ZIP utility
-   Android-compatible shell tools

The repository's build scripts can be used where supported.

------------------------------------------------------------------------

# 7. Automated One-Command Setup & Porting

The project includes `port_fod.sh` to make device discovery and porting
easier.

From Termux:

``` bash
git clone https://github.com/Emii31/Motorola-UDFPS-bridge.git
cd Motorola-UDFPS-bridge
bash port_fod.sh
```

If the script is being executed from a root shell and the Termux `PATH`
is unavailable, use the Termux bash binary explicitly:

``` bash
/data/data/com.termux/files/usr/bin/bash port_fod.sh
```

The exact capabilities of `port_fod.sh` depend on the current script
version. A properly ported device should still be manually verified
before flashing.

The most important values to verify are:

``` text
FOD input event node
FOD keycode
FOD sysfs node
Fingerprint vendor library/interface
DRM/display node
Local-HBM parameters
```

------------------------------------------------------------------------

# 8. Diagnostics & Logging

Low-level fingerprint/display problems are much easier to debug when the
bridge can produce a live log.

The recommended workflow is to run the bridge manually first, verify its
output, and only then rely on the boot service.

## A. Live Debug Mode

If the current binary supports the logging/debug option:

``` bash
su
/vendor/bin/moto_fod_bridge --debug
```

or:

``` bash
su
/vendor/bin/moto_fod_bridge -d
```

The debug output should help identify:

-   which device nodes were opened,
-   which fingerprint library/interface was loaded,
-   biometric session state,
-   received FOD input events,
-   Local-HBM enable/disable attempts,
-   ioctl or sysfs failures,
-   FOD event dispatch,
-   session disarming.

## B. `--log` / `-l`

If the newer logging implementation uses the dedicated log option:

``` bash
su
/vendor/bin/moto_fod_bridge --log
```

or:

``` bash
su
/vendor/bin/moto_fod_bridge -l
```

Use the option supported by the binary you actually built.

> **Important:** README documentation does not add CLI options by
> itself. The C++ binary must actually implement `--debug`, `-d`,
> `--log`, or `-l` before those commands will work.

## C. Save a Debug Log

``` bash
su
/vendor/bin/moto_fod_bridge --debug > /sdcard/fod_bridge_debug.log 2>&1
```

or:

``` bash
su
/vendor/bin/moto_fod_bridge --log > /sdcard/fod_bridge_debug.log 2>&1
```

Then inspect it with:

``` bash
cat /sdcard/fod_bridge_debug.log
```

## D. Collect Supporting Android Logs

``` bash
su
logcat -b all -v time \
  -s BiometricService:D \
     UdfpsController:D \
     FingerprintService:D \
     AuthService:D \
     KeyguardUpdateMonitor:D \
     KeyguardViewMediator:D
```

For a broader capture:

``` bash
su
logcat -b all -v time > /sdcard/fod_logcat.txt
```

Then reproduce enrollment/authentication and stop the capture.

## E. Check the Module Startup Log

If the module's `service.sh` writes a startup log, check:

``` bash
su
cat /data/local/tmp/moto_fod_bridge.log
```

If that file does not exist, inspect the module's `service.sh` and use
the log location configured by that version.

------------------------------------------------------------------------

# 9. Manual Porting to Your Device

When automatic detection is not enough, port the bridge manually.

## Step 1 --- Find the fingerprint input event

``` bash
su
getevent -l
```

Touch or interact with the fingerprint area during an active fingerprint
operation. Look for a fingerprint-related event such as
`/dev/input/event10` and record the event node and keycode.

## Step 2 --- Find FOD-related sysfs nodes

``` bash
su
find /sys -iname "*fod*" 2>/dev/null
find /sys -iname "*finger*" 2>/dev/null
find /sys -iname "*goodix*" 2>/dev/null
```

Verify candidate nodes before using them.

## Step 3 --- Find fingerprint libraries

``` bash
su
ls -l /vendor/lib64/ | grep -i fingerprint
find /vendor/lib64 /vendor/lib -iname "*fingerprint*" 2>/dev/null
ps -A | grep -i finger
getprop | grep -i fingerprint
```

The library name alone is not enough. You also need to know which
API/symbols it exposes.

## Step 4 --- Find the display node

``` bash
su
ls -l /dev/dri/
find /sys/class/drm -type f 2>/dev/null
find /sys/class/backlight -type f 2>/dev/null
find /sys -iname "*hbm*" 2>/dev/null
```

## Step 5 --- Determine Local-HBM parameters

Never copy HBM parameters blindly from another phone. The correct values
depend on the panel and vendor display driver.

For DRM, determine which parameter combination produces the required
local illumination. For sysfs, determine the correct node, accepted
values, enable state, and disable state.

Always verify that the display returns to normal after testing.

## Step 6 --- Update the C++ source

The Boston reference source contains device-specific values such as:

``` cpp
static const char* FOD_EN_NODE =
    "/sys/devices/platform/goodix_ts.0/gesture/fod_en";
```

and:

``` cpp
open("/dev/dri/card0", O_RDWR);
open("/dev/input/event10", O_RDONLY | O_NONBLOCK);
```

These must be changed for another device.

The fingerprint library and Motorola HIDL symbols may also need to be
changed if the target device uses a different vendor implementation.

### Values vs. API porting

Changing:

``` text
event10 → event8
```

is a simple value change.

Changing:

``` text
Motorola HIDL → another fingerprint HAL/API
```

is a code-level port and may require a different implementation.

------------------------------------------------------------------------

# 10. Build & Installation

## Manual Build

From the repository root:

``` bash
bash build.sh
```

Then package the Magisk module:

``` bash
bash zip_module.sh
```

The exact output filename is determined by the current packaging script.

## Install

1.  Open Magisk, KernelSU, or APatch.
2.  Open the Modules section.
3.  Choose **Install from storage**.
4.  Select the generated module ZIP.
5.  Reboot.
6.  Check the module status.

For first-time testing, manual execution from a root shell is
recommended before relying on automatic boot startup.

------------------------------------------------------------------------

# 11. Testing the Fingerprint

### 1. Enrollment

Open:

``` text
Settings → Security → Fingerprint
```

Verify the fingerprint icon is correct, the panel illuminates under the
sensor, touching the sensor produces an FOD event, and enrollment
progresses normally.

### 2. Lock-screen authentication

Lock the phone and unlock it using the fingerprint. Verify that
Local-HBM activates only while authentication is requested.

### 3. Third-party application authentication

Test an application that uses Android biometric authentication.

### 4. Over-trigger protection

Use the phone normally without a biometric prompt. Typing, scrolling, or
tapping the screen should not continuously activate Local-HBM.

### 5. Enrollment timeout

Leave the enrollment screen idle. The bridge should eventually disarm
the sensor if the configured enrollment watchdog is enabled.

------------------------------------------------------------------------

# 12. Troubleshooting

  --------------------------------------------------------------------------------------------------------------------
  Symptom                             Likely cause            What to check
  ----------------------------------- ----------------------- --------------------------------------------------------
  `bash: inaccessible or not found`   Root shell changed      Use
                                      `$PATH`                 `/data/data/com.termux/files/usr/bin/bash port_fod.sh`

  Module installs but nothing happens Service/binary did not  Check module logs and run the binary manually
                                      start                   

  Fingerprint icon is correct but     Wrong Local-HBM control Verify DRM/sysfs node and HBM parameters
  screen does not illuminate                                  

  Screen illuminates but fingerprint  Vendor FOD/HAL          Check loaded library, symbols, and FOD event
  cannot read                         interface mismatch      implementation

  Nothing happens when touching the   Wrong input event       Run `getevent -l`
  sensor                              node/keycode            

  Local-HBM triggers on normal        Biometric session       Inspect `logcat` session transitions
  touches                             filtering mismatch      

  Fingerprint works once and then     Session was not         Capture biometric logs and bridge logs
  stops                               disarmed correctly      

  Enrollment finishes but HBM stays   Watchdog/session-end    Check disarm logs and timeout behavior
  active                              handling failed         

  `dlopen` fails                      Wrong vendor            Verify the library exists and the binary can access it
                                      library/path or linker  
                                      namespace               

  `dlsym` fails                       Vendor interface        Inspect exported symbols and adapt the source
                                      differs                 

  DRM ioctl returns failure           Wrong display driver or Determine the target panel's actual control interface
                                      parameter set           

  `--debug` / `--log` is unknown      Binary does not contain Rebuild with the corresponding CLI logging
                                      the requested option    implementation
  --------------------------------------------------------------------------------------------------------------------

------------------------------------------------------------------------

# 13. Reference Devices

The values below are **reference values**, not universal defaults.

  -----------------------------------------------------------------------------------------
  Model       Codename    Touch Node             Keycode     DRM Node           LHBM Params
  ----------- ----------- ---------------------- ----------- ------------------ -----------
  Moto G      Boston      `/dev/input/event10`   `704` /     `/dev/dri/card0`   `2 2 0`
  Stylus 5G                                      `0x2c0`                        
  2024 /                                                                        
  Boston                                                                        
  reference                                                                     

  Other       Varies      Must detect            Must detect Must detect        Must
  Motorola                                                                      calibrate
  devices                                                                       
  -----------------------------------------------------------------------------------------

Do not assume that a value from the Boston reference device will work on
another Motorola model.

------------------------------------------------------------------------

# 14. Repository Structure

``` text
Motorola-UDFPS-bridge/
│
├── src/
│   └── moto_fod_bridge.cpp      # Native C++ bridge
│
├── magisk_module/
│   ├── module.prop              # Module metadata
│   ├── service.sh               # Late-start boot service
│   └── vendor/
│       └── bin/
│           └── moto_fod_bridge  # Built binary
│
├── port_fod.sh                  # Hardware discovery / porting helper
├── build.sh                     # C++ build script
├── zip_module.sh                # Magisk ZIP packager
├── LICENSE
└── README.md
```

------------------------------------------------------------------------

# 15. License & Disclaimer

This project is licensed under the **[MIT License](LICENSE)**.

You are free to use, modify, and redistribute the project according to
the terms of the license.

### Disclaimer

This is a low-level Android hardware modification project. It can
interact directly with display drivers, kernel input devices, vendor
libraries, biometric services, sysfs nodes, and DRM interfaces.

Incorrect values or incompatible code can cause fingerprint failure,
display problems, service crashes, boot problems, or other unexpected
behavior.

Always keep a working firmware/recovery path and a backup before
testing.

Use this project at your own risk.

------------------------------------------------------------------------

## Important Compatibility Note

This repository aims to make Motorola UDFPS/FOD porting easier and more
universal, but **"universal" does not mean one binary works on every
Motorola phone without modification**.

The intended porting model is:

``` text
Detect hardware
      ↓
Identify display control
      ↓
Identify FOD input
      ↓
Identify fingerprint vendor interface
      ↓
Adapt device-specific values/code
      ↓
Build
      ↓
Test with logging
      ↓
Package as a root module
```

If a Motorola device uses the same underlying interfaces, porting may be
mostly configuration.

If it uses a different display driver or fingerprint HAL/API, additional
C++ changes are required.

That distinction is important for debugging and for contributing support
for new devices.
