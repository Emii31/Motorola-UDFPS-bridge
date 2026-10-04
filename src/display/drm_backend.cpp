#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <stdint.h>
#include "../../include/lhbm_backend.h"

#define DRM_IOCTL_MDSS_DISP_PARAM 0xc008649f

struct disp_param_req {
    uint32_t param_id;
    int32_t value;
};

class DrmLhbmBackend : public ILhbmBackend {
private:
    const char* m_node;
    int m_fd;
    int m_p0, m_p1, m_p2;

public:
    DrmLhbmBackend(const char* node, int p0, int p1, int p2)
        : m_node(node), m_fd(-1), m_p0(p0), m_p1(p1), m_p2(p2) {}

    ~DrmLhbmBackend() override {
        if (m_fd >= 0) close(m_fd);
    }

    bool initialize() override {
        m_fd = open(m_node, O_RDWR);
        return (m_fd >= 0);
    }

    void setLhbmState(bool enable) override {
        if (m_fd < 0) return;
        struct disp_param_req req;

        req.param_id = 0; req.value = enable ? m_p0 : 0;
        ioctl(m_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

        req.param_id = 1; req.value = enable ? m_p1 : 0;
        ioctl(m_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);

        req.param_id = 2; req.value = enable ? m_p2 : 0;
        ioctl(m_fd, DRM_IOCTL_MDSS_DISP_PARAM, &req);
    }

    const char* getName() const override { return "Qualcomm DRM Driver"; }
};

ILhbmBackend* createDrmLhbmBackend(const char* drm_node, int p0, int p1, int p2) {
    return new DrmLhbmBackend(drm_node, p0, p1, p2);
}
