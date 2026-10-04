#include "../../include/fingerprint_backend.h"
#include <stdio.h>
#include <dlfcn.h>
#include <vector>

// Full Motorola C++/HIDL method representation for BpHwMotoFingerPrint::sendFodEvent
typedef void (*moto_hidl_sendFodEvent_t)(
    void* thisptr,
    int32_t event_type,
    const std::vector<int8_t>& extra_data,
    void* callback_fn
);

class MotorolaHidlBackend : public IFingerprintBackend {
private:
    void* m_lib_handle;
    moto_hidl_sendFodEvent_t m_sendFodEvent;

    static constexpr const char* MOTO_LIB = "/vendor/lib64/com.motorola.hardware.biometric.fingerprint@1.0.so";
    static constexpr const char* MOTO_SYMBOL = "_ZN3com8motorola8hardware9biometric11fingerprint4V1_019BpHwMotoFingerPrint12sendFodEventENS4_16IMotFodEventTypeERKN7android8hardware8hidl_vecIaEENSt3__18functionIFvNS4_18IMotFodEventResultESC_EEE";

public:
    MotorolaHidlBackend() : m_lib_handle(nullptr), m_sendFodEvent(nullptr) {}

    ~MotorolaHidlBackend() override {
        if (m_lib_handle) dlclose(m_lib_handle);
    }

    bool initialize() override {
        m_lib_handle = dlopen(MOTO_LIB, RTLD_NOW);
        if (!m_lib_handle) return false;

        m_sendFodEvent = (moto_hidl_sendFodEvent_t)dlsym(m_lib_handle, MOTO_SYMBOL);
        return (m_sendFodEvent != nullptr);
    }

    void sendFodEvent(int state) override {
        if (m_sendFodEvent && m_lib_handle) {
            std::vector<int8_t> dummy_vec;
            // Pass library instance as HIDL proxy thisptr
            m_sendFodEvent(m_lib_handle, state, dummy_vec, nullptr);
        }
    }

    const char* getName() const override {
        return "Motorola HIDL v1.0 (BpHwMotoFingerPrint)";
    }
};

IFingerprintBackend* createMotorolaHidlBackend() {
    auto backend = new MotorolaHidlBackend();
    if (backend->initialize()) {
        return backend;
    }
    delete backend;
    return nullptr;
}
