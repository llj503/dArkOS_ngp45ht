#!/usr/bin/env python3
"""panelprop.py — read/write DRM connector properties via libdrm (ctypes).

Written for the XIFAN NGP45HT dArkOS port so that the ROCKNIX "panel
adjustment" feature can be ported without installing modetest/libdrm-utils:
the system already ships libdrm.so.2 and python3, and /dev/dri/card0 is
group ``video`` while ``ark`` is in that group, so no sudo is needed either.

Mechanism (identical to ROCKNIX's paneladj on RK356X): the Rockchip VOP2
driver exposes four connector properties on the DSI connector —
``brightness`` / ``contrast`` / ``saturation`` / ``hue`` — all 0-100 with
50 = neutral (driver: rockchip_drm_vop2.c vop2_tv_config_update, which maps
them into the VOP2 BCSH post-processor).  The values live in the DRM
property objects, so every later atomic commit (by EmulationStation,
RetroArch, anything) re-applies them; they only reset on reboot, which is
what the ngp-panel-restore.service boot hook is for.

Usage:
    panelprop.py list                      # every connector + every property
    panelprop.py get  <property>           # prints "connector <id> <name> = <value>"
    panelprop.py set  <property> <value>   # returns 0 on success
"""
import ctypes
import os
import sys

DRM_MODE_OBJECT_CONNECTOR = 0xc0c0c0c0
DRM_MODE_OBJECT_PROPERTY = 0xb0b0b0b0


class _ObjectProps(ctypes.Structure):
    _fields_ = [("count_props", ctypes.c_uint32),
                ("props", ctypes.POINTER(ctypes.c_uint32)),
                ("prop_values", ctypes.POINTER(ctypes.c_uint64))]


class _PropRes(ctypes.Structure):
    _fields_ = [("prop_id", ctypes.c_uint32), ("flags", ctypes.c_uint32),
                ("name", ctypes.c_char * 32), ("count_values", ctypes.c_uint32),
                ("values", ctypes.c_void_p), ("count_enums", ctypes.c_uint32),
                ("enums", ctypes.c_void_p), ("count_blobs", ctypes.c_uint32),
                ("blob_ids", ctypes.c_void_p)]


class _ModeRes(ctypes.Structure):
    _fields_ = [("count_fbs", ctypes.c_int), ("fbs", ctypes.POINTER(ctypes.c_uint32)),
                ("count_crtcs", ctypes.c_int), ("crtcs", ctypes.POINTER(ctypes.c_uint32)),
                ("count_connectors", ctypes.c_int), ("connectors", ctypes.POINTER(ctypes.c_uint32)),
                ("count_encoders", ctypes.c_int), ("encoders", ctypes.POINTER(ctypes.c_uint32)),
                ("min_width", ctypes.c_uint32), ("max_width", ctypes.c_uint32),
                ("min_height", ctypes.c_uint32), ("max_height", ctypes.c_uint32)]


lib = ctypes.CDLL("libdrm.so.2", use_errno=True)
lib.drmModeGetResources.restype = ctypes.POINTER(_ModeRes)
lib.drmModeObjectGetProperties.restype = ctypes.POINTER(_ObjectProps)
lib.drmModeGetProperty.restype = ctypes.POINTER(_PropRes)
lib.drmModeObjectSetProperty.argtypes = [ctypes.c_int, ctypes.c_uint32,
                                         ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint64]


def connectors(fd):
    res = lib.drmModeGetResources(fd)
    if not res:
        return []
    n, arr = res.contents.count_connectors, res.contents.connectors
    out = [arr[i] for i in range(n)] if arr else []
    lib.drmModeFreeResources(ctypes.cast(res, ctypes.c_void_p))
    return out


def props_of(fd, cid):
    p = lib.drmModeObjectGetProperties(fd, cid, DRM_MODE_OBJECT_CONNECTOR)
    if not p:
        return []
    n = p.contents.count_props
    ids, vals = p.contents.props, p.contents.prop_values
    out = []
    for i in range(n):
        pid = ids[i]
        pr = lib.drmModeGetProperty(fd, pid)
        name = pr.contents.name.decode() if pr else "?"
        if pr:
            lib.drmModeFreeProperty(ctypes.cast(pr, ctypes.c_void_p))
        out.append((pid, name, vals[i]))
    lib.drmModeFreeObjectProperties(ctypes.cast(p, ctypes.c_void_p))
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    fd = os.open("/dev/dri/card0", os.O_RDWR)
    try:
        cl = connectors(fd)
        if sys.argv[1] == "list":
            for cid in cl:
                print("connector %d:" % cid)
                for _pid, name, val in props_of(fd, cid):
                    print("  %-28s = %d" % (name, val))
            return 0
        if len(sys.argv) < 3:
            print("need a property name")
            return 1
        want = sys.argv[2]
        for cid in cl:
            for pid, name, val in props_of(fd, cid):
                if name != want:
                    continue
                if sys.argv[1] == "get":
                    print("connector %d %s = %d" % (cid, name, val))
                    return 0
                if sys.argv[1] == "set":
                    if len(sys.argv) < 4:
                        print("need a value")
                        return 1
                    nv = int(sys.argv[3])
                    rc = lib.drmModeObjectSetProperty(fd, cid, DRM_MODE_OBJECT_CONNECTOR, pid, nv)
                    if rc != 0:
                        print("set %s on connector %d -> %d failed: rc=%d errno=%d (%s)"
                              % (name, cid, nv, rc, ctypes.get_errno(),
                                 os.strerror(ctypes.get_errno())))
                    return rc
        print("property '%s' not found on any connector" % want)
        return 3
    finally:
        os.close(fd)


sys.exit(main())
