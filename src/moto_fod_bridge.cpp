#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <linux/input.h>
#include <time.h>
#include <stdarg.h>

#include "../include/device_config.h"
#include "../include/lhbm_backend.h"
#include "../include/fingerprint_backend.h"

static bool g_debug_mode = false;
static bool g_file_log_mode = false;
static FILE* g_log_file = nullptr;

static bool g_session_active = false;
static bool g_lhbm_is_on = false;
static time_t g_last_touch_time = 0;
static pthread_mutex_t g_state_lock = PTHREAD_MUTEX_INITIALIZER;

static ILhbmBackend* g_display_engine = nullptr;
static IFingerprintBackend* g_fingerprint_engine = nullptr;

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

void set_session_state(bool active) {
    pthread_mutex_lock(&g_state_lock);
    if (g_session_active != active) {
        g_session_active = active;
        log_msg("SESSION", "Biometric Session: %s", active ? "ACTIVE" : "INACTIVE");
        if (!active && g_lhbm_is_on) {
            log_msg("WATCHDOG", "Session ended with active LHBM. Force disabling.");
            if (g_display_engine) g_display_engine->setLhbmState(false);
            if (g_fingerprint_engine) g_fingerprint_engine->sendFodEvent(1);
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
                log_msg("WATCHDOG", "Touch timeout (%d sec). Disarming LHBM.", CONFIG_WATCHDOG_TIMEOUT_SEC);
                if (g_display_engine) g_display_engine->setLhbmState(false);
                if (g_fingerprint_engine) g_fingerprint_engine->sendFodEvent(1);
                g_lhbm_is_on = false;
            }
        }
        pthread_mutex_unlock(&g_state_lock);
    }
    return nullptr;
}

void* logcat_session_listener(void* arg) {
    log_msg("SESSION", "Listening to Android Logcat biometric events...");
    FILE* pipe = popen("logcat -v time -b all -s FingerprintService BiometricService AuthContainer 2>/dev/null", "r");
    if (!pipe) return nullptr;

    char line[512];
    while (fgets(line, sizeof(line), pipe) != nullptr) {
        if (strstr(line, "prepareForAuthentication") || strstr(line, "onAcquired") || 
            strstr(line, "authenticate()") || strstr(line, "enroll()")) {
            set_session_state(true);
        } else if (strstr(line, "onAuthenticated") || strstr(line, "cancelAuthentication") || 
                   strstr(line, "onError") || strstr(line, "USER_CANCELED") || strstr(line, "HIDE_AUTH_DATA")) {
            set_session_state(false);
        }
    }
    pclose(pipe);
    return nullptr;
}

int main(int argc, char** argv) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--debug") == 0 || strcmp(argv[i], "-d") == 0) g_debug_mode = true;
        if (strcmp(argv[i], "--log") == 0 || strcmp(argv[i], "-l") == 0) {
            g_debug_mode = true; g_file_log_mode = true;
            g_log_file = fopen("/sdcard/fod_bridge_debug.log", "a");
        }
    }

    log_msg("INIT", "Starting Universal Motorola UDFPS Bridge Daemon...");

    // Instantiate LHBM Backend
    g_display_engine = createDrmLhbmBackend(CONFIG_DRM_CARD_NODE, CONFIG_LHBM_PARAM_P0, CONFIG_LHBM_PARAM_P1, CONFIG_LHBM_PARAM_P2);
    if (!g_display_engine->initialize()) {
        log_msg("WARN", "DRM Driver failed to initialize. Falling back to Sysfs.");
        delete g_display_engine;
        g_display_engine = createSysfsLhbmBackend(CONFIG_SYSFS_FOD_EN);
        g_display_engine->initialize();
    }
    log_msg("INIT", "Loaded Display Backend: %s", g_display_engine->getName());

    // Instantiate Fingerprint Backend
    if (strcmp(CONFIG_FINGERPRINT_BACKEND, "motorola_hidl") == 0) {
        g_fingerprint_engine = createMotorolaHidlBackend(CONFIG_FINGERPRINT_LIB_PATH);
    } else {
        g_fingerprint_engine = createAospHidlBackend();
    }

    if (g_fingerprint_engine && g_fingerprint_engine->initialize()) {
        log_msg("INIT", "Loaded Fingerprint Backend: %s", g_fingerprint_engine->getName());
    } else {
        log_msg("WARN", "Fingerprint Backend failed. Running LHBM standalone mode.");
    }

    pthread_t logcat_t, watchdog_t;
    pthread_create(&logcat_t, nullptr, logcat_session_listener, nullptr);
    pthread_create(&watchdog_t, nullptr, watchdog_thread, nullptr);

    int input_fd = open(CONFIG_INPUT_NODE, O_RDONLY | O_NONBLOCK);
    if (input_fd < 0) {
        log_msg("ERROR", "Failed to open input device %s!", CONFIG_INPUT_NODE);
        return 1;
    }

    struct input_event ev;
    while (true) {
        ssize_t bytes = read(input_fd, &ev, sizeof(ev));
        if (bytes < (ssize_t)sizeof(ev)) {
            usleep(10000);
            continue;
        }

        if (ev.type == EV_KEY && ev.code == CONFIG_TARGET_KEYCODE) {
            if (!is_session_active()) continue;

            pthread_mutex_lock(&g_state_lock);
            g_last_touch_time = time(nullptr);

            if (ev.value == 1) {
                log_msg("TOUCH", "Finger Down");
                if (g_display_engine) g_display_engine->setLhbmState(true);
                if (g_fingerprint_engine) g_fingerprint_engine->sendFodEvent(0);
                g_lhbm_is_on = true;
            } else if (ev.value == 0) {
                log_msg("TOUCH", "Finger Up");
                if (g_display_engine) g_display_engine->setLhbmState(false);
                if (g_fingerprint_engine) g_fingerprint_engine->sendFodEvent(1);
                g_lhbm_is_on = false;
            }
            pthread_mutex_unlock(&g_state_lock);
        }
    }

    close(input_fd);
    delete g_display_engine;
    delete g_fingerprint_engine;
    return 0;
}
