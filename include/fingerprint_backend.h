#ifndef FINGERPRINT_BACKEND_H
#define FINGERPRINT_BACKEND_H

#include <stdint.h>

class IFingerprintBackend {
public:
    virtual ~IFingerprintBackend() {}
    virtual bool initialize() = 0;
    virtual void sendFodEvent(int state) = 0;
    virtual const char* getName() const = 0;
};

// Factory functions
IFingerprintBackend* createMotorolaHidlBackend();
IFingerprintBackend* createAospHidlBackend();

#endif // FINGERPRINT_BACKEND_H
