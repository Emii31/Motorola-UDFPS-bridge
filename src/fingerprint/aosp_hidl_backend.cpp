#include <stdio.h>
#include "../../include/fingerprint_backend.h"

class AospHidlBackend : public IFingerprintBackend {
public:
    bool initialize() override { return true; }
    void sendFodEvent(int state) override {}
    const char* getName() const override { return "AOSP Standard HIDL Driver (Stub)"; }
};

IFingerprintBackend* createAospHidlBackend() {
    return new AospHidlBackend();
}
