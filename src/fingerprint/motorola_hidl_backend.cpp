#include <stdio.h>
#include <dlfcn.h>
#include <stdint.h>
#include "../../include/fingerprint_backend.h"

static const char* MOTO_GET_SERVICE_SYM = "_ZN3com8motorola8hardware9biometric11fingerprint4V1_018IMotoFingerPrint10getServiceERKNSt3__112basic_stringIcNS5_11char_traitsIcEENS5_9allocatorIcEEEEb";
static const char* MOTO_SEND_FOD_SYM = "_ZN3com8motorola8hardware9biometric11fingerprint4V1_019BpHwMotoFingerPrint12sendFodEventENS4_16IMotFodEventTypeERKN7android8hardware8hidl_vecIaEENSt3__18functionIFvNS4_18IMotFodEventResultESC_EEE";

typedef void* (*fn_get_service_t)(const void*, bool);
typedef void (*fn_send_fod_event_t)(void*, int32_t, const void*, const void*);

class MotorolaHidlBackend : public IFingerprintBackend {
private:
    const char* m_lib_path;
    void* m_handle;
    void* m_hidl_service;
    fn_send_fod_event_t m_send_fod_fn;

public:
    MotorolaHidlBackend(const char* lib_path)
        : m_lib_path(lib_path), m_handle(nullptr), m_hidl_service(nullptr), m_send_fod_fn(nullptr) {}

    ~MotorolaHidlBackend() override {
        if (m_handle) dlclose(m_handle);
    }

    bool initialize() override {
        m_handle = dlopen(m_lib_path, RTLD_NOW);
        if (!m_handle) return false;

        fn_get_service_t get_svc = (fn_get_service_t)dlsym(m_handle, MOTO_GET_SERVICE_SYM);
        m_send_fod_fn = (fn_send_fod_event_t)dlsym(m_handle, MOTO_SEND_FOD_SYM);

        if (!get_svc || !m_send_fod_fn) return false;

        struct {
            const char* data;
            size_t length;
            char capacity_or_inline[16];
        } std_str_default = { "default", 7, {0} };

        m_hidl_service = get_svc(&std_str_default, false);
        return (m_hidl_service != nullptr);
    }

    void sendFodEvent(int state) override {
        if (m_send_fod_fn && m_hidl_service) {
            uint8_t dummy_vec[24] = {0};
            uint8_t dummy_cb[32] = {0};
            m_send_fod_fn(m_hidl_service, state, dummy_vec, dummy_cb);
        }
    }

    const char* getName() const override { return "Motorola HIDL v1.0 Driver"; }
};

IFingerprintBackend* createMotorolaHidlBackend(const char* lib_path) {
    return new MotorolaHidlBackend(lib_path);
}
