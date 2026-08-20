#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <stdatomic.h>
#include <linux/input.h>
#include <dlfcn.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <string>
#include <functional>

#define DRM_IOCTL_MDSS_DISP_PARAM 0xc008649f

struct disp_param_req {
    uint32_t param_id;
    int32_t  value;
};

static int g_drm_fd = -1;
static atomic_bool g_session_active = ATOMIC_VAR_INIT(false);
static atomic_bool g_running = ATOMIC_VAR_INIT(true);
static const char* FOD_EN_NODE = "/sys/devices/platform/goodix_ts.0/gesture/fod_en";

static void set_panel_mode(int mode) {
    if (g_drm_fd < 0) return;
    struct disp_param_req req;
    if (mode == 4) {
        // Mode 4: Native Local-HBM (Circle Spot only) -> param0=2, param1=2, param2=0
        req.param_id = 0; req.value = 2; ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);
        req.param_id = 1; req.value = 2; ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);
        req.param_id = 2; req.value = 0; ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);
    } else {
        // Mode 0: NORMAL (param0=0, param1=0, param2=0)
        req.param_id = 0; req.value = 0; ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);
        req.param_id = 1; req.value = 0; ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);
        req.param_id = 2; req.value = 0; ioctl(g_drm_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);
    }
}

static void write_int_to_file(const char* path, int val) {
    FILE* f = fopen(path, "w");
    if (f) {
        fprintf(f, "%d\n", val);
        fclose(f);
    }
}

static void handle_exit(int sig) {
    g_running = false;
    set_panel_mode(0);
    write_int_to_file(FOD_EN_NODE, 0);
    if (g_drm_fd >= 0) close(g_drm_fd);
    printf("\n[*] Safety exit (signal %d). Restored display to normal mode.\n", sig);
    _exit(0);
}

struct alignas(8) VendorString {
    unsigned char buf[24];
    VendorString(const char* str) {
        memset(buf, 0, sizeof(buf));
        size_t len = strlen(str);
        buf[0] = (unsigned char)(len << 1);
        memcpy(&buf[1], str, len);
    }
};

struct alignas(8) HidlVecInt8 {
    int8_t* mBuffer;
    uint32_t mSize;
    bool mOwnsBuffer;
    uint8_t mPad[3];
    HidlVecInt8(int8_t* ptr, uint32_t sz)
        : mBuffer(ptr), mSize(sz), mOwnsBuffer(false) {
        memset(mPad, 0, sizeof(mPad));
    }
};

static void* call_moto_get_service(void* fn_ptr, const VendorString* name, bool get_stub) {
    void* sp_storage = nullptr;
    register const VendorString* r_x0 asm("x0") = name;
    register uint64_t r_x1 asm("x1") = get_stub ? 1 : 0;
    register void* r_x8 asm("x8") = &sp_storage;

    asm volatile(
        "blr %3"
        : "+r"(r_x0), "+r"(r_x1), "+r"(r_x8)
        : "r"(fn_ptr)
        : "x2", "x3", "x4", "x5", "x6", "x7", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x30", "memory"
    );
    return sp_storage;
}

static void call_bphw_send_fod_event(void* fn_ptr, void* instance, int32_t event_type, const HidlVecInt8* vec, void* std_func_ptr) {
    uint8_t ret_buffer[128];
    memset(ret_buffer, 0, sizeof(ret_buffer));

    register void* r_x0 asm("x0") = instance;
    register int64_t r_x1 asm("x1") = event_type;
    register const HidlVecInt8* r_x2 asm("x2") = vec;
    register void* r_x3 asm("x3") = std_func_ptr;
    register void* r_x8 asm("x8") = ret_buffer;

    asm volatile(
        "blr %5"
        : "+r"(r_x0), "+r"(r_x1), "+r"(r_x2), "+r"(r_x3), "+r"(r_x8)
        : "r"(fn_ptr)
        : "x4", "x5", "x6", "x7", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x30", "memory"
    );
}

static uint64_t get_time_ms() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return (uint64_t)tv.tv_sec * 1000 + (uint64_t)tv.tv_usec / 1000;
}

static void* session_listener_thread(void* arg) {
    FILE* pipe = popen("logcat -v time -s BiometricService:D UdfpsController:D", "r");
    if (!pipe) return nullptr;

    char line[512];
    while (atomic_load(&g_running) && fgets(line, sizeof(line), pipe)) {
        if (strstr(line, "showUdfpsOverlay") || strstr(line, "authenticate") || strstr(line, "enroll")) {
            if (!atomic_load(&g_session_active)) {
                atomic_store(&g_session_active, true);
                write_int_to_file(FOD_EN_NODE, 1);
                printf("\n[>>>] BIOMETRIC PROMPT ACTIVE -> Sensor Armed\n");
            }
        } else if (strstr(line, "hideUdfpsOverlay") || strstr(line, "onAuthSessionEnded") || strstr(line, "resetLockout")) {
            if (atomic_load(&g_session_active)) {
                atomic_store(&g_session_active, false);
                set_panel_mode(0);
                write_int_to_file(FOD_EN_NODE, 0);
                printf("\n[<<<] BIOMETRIC PROMPT CLOSED -> Sensor Disarmed\n");
            }
        }
    }
    pclose(pipe);
    return nullptr;
}

int main() {
    signal(SIGINT, handle_exit);
    signal(SIGTERM, handle_exit);

    g_drm_fd = open("/dev/dri/card0", O_RDWR);
    if (g_drm_fd < 0) {
        perror("[-] Failed to open /dev/dri/card0");
        return 1;
    }
    set_panel_mode(0);
    write_int_to_file(FOD_EN_NODE, 0);

    printf("[*] Starting Native LHBM FOD Bridge (Mode 4)...\n");

    void* hidl_lib = dlopen("/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so", RTLD_NOW);
    if (!hidl_lib) {
        printf("[-] dlopen failed: %s\n", dlerror());
        return 1;
    }

    void* get_svc_sym = dlsym(
        hidl_lib,
        "_ZN3com8motorola8hardware9biometric11fingerprint4V1_016IMotoFingerPrint10getServiceERKNSt3__112basic_stringIcNS6_11char_traitsIcEENS6_9allocatorIcEEEEb"
    );

    void* send_fod_sym = dlsym(
        hidl_lib,
        "_ZN3com8motorola8hardware9biometric11fingerprint4V1_019BpHwMotoFingerPrint12sendFodEventENS4_16IMotFodEventTypeERKN7android8hardware8hidl_vecIaEENSt3__18functionIFvNS4_18IMotFodEventResultESC_EEE"
    );

    VendorString svc_name("default");
    void* motoFpInstance = call_moto_get_service(get_svc_sym, &svc_name, false);
    if (!motoFpInstance) {
        printf("[-] Failed to acquire IMotoFingerPrint interface.\n");
        return 1;
    }
    printf("[+] Connected to IMotoFingerPrint HIDL: %p\n", motoFpInstance);

    int fd = open("/dev/input/event10", O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
        perror("[-] Failed to open /dev/input/event10");
        return 1;
    }

    pthread_t listener_tid;
    pthread_create(&listener_tid, nullptr, session_listener_thread, nullptr);

    printf("[+] Ready for touch events.\n");

    int8_t fod_mode = 0x03;
    HidlVecInt8 vec(&fod_mode, 1);
    std::function<void(int32_t, const HidlVecInt8&)> cb = [](int32_t res, const HidlVecInt8& v) {};

    struct input_event ev;
    bool is_touch_active = false;
    uint64_t last_touch_ms = 0;
    int touch_count = 0;

    while (g_running) {
        uint64_t now = get_time_ms();

        while (read(fd, &ev, sizeof(struct input_event)) > 0) {
            if (!atomic_load(&g_session_active)) {
                continue;
            }

            if (ev.type == EV_KEY && (ev.code == 704 || ev.code == 0x2c0)) {
                if (ev.value == 1) { // Touch DOWN
                    last_touch_ms = now;
                    if (!is_touch_active) {
                        is_touch_active = true;
                        touch_count++;

                        // 1. Activate Hardware Local-HBM Circle
                        set_panel_mode(4);

                        // 2. Trigger TrustZone frame capture
                        printf("[+] [%d] Local-HBM ON -> sendFodEvent(0)\n", touch_count);
                        call_bphw_send_fod_event(send_fod_sym, motoFpInstance, 0, &vec, &cb);
                    }
                }
            }
        }

        // Keep spot on for optical integration (~160ms), then reset
        if (is_touch_active && (now - last_touch_ms > 160)) {
            is_touch_active = false;

            // Reset panel to normal
            set_panel_mode(0);

            printf("[-] [%d] Normal Restore -> sendFodEvent(1)\n", touch_count);
            call_bphw_send_fod_event(send_fod_sym, motoFpInstance, 1, &vec, &cb);
        }

        usleep(2000);
    }

    close(fd);
    if (g_drm_fd >= 0) close(g_drm_fd);
    return 0;
}
