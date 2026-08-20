# Motorola Native Local-HBM UDFPS Bridge

> A simple native C++ bridge for bringing back **optical in-display fingerprint (UDFPS/FOD) scanning on Motorola devices running a GSI** by using the device's existing vendor fingerprint stack and native Local-HBM support.

<p align="center">
  <img src="https://img.shields.io/badge/Android-GSI-green?style=for-the-badge" alt="Android GSI">
  <img src="https://img.shields.io/badge/Motorola-UDFPS-blue?style=for-the-badge" alt="Motorola UDFPS">
  <img src="https://img.shields.io/badge/Local--HBM-Native-orange?style=for-the-badge" alt="Local HBM">
  <img src="https://img.shields.io/badge/Magisk-Module-red?style=for-the-badge" alt="Magisk">
  <img src="https://img.shields.io/badge/Language-C%2B%2B17-purple?style=for-the-badge" alt="C++17">
</p>

---

## 📖 Why I Made This

This project started because of a very simple GSI problem.

When I first installed a GSI on my Motorola device, Android thought the fingerprint sensor was a **rear-mounted fingerprint sensor**.

The fingerprint icon was therefore shown in the wrong place.

### Step 1 — The "Fingerprint on Back" problem

The first thing I had to fix was the UDFPS position.

I created a framework/SystemUI overlay and supplied the correct fingerprint sensor position and size.

After that:

- The fingerprint icon appeared in the **correct position**.
- Android knew that there was an under-display fingerprint sensor.
- The UI looked correct.

But the fingerprint still **did not work**.

---

## ❌ The Second Problem — No HBM

This was the real problem.

The fingerprint circle appeared on the screen, but when I touched it:

- The display did not illuminate the fingerprint area.
- Local-HBM was not triggered.
- The optical sensor could not see the fingerprint.
- Enrollment failed.
- Unlocking failed.

The UI was working, but the hardware was not being illuminated.

At this point I asked other developers about it.

The answer I received was basically:

> Port the fingerprint HIDL from a donor device.

That meant dealing with complicated vendor fingerprint HALs, HIDL interfaces, libraries and potentially replacing or porting large parts of the biometric stack.

I didn't want to do that.

The important discovery was that **the stock Motorola vendor fingerprint components were already present and working on the device**.

The problem was not necessarily that the fingerprint HAL needed to be replaced.

The missing part was the bridge between:

```text
AOSP GSI
   ↓
UDFPS prompt
   ↓
FOD touch event
   ↓
Native Local-HBM
   ↓
Motorola fingerprint HIDL
   ↓
TrustZone / fingerprint sensor
```

So instead of porting a donor HIDL, this project uses a small native C++ program to connect the pieces that were already present.

---

# 🧠 How This Project Works

The bridge does a few simple things.

### 1. Watches the Android biometric state

It listens to `logcat` for biometric/UDFPS events.

When a fingerprint session or enrollment starts:

```text
Sensor Armed
```

When the session ends:

```text
Sensor Disarmed
```

---

### 2. Watches the FOD touch event

The bridge reads the Linux input device:

```text
/dev/input/eventX
```

and waits for the FOD keycode.

For the original Boston implementation this was:

```text
event10
704 / 0x2c0
```

**These values are NOT universal.**

You must replace them with the values from your own device.

---

### 3. Enables Local-HBM

When the FOD touch is detected, the bridge sends:

```text
DRM_IOCTL_MDSS_DISP_PARAM
```

to:

```text
/dev/dri/card0
```

On the reference Boston implementation:

```text
param0 = 2
param1 = 2
param2 = 0
```

This activates the panel's native Local-HBM mode.

The important part is that **only the fingerprint area is illuminated**, instead of making the whole screen extremely bright.

---

### 4. Sends the fingerprint event to Motorola's vendor HAL

The bridge dynamically loads:

```text
/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
```

and calls Motorola's existing:

```text
IMotoFingerPrint
```

interface.

The FOD events are:

```text
sendFodEvent(0)
```

for capture/start and:

```text
sendFodEvent(1)
```

for release/stop.

Again, these are based on the working reference implementation and may need adjustment for another Motorola device/software branch.

---

# ⭐ What Makes This Different?

The goal of this project is **not** to replace the vendor fingerprint HAL.

It is also **not** to build a complete vendor image.

The idea is much simpler:

```text
Keep the stock vendor fingerprint hardware/software
                +
Use your GSI normally
                +
Add a small native bridge
                ↓
        Native Local-HBM FOD
```

That's why this can be useful for people experimenting with Motorola GSIs.

---

# 📱 Porting This To Your Motorola Device

You do **not** need to build a complete vendor partition.

You do **not** need to port an entire donor fingerprint HAL.

You do **not** need to rebuild Android.

The basic idea is:

> Find the few hardware/software values that are different on your device, replace them in `moto_fod_bridge.cpp`, build it, and package it as a Magisk module.

---

# ⚠️ Important Before You Start

This project was developed and tested from a **GSI environment**.

It assumes your device already has a working stock vendor partition containing the necessary fingerprint components.

This is **not a replacement fingerprint HAL**.

If your stock vendor does not contain the required fingerprint hardware implementation, this bridge cannot magically create one.

---

# 🧰 Prerequisites

You need:

- A Motorola device with an **optical under-display fingerprint sensor**
- A working **GSI/custom ROM**
- Stock/compatible Motorola vendor partition
- Root access
- Magisk or KernelSU
- Termux
- Basic Linux/Termux knowledge
- USB/ADB access is useful
- `clang++`
- `git`
- `zip`

Install the basic tools in Termux:

```bash
pkg update
pkg install clang git zip -y
```

Check:

```bash
clang++ --version
git --version
zip -v
```

---

# 🔎 Step 1 — Find Your FOD Input Event

First find which input device produces the fingerprint event.

As root:

```bash
su
getevent -l
```

Now touch the fingerprint sensor.

You should see many events.

Look for an event such as:

```text
/dev/input/event10
```

and a key code such as:

```text
KEY_UNKNOWN (704)
```

or:

```text
0x2c0
```

Your device may be completely different.

For example:

```text
/dev/input/event8
```

with:

```text
704
```

Then change this line in the C++ source:

```cpp
int fd = open("/dev/input/event10", O_RDONLY | O_NONBLOCK);
```

to:

```cpp
int fd = open("/dev/input/event8", O_RDONLY | O_NONBLOCK);
```

And change the keycode check if necessary:

```cpp
if (ev.type == EV_KEY && (ev.code == 704 || ev.code == 0x2c0))
```

---

# 🔎 Step 2 — Find Your FOD Sysfs Node

The reference device uses:

```text
/sys/devices/platform/goodix_ts.0/gesture/fod_en
```

Check your device:

```bash
find /sys -iname "*fod*" 2>/dev/null
```

You can also inspect Goodix-related nodes:

```bash
find /sys -iname "*goodix*" 2>/dev/null
```

If your node is different, change:

```cpp
static const char* FOD_EN_NODE =
    "/sys/devices/platform/goodix_ts.0/gesture/fod_en";
```

For example:

```cpp
static const char* FOD_EN_NODE =
    "/sys/devices/platform/goodix_ts.1/gesture/fod_en";
```

Do **not** copy the Boston path blindly.

---

# 🔎 Step 3 — Check the Motorola Fingerprint Library

Check:

```bash
su -c 'ls -l /vendor/lib64/ | grep -i motorola.*fingerprint'
```

The reference implementation uses:

```text
/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
```

You can check directly:

```bash
su -c 'ls -l /vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so'
```

If the file exists, that's a good sign.

If your device uses another version/name, the library path and symbols in the C++ source may need to be changed.

**Do not guess the HIDL symbols.** Extract/inspect them from your device's actual vendor library.

---

# 🔎 Step 4 — Find Your Local-HBM Parameters

This is the most device-specific part.

The reference implementation uses:

```text
Mode 4

param0 = 2
param1 = 2
param2 = 0
```

The source contains:

```cpp
if (mode == 4) {
    req.param_id = 0;
    req.value = 2;

    req.param_id = 1;
    req.value = 2;

    req.param_id = 2;
    req.value = 0;
}
```

Your panel may use different values.

### Simple test program

Create:

```bash
nano ~/test_lhbm.c
```

Put:

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

If that does nothing, **do not randomly spam parameters on your main device**.

You need to investigate the stock display implementation/vendor sources/logs to determine which MDSS display parameter controls FOD/Local-HBM on your panel.

Once you find the working values, replace the values inside:

```cpp
set_panel_mode()
```

---

# 🔎 Step 5 — Check the DRM Device

The reference implementation uses:

```text
/dev/dri/card0
```

Check:

```bash
ls -l /dev/dri/
```

If your display device is different, update:

```cpp
g_drm_fd = open("/dev/dri/card0", O_RDWR);
```

Do not assume `card0` is always the correct display node.

---

# 🔎 Step 6 — Build the Bridge

Clone the repository:

```bash
git clone https://github.com/Emii31/Motorola-UDFPS-bridge.git
cd Motorola-UDFPS-bridge
```

The repository contains:

```text
Motorola-UDFPS-bridge/
├── src/
│   └── moto_fod_bridge.cpp
├── magisk_module/
│   ├── module.prop
│   ├── service.sh
│   ├── META-INF/
│   └── vendor/
│       └── bin/
│           └── moto_fod_bridge
├── build.sh
├── zip_module.sh
└── README.md
```

---

# 🛠️ Step 7 — Modify Only The Device-Specific Values

Open:

```bash
nano src/moto_fod_bridge.cpp
```

The main values you may need to change are:

### FOD sysfs node

```cpp
static const char* FOD_EN_NODE =
    "/sys/devices/platform/goodix_ts.0/gesture/fod_en";
```

### Input device

```cpp
int fd = open("/dev/input/event10", O_RDONLY | O_NONBLOCK);
```

### FOD keycode

```cpp
ev.code == 704
```

or:

```cpp
ev.code == 0x2c0
```

### DRM display node

```cpp
g_drm_fd = open("/dev/dri/card0", O_RDWR);
```

### Local-HBM parameters

Inside:

```cpp
set_panel_mode()
```

### Motorola fingerprint library

```cpp
dlopen("/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so", RTLD_NOW);
```

These are the important device-specific areas.

**Do not rewrite the whole program just because your device has a different event number.**

---

# 🔨 Step 8 — Use The Included Build Script

The repository now contains:

```text
build.sh
```

Make it executable:

```bash
chmod +x build.sh
```

Run:

```bash
./build.sh
```

The script compiles:

```text
src/moto_fod_bridge.cpp
```

into:

```text
magisk_module/vendor/bin/moto_fod_bridge
```

The important compiler command is:

```bash
clang++ -std=c++17 -O3 \
    src/moto_fod_bridge.cpp \
    -o magisk_module/vendor/bin/moto_fod_bridge \
    -lpthread -ldl
```

---

# 📦 Step 9 — Build The Magisk ZIP

After the binary is successfully compiled:

```bash
chmod +x zip_module.sh
./zip_module.sh
```

The flashable package will be created under:

```text
out/
```

For example:

```text
out/Moto_Native_Local_HBM_FOD_Bridge_v4.zip
```

---

# 📲 Step 10 — Install

Transfer the ZIP to your phone.

Open:

```text
Magisk → Modules → Install from storage
```

Select the ZIP.

Reboot.

The module's `service.sh` starts the bridge automatically.

---

# 🔐 Why The Binary Is Mounted Into Vendor

One important Android problem we encountered was the **Bionic linker namespace**.

The binary needs to load:

```text
/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
```

Simply executing the binary from a normal location such as:

```text
/system/bin/
```

can put the process into a linker namespace that cannot access the required vendor library.

The module therefore places/mounts the binary into the vendor environment.

This is handled by the module's startup script.

**Do not remove the vendor bind-mount logic unless you know your ROM already provides the required vendor linker namespace.**

---

# 🧩 What The Current Bridge Does

The current implementation has four important parts.

| Part | What it does |
|---|---|
| `session_listener_thread()` | Watches biometric/Android state |
| `enroll_watchdog_thread()` | Prevents enrollment from leaving FOD armed forever |
| Input event reader | Detects the physical FOD touch |
| `set_panel_mode()` + `sendFodEvent()` | Enables Local-HBM and tells the fingerprint HAL to capture |

---

# 🛡️ Enrollment Watchdog

One problem I encountered was particularly annoying.

During enrollment, Android sometimes didn't immediately send the expected "hide UDFPS" event.

That meant:

```text
g_session_active = true
```

could remain active after enrollment.

Then I could unlock the phone and later:

- type on the keyboard
- scroll
- touch the screen

and accidentally trigger the FOD hardware.

The current version therefore has an enrollment watchdog.

If enrollment remains idle for more than:

```text
2.5 seconds
```

the bridge automatically disarms the sensor.

This is handled by:

```cpp
enroll_watchdog_thread()
```

---

# 🙂 Face Unlock / Unlock Handling

Another problem was Face Unlock.

Face Unlock could unlock the phone without immediately producing the exact fingerprint-session event the bridge was waiting for.

The current session listener therefore watches additional Android transitions such as:

```text
keyguardGoingAway
setKeyguardOccluded(false)
dismissKeyguard
startExitAnimation
Launcher
```

This allows the bridge to shut down the FOD session when Android has already moved to the home screen.

---

# ⚡ Performance

The bridge does **not** repeatedly execute:

```text
dumpsys
```

in a loop.

That was one of the problems with an earlier approach.

Instead it uses:

```text
logcat stream
        +
non-blocking input events
        +
small watchdog thread
```

The main input loop sleeps for:

```text
2ms
```

and the enrollment watchdog checks every:

```text
250ms
```

---

# 🔧 Reference Boston Values

The original working implementation was developed around a Motorola **Boston** device.

These are therefore reference values, **not universal values**:

```text
FOD input:
    /dev/input/event10

FOD keycode:
    704 / 0x2c0

FOD sysfs:
    /sys/devices/platform/goodix_ts.0/gesture/fod_en

DRM:
    /dev/dri/card0

Local-HBM:
    param0 = 2
    param1 = 2
    param2 = 0

Fingerprint library:
    /vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so

FOD payload:
    0x03

Capture event:
    sendFodEvent(0)

Release event:
    sendFodEvent(1)

Integration time:
    ~160ms
```

If you are using **Boston**, these are the starting values.

If you are porting to another Motorola device, verify them first.

---

# 🧪 Troubleshooting

## Fingerprint icon is still on the back

This is **not a Local-HBM bridge problem**.

You need to fix your GSI's UDFPS/framework/SystemUI configuration first.

The bridge assumes Android already knows that the device has an under-display fingerprint sensor.

---

## Fingerprint icon is in the correct position but nothing happens

Check:

```bash
getevent -l
```

Make sure the bridge is listening to the correct:

```text
/dev/input/eventX
```

and correct:

```text
FOD keycode
```

---

## `dlopen failed`

Check:

```bash
ls -l /vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so
```

Then check that the binary is actually being executed in the vendor environment created by the module.

Also inspect:

```bash
logcat | grep -i moto_fod
```

and:

```bash
dmesg | grep -i avc
```

SELinux denials can prevent access even when the library exists.

---

## Local-HBM does not illuminate

Your panel's Local-HBM implementation may not use:

```text
2 2 0
```

Those values belong to the reference implementation.

You need to identify the correct display parameter values for your panel.

---

## HBM works but fingerprint still doesn't enroll

Check whether:

```text
sendFodEvent(0)
```

is actually being reached.

Look at the bridge output/logs.

Then verify that the Motorola fingerprint library and its HIDL interface match your vendor build.

HBM alone is not enough.

The optical sensor also needs the vendor fingerprint stack to receive the appropriate capture event.

---

## HBM flashes while typing or scrolling

The biometric session is probably still armed.

Check the session log.

The current version includes:

- authentication end detection
- enrollment completion detection
- keyguard transitions
- Launcher transitions
- enrollment inactivity watchdog

If your ROM uses different log messages, add the relevant string to:

```cpp
session_listener_thread()
```

---

# 📝 Simple Porting Checklist

If you're trying this on another Motorola device, don't overcomplicate it.

Start with these:

```text
[ ] Device has optical UDFPS
[ ] GSI is already running
[ ] Stock vendor is intact
[ ] Device is rooted
[ ] FOD input event identified
[ ] FOD keycode identified
[ ] FOD sysfs node identified
[ ] /dev/dri/cardX identified
[ ] Local-HBM parameters identified
[ ] Motorola fingerprint library identified
[ ] C++ values changed
[ ] build.sh completed successfully
[ ] Magisk ZIP created
[ ] Module installed
[ ] Rebooted
[ ] Tested enrollment
[ ] Tested unlocking
```

That's it.

You are **not** building a complete vendor.

You are **not** porting an entire fingerprint HAL.

You are adapting a small bridge to the hardware that already exists on your device.

---

# ⚠️ Important Limitations

This project is not guaranteed to work on every Motorola UDFPS device.

Motorola has used different:

- display panels
- fingerprint sensors
- vendor software versions
- HIDL versions
- input nodes
- sysfs nodes
- DRM implementations
- Local-HBM implementations

So a different device may require different values or additional source changes.

The README is intentionally simple, but that does not mean every Motorola device is plug-and-play.

---

# 📂 Repository Structure

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
└── README.md
```

---

# 🤝 Contributing

If you successfully port this to another Motorola device, please share the values you discovered.

Useful information includes:

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

This can make future ports much easier.

---

# 📜 License

This project is released under the **MIT License**.

See:

```text
LICENSE
```

for the complete license text.

---

# ⚠️ Disclaimer

This project modifies low-level display and fingerprint behavior.

A wrong DRM parameter, input node, vendor interface, or HIDL call can cause crashes, broken fingerprint functionality, or other unexpected behavior.

**Use at your own risk.**

Always keep a working firmware/vendor backup before experimenting.

---

## ❤️ Final Note

This project started with a very simple problem:

> **The GSI said the fingerprint was on the back.**

After fixing the position with an overlay, the next problem was:

> **The fingerprint was in the right place, but the screen never illuminated it.**

The obvious answer was to port a donor fingerprint HIDL.

Instead, the approach here was to leave the existing Motorola vendor fingerprint stack alone and build a small bridge that connects the GSI's fingerprint session to the hardware functions that were already there.

That's what this repository is for.
