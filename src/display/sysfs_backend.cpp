#include "../../include/lhbm_backend.h"
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

static const char* SYSFS_CANDIDATES[] = {
    "/sys/class/drm/card0-DSI-1/dimlayer_hbm",
    "/sys/devices/platform/soc/soc:qcom,dsi-display-primary/hbm",
    "/sys/class/backlight/panel0-backlight/hbm_mode",
    "/sys/class/graphics/fb0/hbm",
    nullptr
};

class SysfsLhbmBackend : public ILhbmBackend {
private:
    const char* m_active_node;
    const char* m_fod_sysfs;

public:
    SysfsLhbmBackend(const char* fod_sysfs) : m_active_node(nullptr), m_fod_sysfs(fod_sysfs) {}

    bool initialize() override {
        for (int i = 0; SYSFS_CANDIDATES[i] != nullptr; i++) {
            int fd = open(SYSFS_CANDIDATES[i], O_WRONLY);
            if (fd >= 0) {
                close(fd);
                m_active_node = SYSFS_CANDIDATES[i];
                return true;
            }
        }
        return false;
    }

    bool setLhbmState(bool enable) override {
        bool status = false;
        if (m_active_node) {
            int fd = open(m_active_node, O_WRONLY);
            if (fd >= 0) {
                const char* val = enable ? "1" : "0";
                write(fd, val, strlen(val));
                close(fd);
                status = true;
            }
        }

        if (m_fod_sysfs && strlen(m_fod_sysfs) > 0) {
            int ffd = open(m_fod_sysfs, O_WRONLY);
            if (ffd >= 0) {
                const char* val = enable ? "1" : "0";
                write(ffd, val, strlen(val));
                close(ffd);
            }
        }
        return status;
    }

    const char* getName() const override {
        return "Sysfs HBM Fallback Engine";
    }
};

ILhbmBackend* createSysfsLhbmBackend(const char* fod_sysfs_node) {
    auto backend = new SysfsLhbmBackend(fod_sysfs_node);
    if (backend->initialize()) {
        return backend;
    }
    delete backend;
    return nullptr;
}
