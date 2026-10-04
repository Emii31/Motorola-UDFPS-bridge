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

// Direct inclusion of generated hardware configuration
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
// Known Motorola HIDL Symbol Declarations
// =============================================================================
static const char* MOTO_HIDL_LIB = CONFIG_FINGERPRINT_LIB_PATH;
static const char* MOTO_GET_SERVICE_SYM = "_ZN3com8motorola8hardware9biometric11fingerprint4V1_018IMotoFingerPrint10getServiceERKNSt3__112basic_stringIcNS5_11char_traitsIcEENS5_9allocatorIcEEEEb";
static const char* MOTO_SEND_FOD_SYM = "_ZN3com8motorola8hardware9biometric11fingerprint4V1_019BpHwMotoFingerPrint12sendFodEventENS4_16IMotFodEventTypeERKN7android8hardware8hidl_vecIaEENSt3__18functionIFvNS4_18IMotFodEventResultESC_EEE";

// C++ HIDL method signatures matching Boston ABI
typedef void* (*fn_get_service_t)(const void*, bool);
typedef void (*fn_send_fod_event_t)(void*, int32_t, const void*, const void*);

// =============================================================================
// Global Engine State
// =============================================================================
static bool g_debug_mode = false;
static bool g_file_log_mode = false;
static FILE* g_log_file = nullptr;

static bool g_session_active = false;
static bool g_lhbm_is_on = false;
static time_t g_last_touch_time = 0;

static pthread_mutex_t g_state_lock = PTHREAD_MUTEX_INITIALIZER;

static int g_drm_fd = -1;
static void* g_hal_lib_handle = nullptr;
static void* g_hidl_service_ptr = nullptr;
static fn_send_fod_event_t g_send_fod_fn = nullptr;

void log_msg(const char* tag, const char* fmt, ...) {
    va_list args;
    time_t now = time(nullptr);
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
// Session State & Watchdog Supervisor
// =============================================================================
void set_session_state(bool active) {
    pthread_mutex_lock(&g_state_lock);
    if (g_session_active != active) {
        g_session_active = active;
        log_msg("SESSION", "Biometric Session State: %s", active ? "ACTIVE" : "INACTIVE");
        
        // Force Disarm LHBM when biometric session closes
        if (!active && g_lhbm_is_on) {
            log_msg("WATCHDOG", "Session terminated while LHBM was ACTIVE. Executing safety disarm.");
            
            // Disarm DRM
            if (g_drm_fd >= 0) {
                struct disp_param_req req;
                req.param_id = 0; req.value = 0; ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);
                req.param_id = 1; req.value = 0; ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);
                req.param_id = 2; req.value = 0; ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);
            }

            // Disarm Sysfs FOD node
            int ffd = open(CONFIG_SYSFS_FOD_EN, O_WRONLY);
            if (ffd >= 0) {
                write(ffd, "0", 1);
                close(ffd);
            }

            g_lhbm_is_on = false;
        }
    }
    pthread_mutex_unlock(&g_state_lock);
}

bool is_session_active() {
    pthread_mutex_lock(&g_state_lock);
    bool active = g_session_active;
    pthread_mutex_unlock(&g_state_lock);
    return active;
}

void* watchdog_thread(void* arg) {
    while (true) {
        sleep(1);
        pthread_mutex_lock(&g_state_lock);
        if (g_lhbm_is_on) {
            time_t now = time(nullptr);
            if (difftime(now, g_last_touch_time) >= CONFIG_WATCHDOG_TIMEOUT_SEC) {
                log_msg("WATCHDOG", "Touch release timeout reached (%d sec)! Safety disarming LHBM.", CONFIG_WATCHDOG_TIMEOUT_SEC);
                
                if (g_drm_fd >= 0) {
                    struct disp_param_req req;
                    req.param_id = 0; req.value = 0; ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);
                    req.param_id = 1; req.value = 0; ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);
                    req.param_id = 2; req.value = 0; ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);
                }

                int ffd = open(CONFIG_SYSFS_FOD_EN, O_WRONLY);
                if (ffd >= 0) {
                    write(ffd, "0", 1);
                    close(ffd);
                }

                g_lhbm_is_on = false;
            }
        }
        pthread_mutex_unlock(&g_state_lock);
    }
    return nullptr;
}

void* logcat_session_listener(void* arg) {
    log_msg("SESSION", "Starting Logcat Session Listener...");
    // Stream logcat using -v time -b all without buffer clearing (-c)
    FILE* pipe = popen("logcat -v time -b all -s FingerprintService BiometricService AuthContainer 2>/dev/null", "r");
    if (!pipe) {
        log_msg("ERROR", "Failed to open logcat pipe!");
        return nullptr;
    }

    char line[512];
    while (fgets(line, sizeof(line), pipe) != nullptr) {
        if (strstr(line, "prepareForAuthentication") || 
            strstr(line, "onAcquired") || 
            strstr(line, "authenticate()") ||
            strstr(line, "enroll()")) {
            set_session_state(true);
        } else if (strstr(line, "onAuthenticated") || 
                   strstr(line, "cancelAuthentication") || 
                   strstr(line, "onError") ||
                   strstr(line, "USER_CANCELED") ||
                   strstr(line, "HIDE_AUTH_DATA")) {
            set_session_state(false);
        }
    }

    pclose(pipe);
    return nullptr;
}

// =============================================================================
// Display Engine (Driven by device_config.h macros)
// =============================================================================
void set_local_hbm(bool enable) {
    bool drm_success = false;

    if (g_drm_fd >= 0) {
        struct disp_param_req req;
        
        req.param_id = 0; req.value = enable ? CONFIG_LHBM_PARAM_P0 : 0;
        ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

        req.param_id = 1; req.value = enable ? CONFIG_LHBM_PARAM_P1 : 0;
        ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

        req.param_id = 2; req.value = enable ? CONFIG_LHBM_PARAM_P2 : 0;
        if (ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req) == 0) {
            log_msg("LHBM", "Qualcomm DRM IOCTL toggled -> %s", enable ? "ON" : "OFF");
            drm_success = true;
        }
    }

    // Toggle FOD Sysfs Node
    int ffd = open(CONFIG_SYSFS_FOD_EN, O_WRONLY);
    if (ffd >= 0) {
        const char* val = enable ? "1" : "0";
        write(ffd, val, strlen(val));
        close(ffd);
        log_msg("GESTURE", "Sysfs Node [%s] toggled -> %s", CONFIG_SYSFS_FOD_EN, val);
    }

    if (!drm_success) {
        log_msg("WARN", "DRM IOCTL execution unconfirmed. Sysfs state toggled.");
    }
}

// =============================================================================
// Motorola HIDL Engine Initialization
// =============================================================================
bool init_motorola_hidl() {
    g_hal_lib_handle = dlopen(MOTO_HIDL_LIB, RTLD_NOW);
    if (!g_hal_lib_handle) {
        log_msg("ERROR", "Failed to open HAL library: %s", MOTO_HIDL_LIB);
        return false;
    }

    fn_get_service_t get_svc = (fn_get_service_t)dlsym(g_hal_lib_handle, MOTO_GET_SERVICE_SYM);
    g_send_fod_fn = (fn_send_fod_event_t)dlsym(g_hal_lib_handle, MOTO_SEND_FOD_SYM);

    if (!get_svc || !g_send_fod_fn) {
        log_msg("ERROR", "Failed to resolve required Motorola HIDL C++ mangled symbols!");
        return false;
    }

    // Construct "default" std::string parameter for IMotoFingerPrint::getService
    struct {
        const char* data;
        size_t length;
        char capacity_or_inline[16];
    } std_str_default = { "default", 7, {0} };

    g_hidl_service_ptr = get_svc(&std_str_default, false);
    if (!g_hidl_service_ptr) {
        log_msg("ERROR", "IMotoFingerPrint::getService(\"default\") returned nullptr!");
        return false;
    }

    log_msg("HAL", "Successfully initialized Motorola HIDL service reference!");
    return true;
}

void trigger_fod_event(int state) {
    if (g_send_fod_fn && g_hidl_service_ptr) {
        // Construct dummy hidl_vec and callback pointers for AArch64 ABI call
        uint8_t dummy_vec[24] = {0};
        uint8_t dummy_cb[32] = {0};
        g_send_fod_fn(g_hidl_service_ptr, state, dummy_vec, dummy_cb);
        log_msg("HAL", "Dispatched BpHwMotoFingerPrint::sendFodEvent(%d)", state);
    }
}

// =============================================================================
// Main Daemon Execution Core
// =============================================================================
int main(int argc, char** argv) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--debug") == 0 || strcmp(argv[i], "-d") == 0) g_debug_mode = true;
        if (strcmp(argv[i], "--log") == 0 || strcmp(argv[i], "-l") == 0) {
            g_debug_mode = true;
            g_file_log_mode = true;
            g_log_file = fopen("/sdcard/fod_bridge_debug.log", "a");
        }
    }

    log_msg("INIT", "Starting Motorola Universal Local-HBM Bridge Daemon...");
    log_msg("INIT", "Configured Input Node: %s (Keycode: %d)", CONFIG_INPUT_NODE, CONFIG_TARGET_KEYCODE);
    log_msg("INIT", "Configured DRM Node: %s (P0=%d, P1=%d, P2=%d)", CONFIG_DRM_CARD_NODE, CONFIG_LHBM_PARAM_P0, CONFIG_LHBM_PARAM_P1, CONFIG_LHBM_PARAM_P2);

    // Initialize DRM Display Engine
    g_drm_fd = open(CONFIG_DRM_CARD_NODE, O_RDWR);
    if (g_drm_fd < 0) {
        log_msg("WARN", "Failed to open DRM Card %s. Operating in Sysfs-only mode.", CONFIG_DRM_CARD_NODE);
    }

    // Initialize Vendor HIDL Stack
    if (!init_motorola_hidl()) {
        log_msg("WARN", "Motorola HIDL Backend failed to initialize. Running in standalone LHBM mode.");
    }

    // Spawn Concurrent Monitor Threads
    pthread_t logcat_t, watchdog_t;
    pthread_create(&logcat_t, nullptr, logcat_session_listener, nullptr);
    pthread_create(&watchdog_t, nullptr, watchdog_thread, nullptr);

    // Open Configured Input Device Event
    int input_fd = open(CONFIG_INPUT_NODE, O_RDONLY | O_NONBLOCK);
    if (input_fd < 0) {
        log_msg("ERROR", "Failed to open input device node %s! Exiting.", CONFIG_INPUT_NODE);
        return 1;
    }

    struct input_event ev;
    while (true) {
        ssize_t bytes = read(input_fd, &ev, sizeof(ev));
        if (bytes < (ssize_t)sizeof(ev)) {
            usleep(10000); // 10ms polling delay
            continue;
        }

        if (ev.type == EV_KEY && ev.code == CONFIG_TARGET_KEYCODE) {
            // SESSION GATE: Restrict processing to active biometric sessions
            if (!is_session_active()) {
                log_msg("TOUCH", "Touch event on keycode %d ignored (No active biometric session).", ev.code);
                continue;
            }

            pthread_mutex_lock(&g_state_lock);
            g_last_touch_time = time(nullptr);

            if (ev.value == 1) { // Touch down
                log_msg("TOUCH", "Finger Down Detected!");
                set_local_hbm(true);
                trigger_fod_event(0);
                g_lhbm_is_on = true;
            } else if (ev.value == 0) { // Touch lift
                log_msg("TOUCH", "Finger Lift Detected!");
                set_local_hbm(false);
                trigger_fod_event(1);
                g_lhbm_is_on = false;
            }
            pthread_mutex_unlock(&g_state_lock);
        }
    }

    if (g_log_file) fclose(g_log_file);
    close(input_fd);
    if (g_drm_fd >= 0) close(g_drm_fd);
    return 0;
}
