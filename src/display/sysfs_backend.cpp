#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include "../../include/lhbm_backend.h"

class SysfsLhbmBackend : public ILhbmBackend {
private:
    const char* m_node;

public:
    SysfsLhbmBackend(const char* node) : m_node(node) {}

    bool initialize() override {
        int fd = open(m_node, O_WRONLY);
        if (fd >= 0) {
            close(fd);
            return true;
        }
        return false;
    }

    void setLhbmState(bool enable) override {
        int fd = open(m_node, O_WRONLY);
        if (fd >= 0) {
            const char* val = enable ? "1" : "0";
            write(fd, val, strlen(val));
            close(fd);
        }
    }

    const char* getName() const override { return "Sysfs Generic Driver"; }
};

ILhbmBackend* createSysfsLhbmBackend(const char* sysfs_node) {
    return new SysfsLhbmBackend(sysfs_node);
}
