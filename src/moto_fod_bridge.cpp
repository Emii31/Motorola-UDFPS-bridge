#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <linux/input.h>
#include <stdint.h>
#include <time.h>
#include <stdarg.h>
#include <stdbool.h>

#include "../include/device_config.h"

// =============================================================================
// DRM / IOCTL Definitions
// =============================================================================
#define DRM_IOCTL_MDSS_DISP_PARAM 0xc008649f

struct disp_param_req {
    uint32_t param_id;
    int32_t value;
};

// =============================================================================
// Fallback Paths
// =============================================================================
static const char* SYSFS_LHBM_FALLBACKS[] = {
    "/sys/class/drm/card0-DSI-1/dimlayer_hbm",
    "/sys/devices/platform/soc/soc:qcom,dsi-display-primary/hbm",
    "/sys/class/backlight/panel0-backlight/hbm_mode",
    "/sys/class/graphics/fb0/hbm",
    NULL
};

static const char* TARGET_LIBS[] = {
    "/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so",
    "/vendor/lib64/hw/android.hardware.biometrics.fingerprint@2.1-service-jv.so",
    "/vendor/lib64/hw/android.hardware.biometrics.fingerprint@2.1-service.so",
    "/vendor/lib64/hw/fingerprint.default.so",
    NULL
};

// Known Motorola HIDL C++ Mangled Symbols for BpHwMotoFingerPrint::sendFodEvent(int32_t)
static const char* MOTO_HIDL_SYMBOLS[] = {
    "_ZN8android8hardware9biometrics11fingerprintV1_020BpHwMotoFingerPrint12sendFodEventEi",
    "_ZN7vendor8motorola8hardware9biometrics11fingerprintV1_020BpHwMotoFingerPrint12sendFodEventEi",
    "sendFodEvent", // Direct fallback
    NULL
};

// =============================================================================
// Global State & Session Gating
// =============================================================================
static bool g_debug_mode = false;
static bool g_file_log_mode = false;
static FILE* g_log_file = NULL;

static bool g_session_active = false;
static pthread_mutex_t g_session_lock = PTHREAD_MUTEX_INITIALIZER;

static int g_drm_fd = -1;
static void* g_hal_handle = NULL;

// Function Pointer Signature for HIDL Call (thisptr, fod_cmd)
typedef void (*moto_sendFodEvent_t)(void*, int32_t);
static moto_sendFodEvent_t g_sendFodEvent = NULL;

void log_msg(const char* tag, const char* fmt, ...) {
    va_list args;
    time_t now = time(NULL);
    struct tm* t = localtime(&now);
    char time_str[32];
    strftime(time_str, sizeof(time_str), "%H:%M:%S", t);

    char buffer[1024];
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);

    if (g_debug_mode) {
        printf("[%s] [%s] %s\n", time_str, tag, buffer);
        fflush(stdout);
    }

    if (g_file_log_mode && g_log_file) {
        fprintf(g_log_file, "[%s] [%s] %s\n", time_str, tag, buffer);
        fflush(g_log_file);
    }
}

// =============================================================================
// Session Watchdog & Logcat Thread
// =============================================================================
void set_session_state(bool active) {
    pthread_mutex_lock(&g_session_lock);
    if (g_session_active != active) {
        g_session_active = active;
        log_msg("SESSION", "Biometric Authentication Session state changed: %s", active ? "ACTIVE" : "INACTIVE");
    }
    pthread_mutex_unlock(&g_session_lock);
}

bool is_session_active() {
    pthread_mutex_lock(&g_session_lock);
    bool active = g_session_active;
    pthread_mutex_unlock(&g_session_lock);
    return active;
}

void* logcat_session_listener(void* arg) {
    log_msg("SESSION", "Starting Logcat Session Listener Thread...");
    
    // Clear buffer first, then stream fingerprint log messages
    FILE* pipe = popen("logcat -c && logcat -v tag -s FingerprintService BiometricService AuthContainer 2>/dev/null", "r");
    if (!pipe) {
        log_msg("ERROR", "Failed to start logcat session listener pipe!");
        return NULL;
    }

    char line[512];
    while (fgets(line, sizeof(line), pipe) != NULL) {
        // Detect arming / starting session events
        if (strstr(line, "prepareForAuthentication") || 
            strstr(line, "onAcquired") || 
            strstr(line, "authenticate()") ||
            strstr(line, "enroll()")) {
            set_session_state(true);
        }
        // Detect disarming / stopping session events
        else if (strstr(line, "onAuthenticated") || 
                 strstr(line, "cancelAuthentication") || 
                 strstr(line, "onError") ||
                 strstr(line, "USER_CANCELED") ||
                 strstr(line, "HIDE_AUTH_DATA")) {
            set_session_state(false);
        }
    }

    pclose(pipe);
    return NULL;
}

// =============================================================================
// Display Local-HBM Driver Engine
// =============================================================================
void set_local_hbm(bool enable) {
    bool success = false;

    // Engine 1: Qualcomm DRM IOCTL
    if (g_drm_fd >= 0) {
        struct disp_param_req req;
        
        req.param_id = 0; req.value = enable ? CONFIG_LHBM_PARAM_P0 : 0;
        ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

        req.param_id = 1; req.value = enable ? CONFIG_LHBM_PARAM_P1 : 0;
        ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

        req.param_id = 2; req.value = enable ? CONFIG_LHBM_PARAM_P2 : 0;
        if (ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req) == 0) {
            log_msg("LHBM", "DRM IOCTL toggled -> %s", enable ? "ON" : "OFF");
            success = true;
        }
    }

    // Engine 2: Sysfs Fallbacks (MediaTek / Generic Panels)
    if (!success) {
        for (int i = 0; SYSFS_LHBM_FALLBACKS[i] != NULL; i++) {
            int fd = open(SYSFS_LHBM_FALLBACKS[i], O_WRONLY);
            if (fd >= 0) {
                const char* val = enable ? "1" : "0";
                write(fd, val, strlen(val));
                close(fd);
                log_msg("LHBM", "Sysfs [%s] toggled -> %s", SYSFS_LHBM_FALLBACKS[i], val);
                success = true;
                break;
            }
        }
    }

    // Engine 3: Touch Gesture Enable Sysfs Toggle
    int fod_fd = open(CONFIG_SYSFS_FOD_EN, O_WRONLY);
    if (fod_fd >= 0) {
        const char* val = enable ? "1" : "0";
        write(fod_fd, val, strlen(val));
        close(fod_fd);
        log_msg("GESTURE", "FOD Sysfs Node [%s] toggled -> %s", CONFIG_SYSFS_FOD_EN, val);
    }

    if (!success) {
        log_msg("ERROR", "Failed to set LHBM state (%s) across all display engines!", enable ? "ON" : "OFF");
    }
}

// =============================================================================
// Fingerprint HAL HIDL Resolver
// =============================================================================
void init_hal_library() {
    for (int i = 0; TARGET_LIBS[i] != NULL; i++) {
        g_hal_handle = dlopen(TARGET_LIBS[i], RTLD_NOW);
        if (g_hal_handle) {
            log_msg("HAL", "Loaded HAL shared library: %s", TARGET_LIBS[i]);
            
            // Iterate over known C++ mangled symbols for Motorola HIDL
            for (int j = 0; MOTO_HIDL_SYMBOLS[j] != NULL; j++) {
                g_sendFodEvent = (moto_sendFodEvent_t)dlsym(g_hal_handle, MOTO_HIDL_SYMBOLS[j]);
                if (g_sendFodEvent) {
                    log_msg("HAL", "Resolved sendFodEvent symbol: %s", MOTO_HIDL_SYMBOLS[j]);
                    return;
                }
            }
            log_msg("WARN", "Loaded %s but failed to resolve HIDL sendFodEvent symbol.", TARGET_LIBS[i]);
        }
    }
    log_msg("ERROR", "Could not resolve any compatible vendor fingerprint HAL symbol!");
}

void trigger_fod_event(int state) {
    if (g_sendFodEvent) {
        // Pass dummy HIDL 'this' pointer as first parameter for C++ ABI method calls
        g_sendFodEvent(g_hal_handle, state);
        log_msg("HAL", "Dispatched HIDL sendFodEvent(%d)", state);
    }
}

// =============================================================================
// Main Daemon Execution Core
// =============================================================================
int main(int argc, char** argv) {
    // Parse Arguments for Debug / Logging Modes
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--debug") == 0 || strcmp(argv[i], "-d") == 0) {
            g_debug_mode = true;
        }
        if (strcmp(argv[i], "--log") == 0 || strcmp(argv[i], "-l") == 0) {
            g_debug_mode = true;
            g_file_log_mode = true;
            g_log_file = fopen("/sdcard/fod_bridge_debug.log", "a");
        }
    }

    log_msg("INIT", "Starting Motorola UDFPS Native Bridge Daemon...");

    // Start Logcat Session Listener Thread
    pthread_t logcat_thread;
    pthread_create(&logcat_thread, NULL, logcat_session_listener, NULL);

    // Initialize DRM Display Device
    g_drm_fd = open(CONFIG_DRM_CARD_NODE, O_RDWR);
    if (g_drm_fd >= 0) {
        log_msg("INIT", "Opened DRM Card Device: %s", CONFIG_DRM_CARD_NODE);
    } else {
        log_msg("WARN", "DRM Card %s unreadable. Falling back to Sysfs display engines.", CONFIG_DRM_CARD_NODE);
    }

    // Resolve Fingerprint HAL HIDL Symbol
    init_hal_library();

    // Open Input Device Event
    int input_fd = open(CONFIG_INPUT_NODE, O_RDONLY);
    if (input_fd < 0) {
        log_msg("ERROR", "Failed to open kernel input node %s! Exiting.", CONFIG_INPUT_NODE);
        return 1;
    }
    log_msg("INIT", "Monitoring input node %s for Keycode %d", CONFIG_INPUT_NODE, CONFIG_TARGET_KEYCODE);

    struct input_event ev;
    while (read(input_fd, &ev, sizeof(ev)) > 0) {
        if (ev.type == EV_KEY && (ev.code == CONFIG_TARGET_KEYCODE || ev.code == 0x2c0)) {
            
            // SESSION GATE: Only process touch events if a biometric session is active!
            if (!is_session_active()) {
                log_msg("TOUCH", "Touch detected on FOD keycode, but ignored (No active biometric session).");
                continue;
            }

            if (ev.value == 1) { // Touch down event
                log_msg("TOUCH", "Finger Down Detected (Session Active)!");
                set_local_hbm(true);
                trigger_fod_event(0);
            } else if (ev.value == 0) { // Touch release event
                log_msg("TOUCH", "Finger Lift Detected!");
                set_local_hbm(false);
                trigger_fod_event(1);
            }
        }
    }

    if (g_log_file) fclose(g_log_file);
    close(input_fd);
    if (g_drm_fd >= 0) close(g_drm_fd);
    return 0;
}
