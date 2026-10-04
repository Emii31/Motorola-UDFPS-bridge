#include <stdio.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "../../include/fingerprint_backend.h"

// Standard Android HIDL Vector Memory Layout
struct HidlVecInt8 {
    int8_t* mBuffer;
    uint32_t mSize;
    bool mOwnsBuffer;
    uint8_t mPadding[3];
};

// Callback closure representation for Motorola HIDL sendFodEvent response
typedef void (*FodCallbackFn)(void* userData, int32_t result, const HidlVecInt8* vec);

// Mangled C++ symbols for Motorola Fingerprint HIDL v1.0 interface
static const char* MOTO_GET_SERVICE_SYM = 
    "_ZN3com8motorola8hardware9biometric11fingerprint4V1_016IMotoFingerPrint10getServiceERKNSt3__112basic_stringIcNS6_11char_traitsIcEENS6_9allocatorIcEEEEb";

static const char* MOTO_SEND_FOD_SYM = 
    "_ZN3com8motorola8hardware9biometric11fingerprint4V1_019BpHwMotoFingerPrint12sendFodEventENS4_16IMotFodEventTypeERKN7android8hardware8hidl_vecIaEENSt3__18functionIFvNS4_18IMotFodEventResultESC_EEE";

typedef void* (*fn_getService)(const void* serviceName, bool getStub);
typedef void (*fn_sendFodEvent)(void* instance, int32_t eventType, const HidlVecInt8* vec, const void* callbackFunc);

class MotorolaHidlBackend : public IFingerprintBackend {
private:
    const char* m_lib_path;
    void* m_handle;
    void* m_hidl_service;
    fn_send_fod_event_t m_send_fod_fn; // function pointer for sendFodEvent

public:
    MotorolaHidlBackend(const char* lib_path)
        : m_lib_path(lib_path), m_handle(nullptr), m_hidl_service(nullptr), m_send_fod_fn(nullptr) {}

    ~MotorolaHidlBackend() override {
        if (m_handle) {
            dlclose(m_handle);
            m_handle = nullptr;
        }
    }

    bool initialize() override {
        m_handle = dlopen(m_lib_path, RTLD_NOW);
        if (!m_handle) {
            return false;
        }

        fn_getService getService = (fn_getService)dlsym(m_handle, MOTO_GET_SERVICE_SYM);
        m_send_fod_fn = (fn_send_fod_event_t)dlsym(m_handle, MOTO_SEND_FOD_SYM);

        if (!getService || !m_send_fod_fn) {
            return false;
        }

        // Properly formatted std::string ("default") layout for NDK/HIDL service lookup
        struct {
            const char* data;
            size_t length;
            char capacity_or_inline[16];
        } std_str_default = { "default", 7, {0} };

        m_hidl_service = getService(&std_str_default, false);
        return (m_hidl_service != nullptr);
    }

    void sendFodEvent(int state) override {
        if (!m_send_fod_fn || !m_hidl_service) return;

        // Construct empty hidl_vec<int8_t>
        HidlVecInt8 emptyVec;
        emptyVec.mBuffer = nullptr;
        emptyVec.mSize = 0;
        emptyVec.mOwnsBuffer = false;

        // Dummy callback structure matching LLVM libUnwind / std::function layout (4 pointers)
        void* dummyCallback[4] = { nullptr, nullptr, nullptr, nullptr };

        // Execute HIDL invocation with verified ABI layout
        ((fn_sendFodEvent)m_send_fod_fn)(m_hidl_service, state, &emptyVec, dummyCallback);
    }

    const char* getName() const override { return "Motorola HIDL v1.0 Driver (Boston ABI)"; }
};

IFingerprintBackend* createMotorolaHidlBackend(const char* lib_path) {
    return new MotorolaHidlBackend(lib_path);
}
