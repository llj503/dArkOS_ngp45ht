timeout 8 bluetoothctl --timeout 4 scan off < /dev/null >/dev/null 2>&1
timeout 16 bluetoothctl --timeout 12 scan on < /dev/null 2>&1 | grep -aE "NEW|Device" | tail -8
python3 - <<'PY'
import dbus
bus = dbus.SystemBus()
om = dbus.Interface(bus.get_object("org.bluez", "/"), "org.freedesktop.DBus.ObjectManager")
found = 0
for path, props_by_iface in om.GetManagedObjects().items():
    if "org.bluez.Device1" not in props_by_iface:
        continue
    found += 1
    p = props_by_iface["org.bluez.Device1"]
    print("path     :", path)
    print("   Alias  : %r  Address: %s" % (str(p.get("Alias", "")), str(p.get("Address", ""))))
    print("   Techs  :", [str(t) for t in p.get("SupportedTechnologies", [])])
    print("   UUIDs  :", [str(u) for u in p.get("UUIDs", [])])
    print("   Paired=%s Trusted=%s Connected=%s Legacy=%s RSSI=%s" % (
        p.get("Paired"), p.get("Trusted"), p.get("Connected"), p.get("LegacyPairing"), p.get("RSSI")))
    ad = p.get("AdvertisingData")
    if ad:
        for k in ad:
            print("   Adv.%s = %s" % (k, str(ad[k])[:160]))
print("devices found:", found)
PY
