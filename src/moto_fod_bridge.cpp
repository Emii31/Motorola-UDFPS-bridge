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

// =============================================================================
// DRM / IOCTL Definitions
// =============================================================================
#define DRM_IOCTL_MDSS_DISP_PARAM 0xc008649f

struct disp_param_req {
    uint32_t param_id;
    int32_t value;
};

// =============================================================================
// Configuration Targets & Fallbacks
// =============================================================================
static const char* INPUT_EVENT_NODE = "/dev/input/event10";
static int TARGET_KEYCODE = 704;

static const char* SYSFS_FOD_EN = "/sys/devices/platform/goodix_ts.0/gesture/fod_en";
static const char* DRM_CARD_NODE = "/dev/dri/card0";

// Fallback LHBM Sysfs Paths (QCOM / MediaTek / Generic Panel)
static const char* SYSFS_LHBM_FALLBACKS[] = {
    "/sys/class/drm/card0-DSI-1/dimlayer_hbm",
    "/sys/devices/platform/soc/soc:qcom,dsi-display-primary/hbm",
    "/sys/class/backlight/panel0-backlight/hbm_mode",
    "/sys/class/graphics/fb0/hbm",
    NULL
};

// Target HAL Shared Libraries
static const char* TARGET_LIBS[] = {
    "/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so",
    "/vendor/lib64/hw/android.hardware.biometrics.fingerprint@2.1-service-jv.so",
    "/vendor/lib64/hw/android.hardware.biometrics.fingerprint@2.1-service.so",
    "/vendor/lib64/hw/fingerprint.default.so",
    NULL
};

// Local-HBM Parameters (Calibrated by port_fod.sh)
static int PARAM_P0 = 2;
static int PARAM_P1 = 2;
static int PARAM_P2 = 0;

// =============================================================================
// Global State & Logging Controls
// =============================================================================
static bool g_debug_mode = false;
static bool g_file_log_mode = false;
static FILE* g_log_file = NULL;

static int g_drm_fd = -1;
static void* g_hal_handle = NULL;
typedef void (*sendFodEvent_t)(int);
static sendFodEvent_t g_sendFodEvent = NULL;

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
// Universal Local-HBM Controller (DRM IOCTL + Multi-Sysfs Fallback)
// =============================================================================
void set_local_hbm(bool enable) {
    bool success = false;

    // Engine 1: DRM IOCTL
    if (g_drm_fd >= 0) {
        struct disp_param_req req;
        
        req.param_id = 0; req.value = enable ? PARAM_P0 : 0;
        ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

        req.param_id = 1; req.value = enable ? PARAM_P1 : 0;
        ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

        req.param_id = 2; req.value = enable ? PARAM_P2 : 0;
        if (ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req) == 0) {
            log_msg("LHBM", "DRM IOCTL toggled -> %s", enable ? "ON" : "OFF");
            success = true;
        }
    }

    // Engine 2: Sysfs Fallbacks (If DRM IOCTL unavailable or failed)
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

    if (!success) {
        log_msg("ERROR", "Failed to set LHBM state (%s) across all display engines!", enable ? "ON" : "OFF");
    }
}

// =============================================================================
// HAL Resolver
// =============================================================================
void init_hal_library() {
    for (int i = 0; TARGET_LIBS[i] != NULL; i++) {
        g_hal_handle = dlopen(TARGET_LIBS[i], RTLD_NOW);
        if (g_hal_handle) {
            log_msg("HAL", "Successfully loaded HAL library: %s", TARGET_LIBS[i]);
            g_sendFodEvent = (sendFodEvent_t)dlsym(g_hal_handle, "sendFodEvent");
            if (g_sendFodEvent) {
                log_msg("HAL", "Symbol 'sendFodEvent' resolved!");
            } else {
                log_msg("WARN", "Loaded %s but 'sendFodEvent' symbol not found.", TARGET_LIBS[i]);
            }
            return;
        }
    }
    log_msg("ERROR", "Could not load any compatible vendor fingerprint shared library!");
}

// =============================================================================
// Main Execution Engine
// =============================================================================
int main(int argc, char** argv) {
    // Parse Arguments
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

    // Open DRM Card
    g_drm_fd = open(DRM_CARD_NODE, O_RDWR);
    if (g_drm_fd >= 0) {
        log_msg("INIT", "Opened DRM Card: %s", DRM_CARD_NODE);
    } else {
        log_msg("WARN", "Failed to open DRM card %s. Will rely on Sysfs fallbacks.", DRM_CARD_NODE);
    }

    // Resolve Vendor HAL
    init_hal_library();

    // Open Input Event Node
    int input_fd = open(INPUT_EVENT_NODE, O_RDONLY);
    if (input_fd < 0) {
        log_msg("ERROR", "Cannot open input node %s! Exiting.", INPUT_EVENT_NODE);
        return 1;
    }
    log_msg("INIT", "Listening for touch events on %s (Keycode: %d)", INPUT_EVENT_NODE, TARGET_KEYCODE);

    struct input_event ev;
    while (read(input_fd, &ev, sizeof(ev)) > 0) {
        if (ev.type == EV_KEY && (ev.code == TARGET_KEYCODE || ev.code == 0x2c0 || ev.code == 0x140)) {
            if (ev.value == 1) { // Touch down
                log_msg("TOUCH", "Finger Down Detected!");
                set_local_hbm(true);
                if (g_sendFodEvent) g_sendFodEvent(0);
            } else if (ev.value == 0) { // Touch release
                log_msg("TOUCH", "Finger Lift Detected!");
                set_local_hbm(false);
                if (g_sendFodEvent) g_sendFodEvent(1);
            }
        }
    }

    if (g_log_file) fclose(g_log_file);
    close(input_fd);
    if (g_drm_fd >= 0) close(g_drm_fd);
    return 0;
}
