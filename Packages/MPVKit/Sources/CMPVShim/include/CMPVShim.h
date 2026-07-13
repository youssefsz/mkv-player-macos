#ifndef MKV_PLAYER_CMPV_SHIM_H
#define MKV_PLAYER_CMPV_SHIM_H

#include <stddef.h>
#include <stdint.h>

// Minimal ABI mirrors from mpv 0.41's public client.h, render.h, and
// render_gl.h. They contain no linked symbols, so MPVKit remains buildable
// before MediaCore is vendored while Clang still guarantees C field layout.

typedef void *(*MKVMPVGetProcAddress)(void *context, const char *name);

typedef struct {
    int32_t type;
    void *data;
} MKVMPVRenderParam;

typedef struct {
    MKVMPVGetProcAddress getProcAddress;
    void *context;
} MKVMPVOpenGLInitParams;

typedef struct {
    int32_t fbo;
    int32_t width;
    int32_t height;
    int32_t internalFormat;
} MKVMPVOpenGLFBO;

typedef struct {
    int32_t eventID;
    int32_t error;
    uint64_t replyUserData;
    void *data;
} MKVMPVEvent;

typedef struct {
    const char *name;
    int32_t format;
    void *data;
} MKVMPVEventProperty;

typedef struct {
    int64_t playlistEntryID;
} MKVMPVEventStartFile;

typedef struct {
    int32_t reason;
    int32_t error;
    int64_t playlistEntryID;
} MKVMPVEventEndFilePrefix;

_Static_assert(sizeof(MKVMPVRenderParam) == 16, "Unexpected mpv_render_param ABI");
_Static_assert(offsetof(MKVMPVRenderParam, data) == 8, "Unexpected render data offset");
_Static_assert(sizeof(MKVMPVOpenGLInitParams) == 16, "Unexpected OpenGL init ABI");
_Static_assert(sizeof(MKVMPVOpenGLFBO) == 16, "Unexpected OpenGL FBO ABI");
_Static_assert(sizeof(MKVMPVEvent) == 24, "Unexpected mpv_event ABI");
_Static_assert(offsetof(MKVMPVEvent, data) == 16, "Unexpected event data offset");
_Static_assert(sizeof(MKVMPVEventProperty) == 24, "Unexpected property event ABI");
_Static_assert(offsetof(MKVMPVEventProperty, data) == 16, "Unexpected property data offset");
_Static_assert(sizeof(MKVMPVEventStartFile) == 8, "Unexpected start-file event ABI");
_Static_assert(sizeof(MKVMPVEventEndFilePrefix) == 16, "Unexpected end-file event prefix ABI");
_Static_assert(offsetof(MKVMPVEventEndFilePrefix, playlistEntryID) == 8,
               "Unexpected end-file playlist ID offset");

#endif
