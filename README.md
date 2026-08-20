# Motorola Native Local-HBM FOD Bridge

A high-performance Magisk module that implements native **Local-HBM (High Brightness Mode)** optical fingerprint (UDFPS / FOD) support for Motorola devices running Generic System Images (GSIs) or custom ROMs.

> **Project status:** Experimental / device-specific  
> **Target:** Motorola devices with optical in-display fingerprint sensors  
> **Root:** Magisk or KernelSU required

---

## 🎯 The Ultimate Story: How We Solved the Motorola GSI FOD Nightmare

### 1. The Initial Problem — The "Fingerprint on Back" Bug

When you flash a clean GSI or custom ROM onto an optical in-display fingerprint Motorola device, Android may use generic system configuration and incorrectly assume that the device has a physical rear-mounted fingerprint scanner.

The result is predictable:

- The UDFPS/FOD icon does not appear correctly.
- Optical fingerprint enrollment may fail.
- Fingerprint unlocking does not work as expected.
- SystemUI may behave as though the device has a conventional fingerprint reader.

The first task was therefore to make Android correctly understand the physical fingerprint sensor configuration.

---

### 2. Our First Attempt — Building the Overlay Module

To fix the "fingerprint on back" problem, we created custom framework and SystemUI overlays similar in concept to Motorola/Treble overlays.

The overlay provided device-specific information such as:

- UDFPS sensor position.
- Sensor radius.
- Display dimensions.
- SystemUI/FOD-related resources.
- Device-specific fingerprint configuration.

### Result

The optical fingerprint circle finally appeared in the correct location on the lockscreen.

That proved an important point:

> **The display-side UDFPS UI could be corrected without replacing the entire biometric stack.**

But there was still a much bigger problem.

---

## 3. The Major Roadblock — No Illumination and Failed Reads

Although the fingerprint icon appeared, the optical sensor still could not successfully read a fingerprint.

The main symptoms were:

- No proper Local-HBM activation.
- No localized illumination under the fingerprint sensor.
- Fingerprint reads failed.
- Generic AOSP full-screen brightness/scrim approaches produced poor results.
- Screen-off and low-brightness scenarios were especially problematic.

At this stage, one proposed solution was to port, decompile, and recompile complex donor-device HIDL components.

That approach was rejected because it would introduce a large amount of device-specific vendor code when the stock Motorola biometric infrastructure was already present.

---

# 4. The Breakthrough — Bypassing the HIDL Rewrite

The key discovery was that the stock Motorola fingerprint HAL was already present and active in the vendor environment.

The missing piece was not necessarily a completely broken fingerprint HAL.

Instead, the problem was the connection between:

1. SystemUI / biometric prompt state.
2. Touch input.
3. The display panel's native Local-HBM mechanism.
4. The Motorola fingerprint capture path.

The proposed solution was therefore a small native C++ background service:

```text
                ┌─────────────────────┐
                │ Android / SystemUI  │
                │   Biometric Prompt  │
                └──────────┬──────────┘
                           │
                           ▼
                ┌─────────────────────┐
                │   moto_fod_bridge   │
                │     C++ daemon      │
                └──────┬───────┬──────┘
                       │       │
             Touch ────┘       └──── Display DRM
                       │               │
                       ▼               ▼
              Fingerprint HAL     Local-HBM
                       │               │
                       └───────┬───────┘
                               ▼
                     Optical Fingerprint
                           Sensor
```

The bridge is intended to synchronize the touch event, display Local-HBM state, and fingerprint capture path without replacing the complete vendor biometric implementation.

---

# 🛠️ How the Bridge Works

The bridge is designed around three primary operations.

## 1. Listen for Touch Events

The daemon monitors the Linux input subsystem for the touchscreen event associated with the fingerprint interaction.

When the user places a finger over the UDFPS area, the bridge detects the relevant event.

Example:

```text
/dev/input/event10
```

The actual event node is device-specific and **must not be assumed**.

---

## 2. Trigger Native Local-HBM

When the fingerprint interaction is detected, the bridge attempts to communicate with the display driver through the DRM interface.

The experimental implementation uses:

```c
DRM_IOCTL_MDSS_DISP_PARAM
```

with a device-specific parameter set.

One tested parameter combination was:

```text
2 2 0
```

Conceptually:

```text
finger touches UDFPS
        ↓
bridge detects event
        ↓
DRM ioctl
        ↓
panel enters Local-HBM
        ↓
only fingerprint region receives high brightness
```

Unlike a software white overlay or full-screen brightness boost, Local-HBM is intended to activate the panel's hardware-supported fingerprint illumination region.

---

## 3. Synchronize Fingerprint Capture

The bridge can also communicate with the Motorola fingerprint implementation through the appropriate vendor interface available on the target device.

The intended event sequence is:

```text
Finger Down
    ↓
Enable Local-HBM
    ↓
Start / notify fingerprint capture
    ↓
Sensor reads fingerprint
    ↓
Finger Up
    ↓
Disable fingerprint illumination
    ↓
Restore normal display state
```

The exact Motorola fingerprint API, library name, symbol, and event semantics are **device and firmware dependent**.

Do not blindly copy a library path or ABI from another Motorola model.

---

# 📱 Adapting This to Another Motorola Device

This project is not a universal plug-and-play UDFPS solution.

Different Motorola devices can use different:

- Display panels.
- DRM implementations.
- Kernel drivers.
- Input event layouts.
- Fingerprint vendors.
- Vendor HAL versions.
- SELinux policies.
- Android framework versions.
- Local-HBM parameter mappings.

Therefore, porting requires hardware-specific investigation.

---

# Prerequisites

You need:

- A Motorola device with an optical UDFPS/FOD sensor.
- A rooted Android installation.
- Magisk or KernelSU.
- Termux.
- Root shell access.
- Basic Linux command-line knowledge.
- Basic C/C++ compilation knowledge.

Install the basic compilation environment in Termux:

```bash
pkg update
pkg install clang git make
```

Then obtain a root shell:

```bash
su
```

> **Warning:** The DRM ioctl experiments below can change display behavior or potentially destabilize the display stack. Test on hardware you can recover. Keep a known-good boot/recovery path available.

---

# Step 1 — Find Your Touch Event Input Node

The first requirement is identifying which Linux input device reports the touchscreen/fingerprint-area interaction.

From a root Termux shell:

```bash
getevent -l
```

Now touch and hold the fingerprint area.

You may see output similar to:

```text
/dev/input/event10: EV_ABS ABS_MT_POSITION_X ...
/dev/input/event10: EV_ABS ABS_MT_POSITION_Y ...
```

The actual event number will vary by device.

For example:

```text
/dev/input/event10
```

is only an example.

### What to Record

Record:

- Input device path.
- Event node number.
- Relevant event type.
- Relevant ABS/KEY code.
- X/Y coordinates.
- Finger-down/finger-up behavior.

Do not hard-code `event10` just because another device uses it.

A better implementation should ideally identify the correct input device by its device name or capabilities instead of relying exclusively on an event number.

---

# Step 2 — Investigate the Local-HBM Interface

Different display panels may expose different mechanisms for Local-HBM.

Possible panel/display implementations can vary between:

- BOE
- CSOT
- Samsung
- Tianma
- Other panel vendors

Even devices from the same manufacturer may use different implementations.

The following test program demonstrates the experimental ioctl interface.

Create the test source:

```bash
cat << 'EOF' > ~/test_lhbm.c
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

int main(int argc, char** argv)
{
    if (argc < 4) {
        printf("Usage: %s <p0> <p1> <p2>\n", argv[0]);
        return 1;
    }

    int fd = open("/dev/dri/card0", O_RDWR);

    if (fd < 0) {
        perror("open card0 failed");
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
EOF
```

Compile it:

```bash
clang -O3 ~/test_lhbm.c -o ~/test_lhbm
```

---

## Testing Parameters

An example test is:

```bash
su -c '~/test_lhbm 2 2 0'
```

Another possible test could be:

```bash
su -c '~/test_lhbm 1 0 0'
```

However:

> **Do not assume that these values are correct for your device.**

The `2 2 0` combination is a device-specific experimental value, not a universal Local-HBM standard.

If your panel supports this interface and the parameters are correct, the display may enter its native Local-HBM state.

The desired behavior is:

```text
Normal display
      ↓
Local-HBM enabled
      ↓
Fingerprint region becomes highly illuminated
      ↓
Normal display restored
```

If nothing happens, that does **not** prove that the panel lacks Local-HBM. The ioctl number, structure, parameter IDs, DRM node, permissions, or vendor display implementation may simply differ.

---

# Step 3 — Verify the Motorola Fingerprint Implementation

Inspect the vendor partition for Motorola biometric libraries:

```bash
su -c 'find /vendor/lib64 -maxdepth 2 -type f -iname "*fingerprint*" -o -iname "*biometric*"'
```

A device may contain libraries resembling:

```text
/vendor/lib64/com.motorola.hardware.biometric.fingerprint*.so
```

The exact filename and API version can differ.

You should determine:

- Which fingerprint HAL is actually running.
- Which library it loads.
- Whether it is HIDL, AIDL, or a vendor-specific interface.
- Which symbols/interfaces are available.
- Which process owns the fingerprint HAL.
- How the stock ROM triggers FOD illumination.
- How fingerprint capture is started/stopped.

Useful investigation commands include:

```bash
ps -A | grep -i finger
```

```bash
logcat -b all | grep -iE 'fingerprint|udfps|fod|hbm|biometric'
```

```bash
dumpsys fingerprint
```

and, where available:

```bash
lshal | grep -i finger
```

> Do not assume that `V1_0`, `V1_1`, or a particular Motorola library name applies to another device. Determine the actual interface from the target firmware.

---

# Step 4 — Build the Native Bridge

Once the device-specific input node, display interface, and fingerprint mechanism have been identified, compile the bridge.

Example:

```bash
clang++ \
    -std=c++17 \
    -O3 \
    moto_fod_bridge.cpp \
    -o moto_fod_bridge \
    -lpthread \
    -ldl
```

For production builds, the source should ideally include:

- Input-device discovery.
- Robust event parsing.
- Finger-down detection.
- Finger-up detection.
- Local-HBM state management.
- Fingerprint capture synchronization.
- Error handling.
- Logging.
- Cleanup on process termination.
- Duplicate-event protection.
- Timeout handling.
- Recovery if the display or fingerprint service restarts.

---

# 📦 Magisk Module Structure

A basic module can use this structure:

```text
moto-fod-bridge/
├── module.prop
├── service.sh
└── system/
    └── bin/
        └── moto_fod_bridge
```

### `module.prop`

Example:

```text
id=moto-fod-bridge
name=Motorola Native Local-HBM FOD Bridge
version=1.0
versionCode=1
author=YourName
description=Native Local-HBM bridge for Motorola optical UDFPS devices
```

### `service.sh`

Example:

```sh
#!/system/bin/sh

MODDIR=${0%/*}

# Wait for Android services to finish starting.
sleep 15

chmod 0755 "$MODDIR/system/bin/moto_fod_bridge"

"$MODDIR/system/bin/moto_fod_bridge" >/dev/null 2>&1 &
```

Make it executable:

```bash
chmod 0755 service.sh
```

> A production module should not blindly start the daemon after a fixed 15-second delay. A better implementation waits for the required Android/vendor services and verifies that the device is actually ready.

---

# 🔬 Recommended Debugging

Before making the daemon completely silent, log its state.

For example:

```text
[moto_fod] bridge started
[moto_fod] input device found: /dev/input/event10
[moto_fod] biometric prompt detected
[moto_fod] finger down
[moto_fod] enabling Local-HBM
[moto_fod] fingerprint capture requested
[moto_fod] finger up
[moto_fod] disabling Local-HBM
```

Then inspect the logs:

```bash
logcat | grep moto_fod
```

This makes failures much easier to diagnose.

---

# ⚠️ Important Technical Limitations

This project should **not** be described as a universal Motorola UDFPS solution.

The following assumptions may be wrong on another device:

```text
/dev/input/event10
```

```text
DRM_IOCTL_MDSS_DISP_PARAM
```

```text
0xc008649f
```

```text
2 2 0
```

```text
/vendor/lib64/com.motorola.hardware.biometric.fingerprint*.so
```

They are examples based on a particular Motorola/vendor architecture.

A successful port requires validating every one of these components.

---

# 🧪 Troubleshooting

## Fingerprint icon does not appear

Check:

```bash
adb shell dumpsys fingerprint
```

and inspect:

```bash
logcat | grep -iE 'udfps|fingerprint|biometric'
```

If the sensor is not recognized by Android, the problem may be framework/resource configuration rather than Local-HBM.

---

## Fingerprint icon appears but sensor does not illuminate

Investigate:

```bash
logcat | grep -iE 'hbm|fod|fingerprint|display'
```

Then determine how the stock firmware enters Local-HBM.

Do not immediately assume the DRM ioctl used by this project is correct.

---

## Local-HBM test does nothing

Verify:

```bash
ls -l /dev/dri/
```

Check whether:

```text
/dev/dri/card0
```

is the correct DRM device.

Also inspect kernel/display logs:

```bash
dmesg | grep -iE 'drm|mdss|dsi|panel|display'
```

Root permissions alone do not guarantee that an ioctl is valid for the current kernel driver.

---

## Fingerprint illumination works but authentication fails

This usually means the display side and biometric side are not synchronized correctly.

Investigate:

- Finger-down timing.
- Finger-up timing.
- Fingerprint HAL state.
- Touch coordinates.
- Biometric prompt state.
- Sensor acquisition calls.
- Vendor fingerprint logs.

Local-HBM alone does not implement fingerprint authentication.

---

## Screen becomes stuck in Local-HBM

The daemon must always restore the normal panel state when:

- Finger-up occurs.
- Authentication finishes.
- Authentication is cancelled.
- The biometric prompt disappears.
- The process receives `SIGTERM`.
- The fingerprint service dies.
- The display service restarts.

A production bridge should include watchdog and cleanup logic.

---

# 🧠 Why We Avoided Porting a Donor HIDL

Porting a donor fingerprint HIDL can work in some circumstances, but it is not automatically the correct solution.

It can introduce:

- ABI incompatibilities.
- Vendor library dependencies.
- SELinux policy problems.
- VINTF conflicts.
- Kernel/vendor mismatches.
- Hardware-specific assumptions.
- Additional maintenance burden.

If the stock Motorola fingerprint HAL already works, replacing it simply to obtain FOD illumination can be unnecessarily invasive.

The preferred strategy is:

```text
Keep working vendor biometric stack
              +
Provide the missing display/input bridge
              =
Device-specific UDFPS integration
```

This is considerably smaller than replacing the complete biometric architecture.

---

# 🏗️ Recommended Architecture

A mature implementation should look approximately like this:

```text
                  Android Framework
                         │
                         ▼
                 Biometric Prompt
                         │
                         ▼
                ┌─────────────────┐
                │ moto_fod_bridge │
                └───────┬─────────┘
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
     Input Events    Display DRM   Fingerprint HAL
          │             │             │
          ▼             ▼             ▼
      Finger Down   Local-HBM      Sensor Capture
          │             │             │
          └─────────────┼─────────────┘
                        ▼
                Optical UDFPS Sensor
```

The important design principle is **synchronization**, not simply forcing brightness.

---

# 📋 Porting Checklist

Before calling a port successful, verify all of the following:

- [ ] UDFPS sensor is correctly recognized by Android.
- [ ] UDFPS icon appears at the correct coordinates.
- [ ] Correct touchscreen input device identified.
- [ ] Finger-down event reliably detected.
- [ ] Finger-up event reliably detected.
- [ ] Correct DRM device identified.
- [ ] Local-HBM interface identified.
- [ ] Correct Local-HBM parameters confirmed.
- [ ] Stock fingerprint HAL confirmed working.
- [ ] Fingerprint capture synchronized with Local-HBM.
- [ ] Screen-off behavior tested.
- [ ] Low-brightness behavior tested.
- [ ] Authentication cancellation tested.
- [ ] Finger removal tested.
- [ ] Display restoration tested.
- [ ] Boot-time startup tested.
- [ ] SELinux behavior checked.
- [ ] Crash/restart recovery tested.

---

# 📦 Installation — Boston / Compatible Devices

If a tested release is available, installation is straightforward:

1. Download the release ZIP from the repository's **Releases** page.
2. Open Magisk.
3. Install the module ZIP.
4. Reboot.
5. Test fingerprint enrollment and authentication.

Do **not** flash an unverified build simply because another Motorola device uses the same fingerprint technology.

---

# ⚠️ Disclaimer

This is an experimental, device-specific hardware integration project.

You are modifying a rooted Android system and potentially interacting directly with the display driver.

Incorrect:

- DRM ioctls,
- panel parameters,
- input handling,
- vendor-library assumptions,
- permissions,
- SELinux rules,
- or fingerprint synchronization

can cause crashes, broken fingerprint functionality, display problems, or boot issues.

Always keep a known-good firmware package and recovery/fastboot access available before experimenting.

---

# 🤝 Contributing

Contributions are welcome.

Useful contributions include:

- Tested Motorola device ports.
- Panel/Local-HBM parameter discoveries.
- DRM interface documentation.
- Input-device detection improvements.
- Fingerprint HAL reverse-engineering results.
- SELinux policy fixes.
- Kernel/display driver information.
- Better daemon lifecycle handling.
- Reproducible build instructions.

When submitting a device port, include as much of the following as possible:

```text
Device:
Model:
Android version:
Build:
Kernel:
Panel:
Fingerprint vendor:
Input node:
DRM device:
Local-HBM mechanism:
Local-HBM parameters:
Fingerprint HAL:
Working / Not working:
Logs:
```

---

# 📜 License

Choose and add an appropriate open-source license before publishing the repository.

For example:

```text
MIT License
```

or another license appropriate for the project's source and any third-party components.

---

# ⭐ Project Goal

The goal of this project is simple:

> **Make native Motorola optical UDFPS work on GSI/custom-ROM environments without unnecessarily replacing the entire vendor biometric stack.**

The long-term objective is a small, reliable, device-aware bridge between Android's biometric UI, touch input, the display's native Local-HBM implementation, and the existing Motorola fingerprint HAL.
