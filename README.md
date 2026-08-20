# Motorola UDFPS Bridge — Boston

A native C++ **Local-HBM (High Brightness Mode) FOD/UDFPS bridge** for the **Motorola Moto G Stylus 5G (2024), codename Boston**.

This project was developed to restore working optical in-display fingerprint illumination and fingerprint capture on a GSI/custom ROM environment while continuing to use Motorola's existing vendor fingerprint implementation.

> **Current target: Motorola Boston only.**
>
> The values and vendor interfaces used by this project are hardware/firmware specific. This is **not** a universal Motorola UDFPS solution.

---

## What Problem Does This Solve?

On a clean GSI/custom ROM, Boston can have a working optical fingerprint sensor at the hardware/vendor level while the Android framework does not correctly reproduce the stock Motorola FOD behavior.

One symptom is the familiar:

```text
Fingerprint sensor appears incorrectly / UDFPS behavior is missing
```

A framework overlay can correct the UDFPS position and make the fingerprint icon appear, but that alone does not provide the optical illumination required by the sensor.

The missing part is the connection between:

```text
Android biometric session
        ↓
Touch/FOD event
        ↓
Display Local-HBM
        ↓
Motorola fingerprint HAL
        ↓
Optical fingerprint capture
```

This project provides that bridge.

---

# How This Implementation Works

The bridge is a native C++ userspace process that coordinates three existing components:

1. Android biometric session state
2. The display driver's Local-HBM interface
3. Motorola's existing fingerprint HIDL implementation

The basic flow is:

```text
Biometric prompt opens
        ↓
Bridge arms FOD
        ↓
User touches fingerprint area
        ↓
Touch event detected
        ↓
Local-HBM enabled
        ↓
Motorola sendFodEvent(0)
        ↓
Optical fingerprint capture
        ↓
~160 ms capture window
        ↓
Local-HBM disabled
        ↓
Motorola sendFodEvent(1)
```

When the biometric session ends, the bridge also disables FOD mode and restores the display.

---

# Boston-Specific Implementation

The current source contains several values that were determined specifically for the Boston environment.

## Display DRM

The bridge communicates with:

```text
/dev/dri/card0
```

using:

```cpp
DRM_IOCTL_MDSS_DISP_PARAM
```

with ioctl value:

```text
0xc008649f
```

The Local-HBM configuration used by this implementation is:

```text
param0 = 2
param1 = 2
param2 = 0
```

This is treated by the bridge as:

```text
Mode 4 — Native Local-HBM
```

Normal display mode uses:

```text
param0 = 0
param1 = 0
param2 = 0
```

### Important

These values are **not universal Local-HBM parameters**.

Do not copy them to another device without verifying its display driver.

---

# Goodix FOD Interface

The bridge uses the following sysfs node:

```text
/sys/devices/platform/goodix_ts.0/gesture/fod_en
```

The node is controlled using:

```text
0 = FOD disabled
1 = FOD enabled
```

The source defines it as:

```cpp
static const char* FOD_EN_NODE =
    "/sys/devices/platform/goodix_ts.0/gesture/fod_en";
```

This is another Boston/vendor-specific dependency.

---

# Motorola Fingerprint HAL

The bridge does **not** replace the fingerprint HAL.

Instead, it dynamically loads Motorola's existing fingerprint HIDL library:

```text
/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
```

The source obtains the Motorola fingerprint service through:

```text
IMotoFingerPrint
```

and resolves the vendor's:

```text
sendFodEvent()
```

interface.

The bridge then sends:

```text
sendFodEvent(0)
```

when fingerprint capture begins and:

```text
sendFodEvent(1)
```

when the capture window ends.

This allows the existing Motorola fingerprint implementation to remain responsible for the actual biometric hardware.

---

# Touch Input

The bridge currently monitors:

```text
/dev/input/event10
```

using Linux's input-event interface.

It looks for:

```text
EV_KEY
```

with:

```text
704
```

or:

```text
0x2c0
```

When the event reports:

```text
value = 1
```

the bridge treats it as a fingerprint touch-down event.

### Why This Is Important

Linux input event numbering is not guaranteed to remain the same across devices or firmware versions.

Therefore:

```text
/dev/input/event10
```

should be considered a **Boston-specific configuration value**, not a universal requirement.

---

# Biometric Session Detection

A separate listener thread monitors Android's logcat:

```bash
logcat -v time -s BiometricService:D UdfpsController:D
```

The bridge watches for biometric/UDFPS-related messages.

Session activation is triggered by messages containing:

```text
showUdfpsOverlay
authenticate
enroll
```

Session termination is detected using:

```text
hideUdfpsOverlay
onAuthSessionEnded
resetLockout
```

When a session becomes active:

```text
g_session_active = true
```

and:

```text
fod_en = 1
```

When the session ends:

```text
g_session_active = false
```

and:

```text
Local-HBM = OFF
fod_en = 0
```

---

# Local-HBM Capture Sequence

When a valid fingerprint touch is detected during an active biometric session:

### 1. Local-HBM is enabled

```cpp
set_panel_mode(4);
```

which sends:

```text
param0 = 2
param1 = 2
param2 = 0
```

to the display driver.

### 2. Fingerprint capture is triggered

```cpp
sendFodEvent(0)
```

### 3. Capture remains active

The implementation maintains the active state for approximately:

```text
160 ms
```

### 4. Display is restored

```cpp
set_panel_mode(0);
```

### 5. Fingerprint event is released

```cpp
sendFodEvent(1)
```

The result is a short native Local-HBM illumination window synchronized with fingerprint capture.

---

# Safety Handling

The bridge installs signal handlers for:

```text
SIGINT
SIGTERM
```

When terminated, it attempts to:

1. Disable Local-HBM.
2. Disable the Goodix FOD node.
3. Close the DRM file descriptor.
4. Exit safely.

This is important because leaving the panel in an active HBM/FOD state could result in abnormal display behavior.

---

# Project Structure

The recommended repository structure is:

```text
Motorola-UDFPS-bridge/
├── LICENSE
├── README.md
├── module.prop
├── service.sh
├── src/
│   └── moto_fod_bridge.cpp
└── system/
    └── bin/
        └── moto_fod_bridge
```

Where:

| File                         | Purpose                      |
| ---------------------------- | ---------------------------- |
| `README.md`                  | Project documentation        |
| `LICENSE`                    | Project license              |
| `module.prop`                | Magisk module metadata       |
| `service.sh`                 | Starts the bridge after boot |
| `src/moto_fod_bridge.cpp`    | Native C++ source            |
| `system/bin/moto_fod_bridge` | Compiled ARM64 executable    |

---

# Building From Source

The source is intended for an Android/ARM64 environment because it directly uses ARM64 register assignments and inline assembly for the Motorola HIDL calls.

The source contains ARM64-specific code such as:

```cpp
register const VendorString* r_x0 asm("x0")
```

and:

```cpp
register uint64_t r_x1 asm("x1")
```

Therefore, this is **not a portable desktop C++ application**.

A suitable Android NDK/Clang environment or an ARM64 Android build environment is required.

An example native compilation command is:

```bash
clang++ \
    -std=c++17 \
    -O3 \
    src/moto_fod_bridge.cpp \
    -o moto_fod_bridge \
    -lpthread \
    -ldl
```

The resulting binary should be placed at:

```text
system/bin/moto_fod_bridge
```

and made executable:

```bash
chmod 0755 system/bin/moto_fod_bridge
```

> The exact compiler/toolchain requirements can depend on the Android version and build environment. The source uses Android/Linux-specific headers, ARM64 inline assembly, dynamic linking, Linux input events, and vendor HIDL ABI details.

---

# Magisk Installation

The compiled bridge is packaged as a Magisk module.

A typical module contains:

```text
module.prop
service.sh
system/bin/moto_fod_bridge
```

After creating the module ZIP:

1. Open Magisk.
2. Install the module ZIP.
3. Reboot.
4. Test fingerprint enrollment.
5. Test fingerprint authentication.

The bridge should start through `service.sh`.

---

# Requirements

The current Boston implementation requires:

* Root access.
* Magisk or compatible root environment.
* ARM64 Android.
* Motorola Boston hardware.
* Goodix optical fingerprint sensor.
* Motorola fingerprint HIDL library.
* `/dev/dri/card0`.
* Boston-compatible display Local-HBM interface.
* Boston-compatible Goodix FOD sysfs node.
* Boston-compatible input event.
* Appropriate permissions to access the required devices/interfaces.

---

# Compatibility

## Confirmed Target

```text
Device: Motorola Moto G Stylus 5G (2024)
Codename: Boston
Architecture: ARM64
Fingerprint: Optical UDFPS / Goodix
```

The project is intended primarily for Boston running a GSI/custom ROM where the stock Motorola fingerprint/vendor components remain available.

---

# Not Universal

This project should **not** be flashed blindly on another Motorola device.

The following values are currently hard-coded:

```text
/dev/dri/card0

/dev/input/event10

/sys/devices/platform/goodix_ts.0/gesture/fod_en

/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so

DRM_IOCTL_MDSS_DISP_PARAM = 0xc008649f

Local-HBM = 2, 2, 0

Touch codes = 704 / 0x2c0

Capture window = ~160 ms
```

A different device may use completely different:

* Display driver
* Panel
* DRM interface
* Local-HBM parameters
* Fingerprint vendor
* HIDL/AIDL version
* Library name
* Input device
* Input event codes
* FOD sysfs interface
* Capture timing

A port therefore requires hardware-specific investigation.

---

# Troubleshooting

## UDFPS icon appears but there is no illumination

Check whether the bridge is running:

```bash
ps -A | grep moto_fod_bridge
```

Check display access:

```bash
ls -l /dev/dri/card0
```

Check FOD node:

```bash
ls -l /sys/devices/platform/goodix_ts.0/gesture/fod_en
```

Check fingerprint libraries:

```bash
ls -l /vendor/lib64/*fingerprint*
```

Check logs:

```bash
logcat | grep -iE 'fingerprint|udfps|fod|hbm|biometric'
```

---

## Bridge cannot open `/dev/input/event10`

The input event number may be different.

Inspect available devices:

```bash
getevent -lp
```

Then identify the touchscreen/FOD-related input device.

If the correct node is different, the source must be adapted.

---

## HIDL library cannot be loaded

The source expects:

```text
/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
```

Check:

```bash
ls -l /vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
```

If the library does not exist, this implementation cannot simply be used unchanged.

The vendor fingerprint interface must be investigated first.

---

## Fingerprint icon appears but authentication fails

Local-HBM illumination and fingerprint authentication are separate pieces.

Check:

```bash
dumpsys fingerprint
```

and:

```bash
logcat -b all | grep -iE 'fingerprint|biometric|udfps|fod'
```

Possible causes include:

* Incorrect touch event.
* Incorrect HBM timing.
* Incorrect vendor FOD event.
* Fingerprint HAL incompatibility.
* Incorrect Goodix FOD state.
* Incorrect input node.
* SELinux restrictions.
* Vendor framework incompatibility.

---

# Development Notes

The bridge intentionally keeps the existing Motorola fingerprint implementation rather than replacing the complete biometric stack.

The architecture is:

```text
             Android Biometric Framework
                       │
                       ▼
              Biometric Session
                       │
                       ▼
              moto_fod_bridge
                 │     │     │
                 │     │     └──── Motorola Fingerprint HIDL
                 │     │
                 │     └────────── Goodix FOD sysfs
                 │
                 └──────────────── Display DRM / Local-HBM
```

This makes the bridge relatively small compared with replacing or porting an entire vendor biometric implementation.

---

# Why Not Replace the Fingerprint HAL?

The purpose of this project is not to recreate Motorola's fingerprint implementation.

The stock vendor fingerprint stack already provides the hardware-specific biometric functionality.

The bridge instead attempts to provide the missing synchronization between:

```text
Biometric prompt
        +
Touch event
        +
Local-HBM
        +
Fingerprint capture
```

This approach reduces the amount of vendor code that needs to be replaced.

---

# Known Limitations

The current implementation is experimental and has several limitations.

### 1. Hard-coded input node

```text
/dev/input/event10
```

### 2. Hard-coded vendor library

```text
com.motorola.hardware.biometric.fingerprint@1.0.so
```

### 3. Hard-coded Goodix sysfs path

```text
/sys/devices/platform/goodix_ts.0/gesture/fod_en
```

### 4. Logcat-based biometric detection

The bridge currently observes logcat output rather than integrating directly with Android's biometric framework.

This is practical for a root-level bridge but is not as robust as a native framework integration.

### 5. Fixed capture timing

The current implementation uses approximately:

```text
160 ms
```

for the Local-HBM capture window.

Different sensors or firmware may require different timing.

### 6. ARM64-specific HIDL calls

The source uses ARM64 register manipulation and inline assembly.

It is therefore not architecture-independent.

---

# Security and Permissions

This project requires root-level access because it interacts with privileged Android/Linux interfaces including:

```text
/dev/dri/card0
/dev/input/event10
/sys/devices/...
/vendor/lib64/...
```

Do not run unknown builds of this project on a device you cannot recover.

Only install releases from a source you trust.

---

# Porting to Another Device

A successful port requires identifying the equivalent components on the target device.

At minimum, determine:

```text
1. Fingerprint vendor
2. Fingerprint HAL/API
3. Fingerprint library
4. FOD sysfs interface
5. Touch input device
6. Touch event code
7. DRM device
8. Local-HBM interface
9. Local-HBM parameters
10. Capture timing
```

A port should not be considered complete until fingerprint enrollment, authentication, cancellation, screen-off behavior, low-brightness behavior, and display restoration have all been tested.

---

# Credits

Developed and tested for the Motorola Boston GSI/custom-ROM environment.

Special focus of this project:

```text
Native Local-HBM
+
Goodix optical UDFPS
+
Motorola fingerprint HIDL
+
Linux input events
+
Root-level Android integration
```

---

# License

This project is licensed under the **MIT License**.

See [`LICENSE`](LICENSE) for the complete license text.

---

# Disclaimer

This is an experimental hardware integration project.

The software directly interacts with the display driver, input subsystem, sysfs interfaces, and vendor fingerprint implementation.

Incorrect modifications can result in:

* Fingerprint failure
* Display problems
* Crashes
* Boot issues
* Stuck Local-HBM
* Other unexpected behavior

Keep a working recovery/fastboot environment and a known-good firmware package before testing.

---

# Project Goal

The goal of this project is to provide a small native bridge that restores the hardware-specific FOD behavior required by Motorola Boston on GSI/custom-ROM environments while retaining the existing Motorola fingerprint implementation.

**Boston is the current target. Other devices require their own hardware-specific investigation and adaptation.**
