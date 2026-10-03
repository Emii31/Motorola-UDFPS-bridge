from pathlib import Path
readme = """# Motorola Native Local-HBM UDFPS Bridge

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

This project started with a simple problem after running a **GSI on a Motorola device with an optical fingerprint sensor**.

The GSI detected the fingerprint sensor incorrectly and treated it like a fingerprint sensor mounted on the back of the phone.

### The first problem

I first fixed the UDFPS position using a framework/SystemUI overlay:

- The fingerprint icon appeared in the correct position.
- Android understood that the sensor was under the display.
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

An optical fingerprint sensor needs the display to illuminate the area above the sensor so it can read the reflected light from your finger.

On stock Motorola firmware, several components work together:

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

The GSI could display the fingerprint UI, but it did not know how to trigger Motorola's proprietary hardware behavior or communicate with the vendor fingerprint stack correctly.

### The advice I received

The obvious suggestion was to port or borrow a fingerprint HIDL/HAL from a donor device.

That would mean dealing with a much larger vendor-side port.

Instead, this project took another approach: **use the vendor components that are already present and build a small bridge around them.**

---

# 3. The Solution

The bridge acts as lightweight C++ middleware between:

- GSI/AOSP biometric sessions
- FOD touch events
- The display's DRM Local-HBM interface
- The existing vendor fingerprint interface

The basic idea is:

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
          Vendor Fingerprint Stack
                     │
                     ▼
                TrustZone / TEE
                     │
                     ▼
             Optical Fingerprint
```

The important part is that the project does **not** try to replace the entire fingerprint HAL.

Instead, it tries to connect the GSI's biometric session with the hardware functions that already exist in the vendor implementation.

---

# 4. How the Bridge Works

The bridge handles four main tasks.

### 1. Watch the biometric session

It streams relevant `logcat` output and watches for biometric, enrollment, lockscreen, launcher, and authentication transitions.

This tells the bridge when the fingerprint sensor should be armed or disarmed.

### 2. Detect FOD touch input

It monitors the device's input event node:

```text
/dev/input/eventX
```

and looks for the FOD-specific keycode.

On Boston, this is:

```text
704 / 0x2c0
```

### 3. Trigger native Local-HBM

It opens the display DRM device:

```text
/dev/dri/card0
```

and sends:

```text
DRM_IOCTL_MDSS_DISP_PARAM
```

parameters to enable or disable the panel's Local-HBM mode.

On Boston:

```text
param0 = 2
param1 = 2
param2 = 0
```

### 4. Trigger the fingerprint capture event

When a valid FOD touch is detected:

```text
sendFodEvent(0)
```

is sent to start the capture sequence.

After the short optical integration period:

```text
sendFodEvent(1)
```

is sent and the display is returned to normal.

---

# 5. Prerequisites

Before starting, make sure you have:

- A Motorola device with an **optical UDFPS/FOD sensor**.
- A working **GSI / AOSP-based ROM**.
- A working UDFPS framework/SystemUI overlay for your device.
- Root access through **Magisk, KernelSU, or APatch**.
- **Termux** installed.
- Internet access in Termux.
- Basic familiarity with terminal commands.
- A working way to restore your stock firmware/vendor setup.

> **Important:** This project was developed and tested on a Motorola device running a GSI. It is not guaranteed to work on every Motorola device.

---

# 6. Automated One-Command Setup & Porting (Recommended)

The repository includes an automated helper:

```text
port_fod.sh
```

The goal is simple:

> Find your device-specific values, put them into the bridge, build it, and package the module without manually porting an entire vendor fingerprint HAL.

## Step 1 — Open Termux

Open Termux on your rooted GSI device.

## Step 2 — Clone the repository

```bash
git clone https://github.com/Emii31/Motorola-UDFPS-bridge.git
cd Motorola-UDFPS-bridge
```

## Step 3 — Run the auto-porter

```bash
bash port_fod.sh
```

If Android's root shell cannot find Termux's Bash binary, use:

```bash
/data/data/com.termux/files/usr/bin/bash port_fod.sh
```

### What the script does

Depending on the current script version, it can help with:

1. Installing required Termux packages such as `clang`, `git`, and `zip`.
2. Detecting the FOD input node and keycode.
3. Finding FOD/Goodix sysfs nodes.
4. Inspecting available fingerprint HAL libraries/services.
5. Testing Local-HBM parameter combinations.
6. Updating device-specific values in `src/moto_fod_bridge.cpp`.
7. Compiling the C++ bridge.
8. Creating a flashable Magisk module.

> **Important:** Automated detection is a helper, not a guarantee. Review the discovered values before flashing.

---

# 7. Manual Porting to Your Device

If you want to do it manually, the process is straightforward:

```text
Find your values
      ↓
Replace the values in moto_fod_bridge.cpp
      ↓
Run build.sh
      ↓
Run zip_module.sh
      ↓
Flash the generated ZIP
```

You do **not** need to build or replace an entire vendor partition just to test this approach.

---

## 7.1 Find the FOD Input Event & Keycode

Enter a root shell:

```bash
su
```

Then:

```bash
getevent -l
```

Touch the fingerprint sensor repeatedly.

Find an input node such as:

```text
/dev/input/event10
```

and an FOD keycode such as:

```text
704
```

or:

```text
0x2c0
```

In:

```text
src/moto_fod_bridge.cpp
```

you may need to change:

```cpp
int fd = open("/dev/input/event10", O_RDONLY | O_NONBLOCK);
```

and:

```cpp
if (ev.type == EV_KEY && (ev.code == 704 || ev.code == 0x2c0))
```

Use the values reported by your own device.

---

## 7.2 Find the FOD Sysfs Node

Search:

```bash
find /sys -iname "*fod*" 2>/dev/null
```

Or specifically:

```bash
find /sys -name "fod_en" 2>/dev/null
```

Boston uses:

```text
/sys/devices/platform/goodix_ts.0/gesture/fod_en
```

The source contains:

```cpp
static const char* FOD_EN_NODE =
    "/sys/devices/platform/goodix_ts.0/gesture/fod_en";
```

Replace it with your device's actual path.

---

## 7.3 Find the Fingerprint Library & GSI Service

Check the vendor libraries:

```bash
su -c 'ls -l /vendor/lib64/ | grep -i fingerprint'
```

A Motorola vendor implementation may contain:

```text
/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
```

Some GSI/vendor combinations may also use a standard service such as:

```text
android.hardware.biometrics.fingerprint@2.1-service-jv.so
```

> **Important:** Finding a different library does not automatically mean the current C++ source can use it. The source currently relies on Motorola-specific symbols and calling conventions. A genuinely different HAL may require additional source changes.

---

## 7.4 Find the Display DRM Node

Check:

```bash
ls -l /dev/dri/
```

The common display node is:

```text
/dev/dri/card0
```

The source currently uses:

```cpp
g_drm_fd = open("/dev/dri/card0", O_RDWR);
```

If your device uses another node, change it.

---

## 7.5 Calibrate Local-HBM Parameters

Different panels may require different Local-HBM parameters.

Create:

```bash
cat > test_lhbm.c <<'EOF'
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
    if (argc != 4)
        return 1;

    int fd = open("/dev/dri/card0", O_RDWR);
    if (fd < 0)
        return 1;

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
EOF
```

Compile:

```bash
clang test_lhbm.c -o test_lhbm
```

Enter root:

```bash
su
```

Test a known candidate:

```bash
./test_lhbm 2 2 0
```

If needed, restore normal mode:

```bash
./test_lhbm 0 0 0
```

Then test another candidate.

> **Warning:** This directly changes display-driver parameters. Do not blindly test random values. Always know how to return the display to normal mode.

Boston uses:

```text
param0 = 2
param1 = 2
param2 = 0
```

---

## 7.6 Update the C++ Source

After identifying your device-specific values, edit:

```text
src/moto_fod_bridge.cpp
```

The main values you may need to change are:

```text
FOD_EN_NODE
DRM device
FOD input event node
FOD keycode
Local-HBM parameters
Motorola fingerprint library/symbols, if your vendor implementation differs
```

The Local-HBM parameters are set inside:

```cpp
set_panel_mode()
```

Do not change Motorola HIDL symbol names unless you have verified your vendor implementation is different.

---

# 8. Build the Project

Once the values are configured:

```bash
chmod +x build.sh
./build.sh
```

The script compiles:

```text
src/moto_fod_bridge.cpp
```

and produces:

```text
magisk_module/vendor/bin/moto_fod_bridge
```

---

# 9. Build the Magisk Module

After compiling:

```bash
chmod +x zip_module.sh
./zip_module.sh
```

or:

```bash
bash zip_module.sh
```

The generated ZIP should appear in:

```text
out/
```

For example:

```text
out/moto_fod_bridge_module.zip
```

A device-specific release can use a name such as:

```text
Boston_Native_Local_HBM_FOD_Bridge_v4.zip
```

---

# 10. Install the Module

1. Open **Magisk**, **KernelSU**, or **APatch**.
2. Go to **Modules**.
3. Select **Install from storage**.
4. Select the generated ZIP.
5. Flash it.
6. Reboot.

---

# 11. Test the Fingerprint

## Enrollment

Go to:

```text
Settings → Security → Fingerprint
```

Start enrollment.

Expected sequence:

```text
Touch detected
      ↓
Local-HBM ON
      ↓
sendFodEvent(0)
      ↓
Optical capture
      ↓
Local-HBM OFF
      ↓
sendFodEvent(1)
```

## Lockscreen Unlock

Lock the device and touch the fingerprint sensor.

Verify:

- The fingerprint area illuminates.
- The sensor attempts to read your finger.
- The display returns to normal.
- Local-HBM does not remain stuck.

## Normal Usage

Test:

- Typing.
- Scrolling.
- Opening applications.
- Returning to the launcher.
- Locking/unlocking repeatedly.
- Face Unlock, if available.

Normal touches should **not** trigger Local-HBM when there is no active biometric session.

---

# 12. Troubleshooting

### Fingerprint icon is still on the back

This is primarily a **framework/SystemUI overlay issue**, not a Local-HBM bridge issue.

Fix the UDFPS overlay/position first.

---

### Local-HBM works but fingerprint does not enroll

Check:

1. FOD input node.
2. FOD keycode.
3. `fod_en` sysfs node.
4. Fingerprint library.
5. `sendFodEvent()` compatibility.
6. Running vendor fingerprint service.

The bridge cannot make an incompatible vendor HAL compatible automatically.

---

### `dlopen failed`

Check whether the expected library exists:

```bash
ls -l /vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
```

A GSI/vendor process may also be affected by Android's linker namespace restrictions.

If the binary cannot access the vendor library, inspect how the Magisk `service.sh` starts and mounts the daemon.

---

### `/dev/dri/card0` cannot be opened

Check:

```bash
ls -l /dev/dri/
```

If another DRM node controls the display, update the source.

Also verify root/SELinux permissions.

---

### No FOD touch events

Run:

```bash
su
getevent -l
```

Touch the fingerprint sensor and verify the actual event node and keycode.

---

### Local-HBM does nothing

Your panel may use different parameters.

Do not assume:

```text
2 2 0
```

will work on another device.

Use the calibration procedure in [7.5](#75-calibrate-local-hbm-parameters).

---

### Local-HBM stays enabled

Restore normal mode with your test program:

```bash
./test_lhbm 0 0 0
```

Then check the bridge's biometric session detection.

Different GSIs may produce different logcat messages.

---

### `bash` is inaccessible after `su`

Use Termux's full Bash path:

```bash
/data/data/com.termux/files/usr/bin/bash port_fod.sh
```

---

# 13. Boston Reference Values

These are the values used during development/testing on Motorola **Boston**.

| Component | Boston Reference Value |
|---|---|
| FOD Input Node | `/dev/input/event10` |
| Keycode | `704 / 0x2c0` |
| Sysfs Gesture Node | `/sys/devices/platform/goodix_ts.0/gesture/fod_en` |
| DRM Device | `/dev/dri/card0` |
| Local-HBM | `param0=2, param1=2, param2=0` |
| HAL Library | `/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so` |

These values are **references**, not universal values.

Do not blindly copy them to another device.

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
│   │   └── com/google/android/
│   └── vendor/
│       └── bin/
│           └── moto_fod_bridge
│
├── port_fod.sh
├── build.sh
├── zip_module.sh
├── LICENSE
└── README.md
```

### Main files

| File | Purpose |
|---|---|
| `src/moto_fod_bridge.cpp` | Native C++ FOD/Local-HBM bridge |
| `port_fod.sh` | Interactive device-porting helper |
| `build.sh` | Compiles the C++ bridge |
| `zip_module.sh` | Builds the flashable module ZIP |
| `magisk_module/` | Magisk module files |
| `LICENSE` | Project license |
| `README.md` | Documentation |

---

# 15. Contributing

If you successfully port the bridge to another Motorola device, open an issue or pull request.

Useful information:

```text
Device:
Codename:
Android Version:
GSI / ROM:
Vendor Firmware:
FOD Input Node:
FOD Keycode:
FOD Sysfs Node:
DRM Device:
Local-HBM Parameters:
Fingerprint HAL Library:
Fingerprint Service:
```

If possible, include relevant logs and explain which values you changed.

The goal is to make the process easier for other people facing the same:

```text
"Fingerprint on back"
        ↓
Overlay fixes position
        ↓
Fingerprint still cannot illuminate/read
        ↓
Native Local-HBM bridge
```

problem on a GSI.

---

# 16. License

This project is licensed under the **[MIT License](LICENSE)**.

You are free to use, modify, and redistribute the source according to the terms of the license.

---

# 17. Disclaimer

This project communicates directly with low-level display and fingerprint hardware interfaces.

Use it at your own risk.

Incorrect DRM parameters, sysfs writes, vendor library calls, or incompatible hardware modifications may cause crashes, broken fingerprint functionality, display problems, boot issues, or other unexpected behavior.

Always keep a working stock firmware/vendor backup before experimenting.

This project is provided **as-is**, without warranty.

---

<p align="center">
  <b>Built from a GSI fingerprint problem — for anyone facing the same problem.</b>
</p>
