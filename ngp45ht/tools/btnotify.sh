systemctl restart ngp-bt-agent 2>&1
sleep 2
python3 - <<'PY'
import dbus, dbus.service, gi, time, binascii
from dbus.mainloop.glib import DBusGMainLoop
gi.require_version('GLib', '2.0')
from gi.repository import GLib
DBusGMainLoop(set_as_default=True)
bus = dbus.SystemBus()
om = dbus.Interface(bus.get_object("org.bluez", "/"), "org.freedesktop.DBus.ObjectManager")
chars = {}
for path, ifs in om.GetManagedObjects().items():
    c = ifs.get("org.bluez.GattCharacteristic1")
    if c and str(c.get("UUID")) in ("0000ff14-0000-1000-8000-00805f9b34fb",
                                    "d7f010e2-660d-46e9-96c3-19c4148bdab5"):
        chars[path] = str(c.get("UUID"))
print("subscribing to %d notify characteristics" % len(chars), flush=True)
t0 = time.time()
counts = {}
def on_change(changed, invalidated, path):
    if "Value" not in changed:
        return
    v = bytes(bytearray(changed["Value"]))
    u = str(changed.get("PrepareWrite")) if False else ""
    counts[path] = counts.get(path, 0) + 1
    print("t=%6.2f  %s  n=%-4d  len=%2d  %s" % (time.time() - t0, str(chars[path])[:8],
          counts[path], len(v), binascii.hexlify(v).decode()), flush=True)
for path in chars:
    ch = dbus.Interface(bus.get_object("org.bluez", path), "org.bluez.GattCharacteristic1")
    try:
        ch.StartNotify()
        print("StartNotify ok on %s" % path, flush=True)
    except Exception as exc:
        print("StartNotify FAILED on %s: %s" % (path, exc), flush=True)
    bus.add_signal_receiver(on_change, "PropertiesChanged", "org.freedesktop.DBus.Properties",
                            "org.bluez", path, byte_arrays=True)
loop = GLib.MainLoop()
GLib.timeout_add_seconds(90, loop.quit)
loop.run()
print("window closed; notifications seen: %s" % (sum(counts.values()),), flush=True)
PY
