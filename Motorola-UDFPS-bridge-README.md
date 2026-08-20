# Motorola Native Local-HBM UDFPS / FOD Bridge

<p align="center">

![Target](https://img.shields.io/badge/Target-Motorola%20UDFPS-8865FF?style=for-the-badge&logo=motorola&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)
![Architecture](https://img.shields.io/badge/Architecture-ARM64-0078D4?style=for-the-badge)
![Language](https://img.shields.io/badge/Language-C%2B%2B-00599C?style=for-the-badge&logo=cplusplus&logoColor=white)
![Root](https://img.shields.io/badge/Root-Magisk-00A98F?style=for-the-badge)
![License](https://img.shields.io/badge/License-MIT-2EA44F?style=for-the-badge)

</p>

<p align="center">
  <b>A native Local-HBM bridge for optical in-display fingerprint sensors on Motorola devices running GSIs or custom ROMs.</b>
</p>

---

## ⚠️ Important

This repository contains a **hardware-specific reference implementation**, not a universal drop-in binary.

The architecture can be reused on other Motorola devices, but the following values are normally device/vendor specific:

- DRM device node
- DRM ioctl
- Local-HBM parameters
- fingerprint vendor library
- HIDL/AIDL interface and symbols
- FOD sysfs node
- FOD input event node
- FOD keycode
- FOD payload
- HBM timing
- SELinux/vendor namespace requirements

**Do not flash the prebuilt module on another device just because it has an optical fingerprint sensor.**

Use this README as a porting guide and replace the Boston-specific values with values discovered from your own stock firmware.

---

# 📖 What This Project Does

Optical UDFPS/FOD hardware is not just a fingerprint icon on the screen.

A typical Motorola optical fingerprint implementation involves several layers:

```text
Android Biometric Framework
            │
            ▼
       UDFPS UI/session
            │
            ▼
     Native FOD Bridge
       ┌────┼─────┐
       │    │     │
       ▼    ▼     ▼
     DRM  Touch  Vendor HAL
     HBM  Event  / HIDL / AIDL
       │    │     │
       └────┼─────┘
            ▼
       Optical Sensor
```

The bridge connects the pieces that a generic GSI may not know how to operate together.

In the reference implementation it:

1. Detects biometric/enrollment sessions.
2. Arms the vendor FOD interface.
3. Monitors the hardware FOD touch event.
4. Enables native Local-HBM through the display driver.
5. Sends the vendor fingerprint capture event.
6. Keeps the optical illumination active for a short capture window.
7. Restores normal display mode.
8. Sends the vendor release event.
9. Disarms the sensor when authentication/enrollment ends.
10. Uses an enrollment watchdog to prevent the sensor remaining armed indefinitely.

---

# 🧠 Why GSIs Can Break Optical Fingerprint

A GSI provides generic Android framework support.

Your device vendor, however, may have proprietary hardware interfaces.

For example:

```text
AOSP
 │
 ├── Generic UDFPS framework
 ├── Generic biometric UI
 └── Generic fingerprint APIs
```

while the Motorola vendor stack may additionally require:

```text
Motorola vendor
 │
 ├── Display Local-HBM control
 ├── Motorola fingerprint HAL
 ├── Goodix FOD control
 └── Vendor-specific touch events
```

If those vendor operations are not correctly connected to the GSI's biometric flow, you can get:

```text
Fingerprint icon appears
        ↓
Finger touches sensor
        ↓
Panel does not enter correct Local-HBM
        ↓
Optical sensor receives insufficient illumination
        ↓
Authentication/enrollment fails
```

The bridge is intended to provide that missing connection.

---

# 🏗️ Architecture

The reference implementation has four major components.

## 1. Display / Local-HBM

The C++ daemon opens:

```text
/dev/dri/card0
```

and uses:

```text
DRM_IOCTL_MDSS_DISP_PARAM
```

to switch the panel between normal mode and the vendor's Local-HBM state.

The Boston reference implementation uses:

```text
Mode 4:
param0 = 2
param1 = 2
param2 = 0
```

and restores:

```text
Mode 0:
param0 = 0
param1 = 0
param2 = 0
```

**These numbers are not universal.**

---

## 2. Vendor Fingerprint HAL

The reference implementation dynamically loads:

```text
/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
```

and resolves Motorola's fingerprint service and `sendFodEvent()` symbols.

The implementation uses ARM64 register-level calls because it is interacting directly with the vendor ABI.

Again, this is **vendor and Android-version specific**.

---

## 3. Goodix FOD Interface

The reference device exposes:

```text
/sys/devices/platform/goodix_ts.0/gesture/fod_en
```

The bridge writes:

```text
1
```

to arm the FOD interface and:

```text
0
```

to disarm it.

Another device may expose something completely different.

---

## 4. FOD Input Event

The reference implementation monitors:

```text
/dev/input/event10
```

and detects:

```text
EV_KEY
keycode 704
```

or:

```text
0x2c0
```

A different kernel may expose:

```text
/dev/input/eventX
```

with another keycode.

You must discover this yourself.

---

# 🔎 Porting Guide

This is the most important section if you are adapting the project to another Motorola device.

Do not start by changing random values in the C++ source.

First map your stock firmware.

The recommended order is:

```text
1. Identify fingerprint hardware
2. Identify FOD input event
3. Identify FOD sysfs interface
4. Identify fingerprint HAL/library
5. Identify HIDL/AIDL API
6. Identify display driver
7. Identify Local-HBM interface
8. Test HBM manually
9. Test vendor FOD event manually
10. Integrate everything into the bridge
11. Package with Magisk
12. Test authentication/enrollment
```

---

# Step 1 — Identify Your Fingerprint Hardware

Boot your **stock ROM** first.

Do not begin by modifying the GSI.

Check the kernel command line and device information:

```bash
su -c 'getprop | grep -iE "finger|goodix|udfps|fod"'
```

Check vendor files:

```bash
su -c 'find /vendor -iname "*finger*" -o -iname "*goodix*" 2>/dev/null'
```

Also inspect:

```bash
su -c 'find /vendor/lib64 /vendor/lib -type f 2>/dev/null | grep -iE "finger|goodix|biometric"'
```

You are looking for evidence such as:

```text
Goodix
FPC
Synaptics
Egis
Motorola biometric
fingerprint HAL
```

Record everything before proceeding.

---

# Step 2 — Find the FOD Touch Event

Run on the stock ROM:

```bash
su
getevent -lp
```

Look through the input devices.

You can also use:

```bash
su -c 'getevent -il'
```

Then monitor events:

```bash
su
getevent -lt
```

Touch the fingerprint sensor repeatedly.

You are looking for an event similar to:

```text
/dev/input/event10
EV_KEY
KEY_...
```

or a vendor-specific numeric keycode.

You can narrow the output:

```bash
su -c 'getevent -lt | grep -iE "KEY|704|2c0|finger|fod"'
```

If filtering hides the event, use the complete `getevent -lt` output and identify which `/dev/input/eventX` changes when you touch the fingerprint area.

### Record

```text
INPUT_NODE=/dev/input/eventX
FOD_KEYCODE=?
```

Do not assume `event10` or `704`.

---

# Step 3 — Find the FOD Sysfs Interface

Search for FOD-related nodes:

```bash
su -c 'find /sys -type f 2>/dev/null | grep -iE "fod|udfps|fingerprint"'
```

Search Goodix nodes:

```bash
su -c 'find /sys -type f 2>/dev/null | grep -i goodix'
```

Inspect candidate files:

```bash
su -c 'ls -l /sys/devices/platform/'
```

If you find something like:

```text
/sys/devices/platform/goodix_ts.0/gesture/fod_en
```

test it carefully.

Read:

```bash
su -c 'cat /sys/devices/platform/goodix_ts.0/gesture/fod_en'
```

If the stock implementation clearly uses it, you can test:

```bash
su -c 'echo 1 > /sys/.../fod_en'
```

and later:

```bash
su -c 'echo 0 > /sys/.../fod_en'
```

**Do not write random values to unknown sysfs nodes.**

---

# Step 4 — Identify the Vendor Fingerprint Library

Search:

```bash
su -c 'find /vendor/lib64 /vendor/lib -type f 2>/dev/null | grep -iE "fingerprint|biometric"'
```

Common examples may look like:

```text
com.motorola.hardware.biometric.fingerprint@1.0.so
```

or another vendor-specific library.

Inspect dependencies:

```bash
su -c 'readelf -d /vendor/lib64/YOUR_LIBRARY.so'
```

Inspect symbols:

```bash
su -c 'nm -D /vendor/lib64/YOUR_LIBRARY.so 2>/dev/null | grep -iE "getService|sendFod|Fod"'
```

If `nm` is unavailable, use:

```bash
strings /vendor/lib64/YOUR_LIBRARY.so | grep -iE "Fod|fingerprint"
```

---

# Step 5 — Determine HIDL or AIDL

Older Motorola implementations may expose HIDL.

Search:

```bash
su -c 'find /vendor -type f 2>/dev/null | grep -iE "android.hardware.biometrics|fingerprint"'
```

Check registered services:

```bash
su -c 'lshal 2>/dev/null | grep -iE "finger|biometric|motorola"'
```

On newer Android versions, the implementation may instead use AIDL.

Check:

```bash
su -c 'service list | grep -iE "finger|biometric"'
```

and:

```bash
su -c 'dumpsys -l | grep -iE "finger|biometric"'
```

### Important

Do not assume the HIDL interface from this project exists on your device.

If your device uses a different interface, the C++ bridge needs to be adapted to that ABI.

---

# Step 6 — Find the Display Device

Check:

```bash
su -c 'ls -l /dev/dri/'
```

Usually you will see something such as:

```text
card0
card1
renderD128
```

Inspect DRM information:

```bash
su -c 'cat /sys/class/drm/*/status 2>/dev/null'
```

and:

```bash
su -c 'find /sys/class/drm -maxdepth 2 -type f 2>/dev/null | head -100'
```

The bridge must communicate with the display driver that actually controls the panel.

---

# Step 7 — Find the Local-HBM Mechanism

This is the hardest part.

Do **not** assume every Motorola device uses:

```text
DRM_IOCTL_MDSS_DISP_PARAM
```

or:

```text
param0=2
param1=2
param2=0
```

Those are hardware/vendor-specific.

Search the stock vendor/kernel files:

```bash
su -c 'grep -RilE "local.?hbm|lhbm|hbm|fod|fingerprint" /vendor/etc /vendor/lib64 /vendor/lib 2>/dev/null | head -100'
```

Search kernel interfaces:

```bash
su -c 'find /sys -type f 2>/dev/null | grep -iE "hbm|fod|finger"'
```

Search device tree/debug information where available:

```bash
su -c 'find /proc /sys -type f 2>/dev/null | grep -iE "display|dsi|mdss|dpu|hbm" | head -200'
```

If you have the stock kernel source or vendor kernel tree, search it directly:

```bash
grep -RniE "LOCAL_HBM|LOCAL-HBM|LHBM|fod_hbm|fingerprint_hbm" kernel/ vendor/ 2>/dev/null
```

Look for:

```text
DRM ioctl
MDSS
DSI command
panel mode
HBM mode
local HBM
fingerprint HBM
fod HBM
```

---

# Step 8 — Test Local-HBM Before Writing the Daemon

This is critical.

Do not write the complete bridge first.

Create a tiny standalone test program that only opens the display node and performs the suspected ioctl.

For the Boston reference implementation:

```cpp
#define DRM_IOCTL_MDSS_DISP_PARAM 0xc008649f

struct disp_param_req {
    uint32_t param_id;
    int32_t value;
};
```

Then test the suspected parameters.

For example:

```text
param0 = ?
param1 = ?
param2 = ?
```

Compile:

```bash
clang++ -O2 test_lhbm.cpp -o test_lhbm
```

Run as root:

```bash
su -c './test_lhbm ...'
```

### Expected behavior

A correct Local-HBM command should produce a localized high-brightness area over the optical sensor.

If the entire screen changes brightness, the command is probably not the expected Local-HBM interface.

If nothing happens, investigate:

- wrong DRM node
- wrong ioctl
- wrong structure
- wrong parameters
- missing permissions
- wrong display driver
- panel not supporting the interface

Do not blindly brute-force random ioctl values.

---

# Step 9 — Determine the Vendor FOD Event

The reference implementation uses:

```text
sendFodEvent(0)
```

for capture start and:

```text
sendFodEvent(1)
```

for release.

It also sends a payload:

```text
0x03
```

Your device may use:

- different event values
- different payload
- different function
- different HAL
- no `sendFodEvent()` at all

Find the corresponding vendor implementation in your stock firmware.

Useful searches:

```bash
strings /vendor/lib64/YOUR_FINGERPRINT_LIBRARY.so | grep -i fod
```

```bash
nm -D /vendor/lib64/YOUR_FINGERPRINT_LIBRARY.so 2>/dev/null | grep -i fod
```

and, if you have the vendor source:

```bash
grep -Rni "sendFodEvent" vendor/ device/ hardware/ kernel/
```

---

# Step 10 — Modify the C++ Constants

Once you have mapped your hardware, replace the Boston-specific constants.

The reference source contains values similar to:

```cpp
static const char* FOD_EN_NODE =
    "/sys/devices/platform/goodix_ts.0/gesture/fod_en";
```

Change this to your device's actual FOD node.

The input device:

```cpp
open("/dev/input/event10", O_RDONLY | O_NONBLOCK);
```

must become your discovered event node.

The keycode:

```cpp
ev.code == 704
```

or:

```cpp
ev.code == 0x2c0
```

must become your discovered FOD event.

The fingerprint library:

```cpp
dlopen("/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so", RTLD_NOW);
```

must match your vendor implementation.

The HIDL mangled symbols must also match your exact interface and ABI.

Finally, replace the Local-HBM parameters in:

```cpp
set_panel_mode()
```

with the values proven on your panel.

---

# Step 11 — Test the Vendor Pieces Independently

Before running the complete daemon, test each layer separately.

## Test FOD sysfs

```bash
su -c 'echo 1 > YOUR_FOD_NODE'
```

Then:

```bash
su -c 'echo 0 > YOUR_FOD_NODE'
```

## Test input

```bash
su -c 'getevent -lt YOUR_INPUT_NODE'
```

Touch the fingerprint sensor.

## Test vendor library

Verify the library exists:

```bash
su -c 'ls -l YOUR_FINGERPRINT_LIBRARY'
```

Check symbols:

```bash
su -c 'nm -D YOUR_FINGERPRINT_LIBRARY 2>/dev/null | grep -iE "getService|Fod"'
```

## Test Local-HBM

Run your standalone HBM test as root.

Only when all three pieces work independently should you combine them.

---

# Step 12 — Build the Bridge

Install the required tools in Termux:

```bash
pkg update
pkg install clang git zip -y
```

Clone the project:

```bash
git clone https://github.com/Emii31/Motorola-UDFPS-bridge.git
cd Motorola-UDFPS-bridge
```

Compile:

```bash
./build.sh
```

The reference build produces:

```text
magisk_module/vendor/bin/moto_fod_bridge
```

If the directory does not exist, create it first:

```bash
mkdir -p magisk_module/vendor/bin
```

Then:

```bash
./build.sh
```

---

# Step 13 — Package the Magisk Module

Run:

```bash
./zip_module.sh
```

The ZIP is generated under:

```text
out/
```

For the reference release:

```text
out/Moto_Native_Local_HBM_FOD_Bridge_v4.zip
```

Before flashing, inspect the ZIP:

```bash
unzip -l out/Moto_Native_Local_HBM_FOD_Bridge_v4.zip
```

You should see the module files and the executable under the expected path.

---

# 🧩 Magisk Module Structure

The reference module uses:

```text
magisk_module/
├── module.prop
├── service.sh
└── vendor/
    └── bin/
        └── moto_fod_bridge
```

The `service.sh`:

1. waits for Android boot completion
2. kills stale daemon instances
3. removes an old vendor bind mount
4. bind-mounts the daemon into `/vendor/bin/vndservice`
5. applies the vendor SELinux file context where supported
6. starts the daemon
7. restarts it if it exits

This vendor-side execution arrangement is used by the reference implementation to work around Android Bionic linker namespace restrictions when loading the vendor fingerprint library.

### Important

This is **not guaranteed to work unchanged on every device**.

A different device may require:

- another vendor executable path
- another SELinux context
- a different namespace solution
- an `init` service
- a different mount point
- no workaround at all

---

# 🛠️ Debugging

The reference service writes:

```text
/data/local/tmp/fod_bridge.log
```

Read it with:

```bash
su -c 'cat /data/local/tmp/fod_bridge.log'
```

Follow it live:

```bash
su -c 'tail -f /data/local/tmp/fod_bridge.log'
```

Check the daemon:

```bash
su -c 'ps -A | grep -E "moto_fod_bridge|vndservice"'
```

Check the vendor mount:

```bash
su -c 'mount | grep vndservice'
```

Check the executable:

```bash
su -c 'ls -lZ /vendor/bin/vndservice'
```

Check the fingerprint library:

```bash
su -c 'ls -l /vendor/lib64/ | grep -iE "finger|biometric"'
```

---

# 🔍 Useful Android Debug Commands

## Fingerprint services

```bash
su -c 'service list | grep -iE "finger|biometric"'
```

## Fingerprint dumpsys

```bash
su -c 'dumpsys fingerprint'
```

## UDFPS-related logs

```bash
su -c 'logcat -b all | grep -iE "udfps|fingerprint|biometric|fod|hbm"'
```

## Vendor services

```bash
su -c 'lshal 2>/dev/null | grep -iE "finger|biometric|motorola"'
```

## Properties

```bash
su -c 'getprop | grep -iE "finger|fod|goodix|biometric|hbm"'
```

---

# 🚨 Common Problems

## `dlopen failed`

Example:

```text
dlopen failed: library "...so" is not accessible
```

Possible causes:

- wrong library path
- linker namespace restriction
- daemon running in the wrong Android namespace
- incorrect vendor mount
- SELinux denial

Check:

```bash
su -c 'ls -l YOUR_LIBRARY'
```

Then:

```bash
su -c 'logcat -b all | grep -iE "linker|avc|denied|fingerprint"'
```

---

## Failed to acquire fingerprint service

Possible causes:

- wrong HIDL version
- wrong service name
- wrong mangled symbol
- incompatible vendor ABI
- fingerprint HAL not running
- wrong library

Check:

```bash
su -c 'lshal 2>/dev/null | grep -i fingerprint'
```

and:

```bash
nm -D YOUR_LIBRARY 2>/dev/null | grep -i getService
```

---

## Fingerprint icon appears but screen does not illuminate

This usually means the Android UDFPS framework is working but the hardware Local-HBM bridge is not.

Investigate:

```text
DRM node
DRM ioctl
HBM parameters
panel driver
permissions
SELinux
```

Do not modify the fingerprint HAL until you have proven the display HBM path.

---

## HBM works but fingerprint capture fails

Then the problem may be the vendor fingerprint side:

```text
sendFodEvent()
FOD payload
event type
Goodix FOD state
capture timing
```

Test these separately.

---

## HBM remains active after authentication

Check session termination logs.

The reference implementation watches events including:

```text
hideUdfpsOverlay
onAuthSessionEnded
onAuthenticated(true)
keyguardGoingAway
setKeyguardOccluded(false)
dismissKeyguard
startExitAnimation
cancelAuthentication
cancelEnrollment
stopEnroll
Launcher
```

Different ROMs may produce different log messages.

You may need to add your ROM's actual log strings.

---

## HBM activates during normal typing or scrolling

This means your session guard is remaining active when it should be disarmed.

Check:

```bash
su -c 'cat /data/local/tmp/fod_bridge.log'
```

and inspect:

```text
g_session_active
g_is_enrolling
```

Add more accurate session-ending log patterns if necessary.

---

## Enrollment never disarms

The reference implementation includes an enrollment watchdog.

The default reference timeout is:

```text
2500 ms
```

The watchdog runs every:

```text
250 ms
```

If your enrollment flow needs more time, change the timeout only after confirming the behavior from logs.

---

# 🧪 Recommended Porting Workflow

If you are doing this on a new Motorola device, follow this exact order:

```text
STOCK ROM
   │
   ├── Identify fingerprint vendor
   │
   ├── Identify input node/keycode
   │
   ├── Identify FOD sysfs node
   │
   ├── Identify fingerprint HAL
   │
   ├── Identify HIDL/AIDL symbols
   │
   ├── Identify display driver
   │
   └── Identify Local-HBM mechanism
            │
            ▼
      Test each component
            │
            ▼
       Modify C++ source
            │
            ▼
          Compile
            │
            ▼
       Test daemon manually
            │
            ▼
      Create Magisk module
            │
            ▼
       Test on GSI
```

This is much safer than trying random overlays, random HBM values, or donor HAL files.

---

# 📋 Porting Checklist

Before calling your port complete:

### Fingerprint

- [ ] Fingerprint vendor identified
- [ ] Fingerprint HAL identified
- [ ] HIDL/AIDL version identified
- [ ] Vendor library identified
- [ ] Required symbols identified

### FOD

- [ ] FOD sysfs node identified
- [ ] Input event node identified
- [ ] FOD keycode identified
- [ ] FOD payload identified
- [ ] Capture event sequence understood

### Display

- [ ] DRM device identified
- [ ] Display ioctl identified
- [ ] Local-HBM mechanism identified
- [ ] Local-HBM parameters tested
- [ ] Normal display restore tested

### Android

- [ ] Authentication-start logs identified
- [ ] Enrollment-start logs identified
- [ ] Authentication-end logs identified
- [ ] Enrollment-complete logs identified
- [ ] Keyguard unlock logs identified
- [ ] Launcher transition verified

### Module

- [ ] C++ binary compiles
- [ ] Magisk module installs
- [ ] Vendor namespace issue resolved if required
- [ ] SELinux behavior verified
- [ ] Daemon survives boot
- [ ] Daemon restarts correctly if it exits
- [ ] HBM restores correctly on daemon termination

---

# 🔐 Safety / Recovery

This project requires root and interacts directly with hardware interfaces.

Before testing:

1. Keep a copy of your stock firmware.
2. Know how to boot into bootloader/recovery.
3. Know how to disable/remove a Magisk module.
4. Test new HBM commands at low risk.
5. Never assume a vendor ioctl is safe on another panel.
6. Do not copy another device's HBM parameters blindly.

If the daemon crashes or the module behaves incorrectly, remove/disable the Magisk module before continuing development.

---

# 📁 Repository Structure

```text
Motorola-UDFPS-bridge/
│
├── README.md
├── LICENSE
├── build.sh
├── zip_module.sh
│
├── src/
│   └── moto_fod_bridge.cpp
│
├── magisk_module/
│   ├── module.prop
│   ├── service.sh
│   └── vendor/
│       └── bin/
│           └── moto_fod_bridge
│
└── out/
    └── Moto_Native_Local_HBM_FOD_Bridge_v4.zip
```

The compiled binary and `out/` directory can be generated during development instead of committed to Git.

---

# 🔨 Building

Install dependencies:

```bash
pkg update
pkg install clang git zip -y
```

Clone:

```bash
git clone https://github.com/Emii31/Motorola-UDFPS-bridge.git
cd Motorola-UDFPS-bridge
```

Compile:

```bash
mkdir -p magisk_module/vendor/bin
./build.sh
```

Package:

```bash
./zip_module.sh
```

Inspect:

```bash
unzip -l out/Moto_Native_Local_HBM_FOD_Bridge_v4.zip
```

---

# 💡 Development Philosophy

This project deliberately focuses on the **hardware bridge** rather than replacing the complete Motorola fingerprint stack.

The goal is:

```text
Keep existing vendor HAL
        +
Keep existing fingerprint hardware
        +
Keep existing Android biometric framework
        +
Bridge the missing hardware-specific operations
```

That can be substantially smaller and easier to maintain than porting an entire fingerprint HAL from another device.

However, this approach only works when the vendor interfaces required by the device can be discovered and safely invoked.

---

# ⚠️ What This Project Is Not

This is not:

- a universal fingerprint HAL
- a replacement for Android BiometricService
- a replacement for the vendor fingerprint driver
- a generic Local-HBM implementation
- a universal Motorola UDFPS module
- a guaranteed solution for every GSI
- a donor-HAL port

It is a **native bridge architecture** that can be adapted to compatible vendor implementations.

---

# 🤝 Contributing

If you successfully port this architecture to another device, document:

```text
Device:
Codename:
Android version:
Vendor version:
Fingerprint vendor:
FOD input node:
FOD keycode:
FOD sysfs node:
Fingerprint library:
HIDL/AIDL version:
Local-HBM mechanism:
Local-HBM parameters:
Capture timing:
```

Do not submit only a compiled binary.

Where possible, submit:

- source changes
- hardware findings
- logs
- exact vendor interfaces
- build instructions
- device-specific documentation

This makes the project useful to other developers.

---

# 📜 License

This project is licensed under the **MIT License**.

See [`LICENSE`](LICENSE).

---

# ⚖️ Disclaimer

This software is provided **as-is**, without warranty.

It interacts with privileged Android, Linux kernel, display, fingerprint, vendor, and SELinux interfaces.

Use it at your own risk.

The author is not responsible for:

- boot failures
- device instability
- display damage
- fingerprint malfunction
- data loss
- software corruption
- warranty issues
- damage caused by incorrect vendor-specific modifications

---

# ⭐ Credits

Developed as a reverse-engineering and hardware-integration project for Motorola optical UDFPS devices running GSI/custom ROM environments.

The reference implementation was developed around Motorola **Boston**, but the architecture and investigation methodology are intended to help developers adapt the concept to other compatible devices.

---

<p align="center">
  <b>Find the vendor path. Test each layer. Then bridge them.</b>
</p>
