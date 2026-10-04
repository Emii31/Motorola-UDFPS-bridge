#include <stdio.h>
#include "../../include/fingerprint_backend.h"

class AospHidlBackend : public IFingerprintBackend {
public:
    bool initialize() override {
        // Explicitly fail initialization until native AOSP AIDL/HIDL driver is implemented
        return false;
    }
    void sendFodEvent(int state) override {}
    const char* getName() const override { return "AOSP Standard HIDL Driver (Unimplemented Stub)"; }
};

IFingerprintBackend* createAospHidlBackend() {
    return new AospHidlBackend();
}
