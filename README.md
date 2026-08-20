# Motorola Native Local-HBM UDFPS Bridge

<p align="center">
  <img src="https://img.shields.io/badge/Android-GSI-green?style=for-the-badge" alt="Android GSI">
  <img src="https://img.shields.io/badge/Motorola-UDFPS-blue?style=for-the-badge" alt="Motorola UDFPS">
  <img src="https://img.shields.io/badge/Local--HBM-Native-orange?style=for-the-badge" alt="Local HBM">
  <img src="https://img.shields.io/badge/Magisk-Module-red?style=for-the-badge" alt="Magisk">
  <img src="https://img.shields.io/badge/C%2B%2B17-purple?style=for-the-badge" alt="C++17">
</p>

> A small native C++ bridge that restores optical **under-display fingerprint (UDFPS/FOD)** functionality on supported Motorola devices running a **GSI or AOSP-based custom ROM**, by using the existing vendor fingerprint stack and the panel's native Local-HBM mechanism.

---

## 📖 Table of Contents

- [1. The Story](#1-the-story)
- [2. What Was Actually Broken](#2-what-was-actually-broken)
- [3. The Solution](#3-the-solution)
- [4. How the Bridge Works](#4-how-the-bridge-works)
- [5. Prerequisites](#5-prerequisites)
- [6. Before You Start](#6-before-you-start)
- [7. Porting to Your Device](#7-porting-to-your-device)
  - [7.1 Find the FOD Input Event](#71-find-the-fod-input-event)
  - [7.2 Find the FOD Sysfs Node](#72-find-the-fod-sysfs-node)
  - [7.3 Find the Motorola Fingerprint Library](#73-find-the-motorola-fingerprint-library)
  - [7.4 Find the Display DRM Node](#74-find-the-display-drm-node)
  - [7.5 Find the Local-HBM Parameters](#75-find-the-local-hbm-parameters)
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

The GSI detected the fingerprint sensor incorrectly and treated it like a fingerprint sensor mounted on the back of the phone.

So the fingerprint icon appeared in the wrong place.

### The first problem

The first thing I fixed was the UDFPS position using a framework/SystemUI overlay.

After applying the overlay:

- The fingerprint icon appeared in the correct position.
- Android understood that the fingerprint sensor was under the display.
- The UI looked correct.

But the fingerprint still did **not** work.

That led to the second problem.

---

# 2. What Was Actually Broken

The fingerprint icon was now in the correct place, but touching it did nothing useful.

There was:

- ❌ No Local-HBM illumination.
- ❌ No proper optical capture.
- ❌ Fingerprint enrollment failed.
- ❌ Fingerprint unlocking failed.

The problem was not simply the position of the fingerprint icon.

An optical fingerprint sensor needs the display to illuminate the area above the sensor so the sensor can read the reflected light from the finger.

On the stock Motorola firmware, several components work together:

```text
Motorola Display
       ↓
Local-HBM
       ↓
Fingerprint Sensor
       ↓
Motorola Fingerprint HAL
       ↓
TrustZone / TEE
```

The GSI could display the fingerprint UI, but it did not know how to trigger Motorola's proprietary hardware behavior.

---

## The Advice I Got

The obvious solution suggested (because no Custom rom for Boston) by other developers was to:

- Port a donor fingerprint HAL.
- Port/decompile/recompile HIDL components.
- Replace or modify complicated vendor fingerprint components.

That was a much bigger job than I wanted to do.

So instead of replacing the existing vendor fingerprint implementation, I looked at what was **already working in the stock vendor**.

The important discovery was:

> The Motorola fingerprint vendor components were already there.

The missing piece was the bridge between the GSI fingerprint session, the FOD touch event, the display's Local-HBM control and Motorola's fingerprint interface.

That is what this project provides.

---

# 3. The Solution

Instead of replacing the fingerprint HAL, the bridge connects the existing pieces:

```text
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
          Motorola Fingerprint HIDL
                     │
                     ▼
                TrustZone / TEE
                     │
                     ▼
             Optical Fingerprint
```

The bridge is deliberately small.

You do **not** need to build a complete vendor partition.

You do **not** need to port an entire donor fingerprint HAL.

For a compatible device, the main job is finding the device-specific values and changing them in:

```text
src/moto_fod_bridge.cpp
```

---

# 4. How the Bridge Works

The current bridge has four main jobs.

## 4.1 Watch the Android fingerprint session

The bridge streams `logcat` and watches for biometric events.

When fingerprint authentication or enrollment starts:

```text
Sensor Armed
```

When the fingerprint session ends:

```text
Sensor Disarmed
```

The current version also watches additional keyguard and launcher transitions so that the sensor does not remain armed after unlocking.

---

## 4.2 Watch the FOD touch event

The bridge reads the Linux input event device:

```text
/dev/input/eventX
```

When the FOD hardware reports a touch, the bridge detects the configured keycode.

---

## 4.3 Turn on native Local-HBM

When the finger touches the FOD area, the bridge sends:

```text
DRM_IOCTL_MDSS_DISP_PARAM
```

to the display device.

On the reference Boston implementation:

```text
param0 = 2
param1 = 2
param2 = 0
```

This activates the panel's native Local-HBM mode.

The goal is to illuminate only the fingerprint area rather than applying a full-screen software brightness effect.

---

## 4.4 Tell the Motorola fingerprint HAL to capture

The bridge loads the Motorola fingerprint library and calls:

```text
sendFodEvent(0)
```

when capture starts.

After the optical integration period:

```text
sendFodEvent(1)
```

is sent and the display returns to normal mode.

---

# 5. Prerequisites

Before trying this project, you should have:

- A Motorola device with an **optical UDFPS/FOD sensor**.
- A working GSI or AOSP-based custom ROM.
- The device's stock/compatible vendor partition.
- Root access.
- Magisk or KernelSU.
- Termux.
- Basic knowledge of running commands as root.
- A backup of your working firmware/vendor.
- `clang++`.
- `git`.
- `zip`.

Install the basic tools:

```bash
pkg update
pkg install clang git zip -y
```

Check them:

```bash
clang++ --version
git --version
zip -v
```

---

# 6. Before You Start

This project was developed around a **GSI environment**.

The important point is that the GSI and vendor are doing different jobs.

The GSI provides the Android framework/SystemUI.

The vendor partition provides the device-specific hardware implementation.

This bridge is intended to connect the two.

### You should already have:

```text
GSI boots
        ↓
UDFPS overlay works
        ↓
Fingerprint icon appears in correct location
        ↓
Fingerprint still does not illuminate/read
        ↓
Install this bridge
```

If your fingerprint icon is still showing on the back of the phone, **stop here**.

That is a framework/overlay problem, not a Local-HBM bridge problem.

---

# 7. Porting to Your Device

This is the main section if you want to use the project on another Motorola device.

The idea is simple:

> Find the values from your device, replace the corresponding values in `moto_fod_bridge.cpp`, build it, and test it.

Do the steps in order.

---

## 7.1 Find the FOD Input Event

Become root:

```bash
su
```

Run:

```bash
getevent -l
```

Now touch the fingerprint sensor.

You should see input events.

Look for something similar to:

```text
/dev/input/event10
```

and a fingerprint-related keycode such as:

```text
704
```

or:

```text
0x2c0
```

### Example

If your device uses:

```text
/dev/input/event8
```

change:

```cpp
int fd = open("/dev/input/event10", O_RDONLY | O_NONBLOCK);
```

to:

```cpp
int fd = open("/dev/input/event8", O_RDONLY | O_NONBLOCK);
```

Then change the keycode if your device uses a different one:

```cpp
if (ev.type == EV_KEY && (ev.code == 704 || ev.code == 0x2c0))
```

Do **not** assume Boston's values are universal.

---

## 7.2 Find the FOD Sysfs Node

The reference device uses:

```text
/sys/devices/platform/goodix_ts.0/gesture/fod_en
```

Search your device:

```bash
find /sys -iname "*fod*" 2>/dev/null
```

You can also search for Goodix:

```bash
find /sys -iname "*goodix*" 2>/dev/null
```

If your device uses a different path, change:

```cpp
static const char* FOD_EN_NODE =
    "/sys/devices/platform/goodix_ts.0/gesture/fod_en";
```

to your actual path.

For example:

```cpp
static const char* FOD_EN_NODE =
    "/sys/devices/platform/goodix_ts.1/gesture/fod_en";
```

---

## 7.3 Find the Motorola Fingerprint Library

Check:

```bash
su -c 'ls -l /vendor/lib64/ | grep -i motorola.*fingerprint'
```

The reference implementation uses:

```text
/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
```

Check it directly:

```bash
su -c 'ls -l /vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so'
```

If it exists, that's a good sign.

If your device has a different library/version, the `dlopen()` path and HIDL symbols may need to be changed.

Do **not** randomly change the mangled HIDL symbols.

They must correspond to the actual library/interface on your device.

---

## 7.4 Find the Display DRM Node

The reference implementation uses:

```text
/dev/dri/card0
```

Check:

```bash
ls -l /dev/dri/
```

If the display is exposed through another card, change:

```cpp
g_drm_fd = open("/dev/dri/card0", O_RDWR);
```

to the correct device.

---

## 7.5 Find the Local-HBM Parameters

This is usually the most device-specific part.

The Boston reference implementation uses:

```text
param0 = 2
param1 = 2
param2 = 0
```

The source contains these values inside:

```cpp
set_panel_mode()
```

### Test program

Create:

```bash
nano ~/test_lhbm.c
```

Paste:

```c
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

int main(int argc, char **argv)
{
    if (argc != 4) {
        printf("Usage: %s <p0> <p1> <p2>\n", argv[0]);
        return 1;
    }

    int fd = open("/dev/dri/card0", O_RDWR);

    if (fd < 0) {
        perror("open /dev/dri/card0");
        return 1;
    }

    struct disp_param_req req;

    req.param_id = 0;
    req.value = atoi(argv[1]);
    ioctl(fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

    req.param_id = 1;
    req.value = atoi(argv[2]);
    ioctl(fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

    req.param_id = 2;
    req.value = atoi(argv[3]);
    ioctl(fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

    close(fd);
    return 0;
}
```

Compile:

```bash
clang ~/test_lhbm.c -o ~/test_lhbm
```

Run as root:

```bash
su
~/test_lhbm 2 2 0
```

If the correct parameters are already known for your panel, use them.

If they are not known, **do not blindly try random combinations on your device**.

Look at your stock vendor/display implementation, logs or kernel/display sources to determine which parameters are used for FOD Local-HBM.

---

## 7.6 Update the C++ Source

Open:

```bash
nano src/moto_fod_bridge.cpp
```

For a typical port, the main values you may need to change are:

### FOD sysfs node

```cpp
FOD_EN_NODE
```

### Input event device

```cpp
/dev/input/event10
```

### FOD keycode

```cpp
704
```

or:

```cpp
0x2c0
```

### DRM device

```cpp
/dev/dri/card0
```

### Local-HBM parameters

Inside:

```cpp
set_panel_mode()
```

### Motorola fingerprint library

```cpp
/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
```

That's the main customization work.

**Do not rewrite the rest of the program unless your device actually requires it.**

---

# 8. Build the Project

Clone the repository:

```bash
git clone https://github.com/Emii31/Motorola-UDFPS-bridge.git
cd Motorola-UDFPS-bridge
```

Make the build script executable:

```bash
chmod +x build.sh
```

Run:

```bash
./build.sh
```

The included `build.sh` compiles:

```text
src/moto_fod_bridge.cpp
```

into:

```text
magisk_module/vendor/bin/moto_fod_bridge
```

The compiler command used is:

```bash
clang++ -std=c++17 -O3 \
    src/moto_fod_bridge.cpp \
    -o magisk_module/vendor/bin/moto_fod_bridge \
    -lpthread -ldl
```

If this completes successfully, the native binary is ready for packaging.

---

# 9. Build the Magisk Module

Now run:

```bash
chmod +x zip_module.sh
./zip_module.sh
```

The flashable ZIP will be created in:

```text
out/
```

For example:

```text
out/Moto_Native_Local_HBM_FOD_Bridge_v4.zip
```

---

# 10. Install the Module

Transfer the generated ZIP to your phone.

Open:

```text
Magisk
→ Modules
→ Install from storage
```

Select:

```text
Moto_Native_Local_HBM_FOD_Bridge_v4.zip
```

Install it.

Then reboot.

The module's `service.sh` starts the bridge automatically after boot.

---

# 11. Test the Fingerprint

After reboot, test in this order.

### Test 1 — Fingerprint enrollment

Go to:

```text
Settings → Security → Fingerprint
```

Start enrollment.

Touch the fingerprint circle.

You should see:

```text
Fingerprint area illuminated
```

and the sensor should begin reading.

---

### Test 2 — Unlock

Lock the phone.

Touch the fingerprint area.

The expected sequence is:

```text
Finger touches sensor
        ↓
FOD event detected
        ↓
Local-HBM ON
        ↓
sendFodEvent(0)
        ↓
Optical capture
        ↓
~160ms integration
        ↓
Local-HBM OFF
        ↓
sendFodEvent(1)
```

---

### Test 3 — Normal phone usage

After unlocking, test:

- keyboard
- scrolling
- normal touch
- apps
- home screen

The FOD hardware should **not** flash every time you touch the display.

This is important because the bridge must only react while a fingerprint session is active.

---

# 12. Troubleshooting

## Fingerprint icon is still on the back

This bridge does not fix that.

Fix the GSI UDFPS/framework/SystemUI overlay first.

The expected situation before using this bridge is:

```text
Fingerprint icon = correct position
Fingerprint hardware = not working
```

---

## Icon is correct but touching it does nothing

Check:

```bash
getevent -l
```

Make sure your `eventX` and keycode match the values in the C++ source.

---

## `dlopen failed`

Check:

```bash
ls -l /vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
```

Also check for SELinux denials:

```bash
dmesg | grep -i avc
```

The bridge is designed to run through the vendor environment because Android linker namespaces can restrict access to vendor libraries.

---

## Local-HBM doesn't turn on

Your panel probably does not use the Boston values:

```text
2 2 0
```

Find the correct Local-HBM parameters for your device.

---

## HBM works but fingerprint does not enroll

That means the display side is working, but the fingerprint capture side may not be.

Check:

- Motorola fingerprint library.
- HIDL interface/version.
- `sendFodEvent()` symbols.
- FOD payload.
- Input event.
- Vendor fingerprint service.

---

## HBM keeps flashing while typing or scrolling

The biometric session is probably still armed.

The current bridge already includes several protections:

- authentication end detection
- enrollment completion detection
- keyguard transitions
- launcher transitions
- enrollment inactivity watchdog

If your GSI uses different log messages, the strings inside:

```cpp
session_listener_thread()
```

may need to be adjusted.

---

# 13. Boston Reference Values

The original implementation was developed and tested on Motorola **Boston**.

These are the working reference values:

| Component | Boston value |
|---|---|
| FOD input | `/dev/input/event10` |
| FOD keycode | `704 / 0x2c0` |
| FOD sysfs | `/sys/devices/platform/goodix_ts.0/gesture/fod_en` |
| DRM | `/dev/dri/card0` |
| Local-HBM | `param0=2, param1=2, param2=0` |
| Fingerprint library | `/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so` |
| FOD payload | `0x03` |
| Capture event | `sendFodEvent(0)` |
| Release event | `sendFodEvent(1)` |
| Integration period | ~160ms |
| Enrollment watchdog | 2.5 seconds |

**These values are not guaranteed to work on another Motorola device.**

They are provided as the reference implementation.

---

# 14. Repository Structure

```text
Motorola-UDFPS-bridge/
│
├── src/
│   └── moto_fod_bridge.cpp
│
├── magisk_module/
│   ├── module.prop
│   ├── service.sh
│   ├── META-INF/
│   │   └── com/
│   │       └── google/
│   │           └── android/
│   └── vendor/
│       └── bin/
│           └── moto_fod_bridge
│
├── build.sh
├── zip_module.sh
├── LICENSE
└── README.md
```

---

# 15. Contributing

If you successfully port this to another Motorola device, please share the values you discovered.

A useful report looks like:

```text
Device:
Android version:
GSI:
Vendor version:
Fingerprint vendor:
FOD input node:
FOD keycode:
FOD sysfs node:
DRM node:
Local-HBM parameters:
Fingerprint library:
```

This will make future ports much easier.

---

# 16. License

This project is licensed under the **MIT License**.

See the full license here:

**[LICENSE](LICENSE)**

---

# 17. Disclaimer

This project modifies low-level display and fingerprint behavior.

A wrong:

- DRM parameter
- input event
- sysfs node
- vendor library
- HIDL interface
- fingerprint event

can cause crashes, broken fingerprint functionality, display problems, or other unexpected behavior.

**Use at your own risk.**

Always keep a working firmware/vendor backup before experimenting.

---

# ❤️ Final Note

This project started with:

> **"Why does my GSI think my fingerprint sensor is on the back?"**

I fixed the position with an overlay.

Then came the next problem:

> **"The fingerprint is finally in the right place, but it doesn't illuminate and doesn't read my finger."**

The suggested solution was to port a donor fingerprint HIDL.

Instead, I kept the existing Motorola vendor fingerprint stack and built a small native bridge around it.

The result is this project:

```text
GSI
 ↓
Correct UDFPS UI
 ↓
Native C++ bridge
 ↓
Local-HBM
 ↓
Motorola fingerprint HAL
 ↓
Optical fingerprint sensor
```

The purpose of this repository is simple:

**If your Motorola device already has the necessary vendor fingerprint components, you should only need to identify your device-specific values, replace them in the C++ source, build the module, and test it.**
