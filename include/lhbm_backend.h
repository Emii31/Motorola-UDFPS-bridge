#ifndef LHBM_BACKEND_H
#define LHBM_BACKEND_H

class ILhbmBackend {
public:
    virtual ~ILhbmBackend() {}
    virtual bool initialize() = 0;
    virtual void setLhbmState(bool enable) = 0;
    virtual const char* getName() const = 0;
};

// Factory functions
ILhbmBackend* createDrmLhbmBackend(const char* drm_node, int p0, int p1, int p2);
ILhbmBackend* createSysfsLhbmBackend(const char* sysfs_node);

#endif // LHBM_BACKEND_H
