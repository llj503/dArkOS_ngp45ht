#!/usr/bin/env python3
"""BlueZ pairing agent for the NGP45HT.

dArkOS ships bluetoothd but registers no agent, and nothing in the UI does either,
so every pairing attempt dies exactly where the reference notes said it would: the
pad offers a pairing request, there is no responder on this side, the pad gives up.
That is why discovery works and "connect" fails instantly.

Everything is auto-accepted on purpose. This is a closed handheld, not a laptop:
the only peer it is ever expected to bond is a gamepad or a headset that cannot show
a numeric comparison anyway (no display, no keyboard). A wrong-passkey attack would
mean standing in BLE range with a spoofed pad and guessing nothing.

Run under systemd (ngp-bt-agent.service); it needs the dbus + glib bindings that
python3-dbus pulls in, both of which are already on the card.
"""
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

ADAPTER = "/org/bluez/hci0"
AGENT_PATH = "/org/bluez/agent/ngp45ht"
AGENT_NAME = "ngp45ht-auto"


class Agent(dbus.service.Object):
    def __init__(self, bus, path):
        # exported on the connection itself, not under a well-known name: the system
        # bus policy refuses to let a user service own org.ngp45ht.agent, and
        # bluetoothd only ever needs the object path we registered
        super().__init__(bus, path)

    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Release(self):
        pass

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        # legacy pairing on the pad's side wants a PIN; 0000 is what almost every
        # gamepad expects when it has no way to type one
        print("RequestPinCode %s -> 0000" % device, flush=True)
        return dbus.String("0000")

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        print("RequestPasskey %s -> 0" % device, flush=True)
        return dbus.UInt32(0)

    @dbus.service.method("org.bluez.Agent1", in_signature="ou", out_signature="")
    def DisplayPasskey(self, device, passkey):
        print("DisplayPasskey %s %s (accepted)" % (device, passkey), flush=True)

    @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode):
        print("DisplayPinCode %s %s (accepted)" % (device, pincode), flush=True)

    @dbus.service.method("org.bluez.Agent1", in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        # the numeric-comparison case: accept blindly, the pad shows the same number
        print("RequestConfirmation %s %s -> accepted" % (device, passkey), flush=True)

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        print("RequestAuthorization %s -> accepted" % device, flush=True)

    @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        print("AuthorizeService %s %s -> accepted" % (device, uuid), flush=True)

    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Cancel(self):
        pass


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    agent = Agent(bus, AGENT_PATH)
    mgr = bus.get_object("org.bluez", "/org/bluez")
    # call_blocking with an explicit signature instead of the proxy: the proxy asks
    # BlueZ to introspect and then mis-derives the argument list on this build, which
    # fails as a TypeError inside dbus before the message ever leaves the process.
    def agent_call(method, in_sig, args):
        return bus.call_blocking("org.bluez", "/org/bluez", "org.bluez.AgentManager1",
                                 method, in_sig, args)

    # This BlueZ (Debian 5.82-1.1 downstream) exports the *legacy* pair of methods --
    # introspected verbatim: RegisterAgent(o agent, s capability), UnregisterAgent(o),
    # RequestDefaultAgent(o) -- and has no RegisterApplication at all.  Call with an
    # explicit signature (the proxy mis-derives it here) and prefer what actually
    # exists, falling forward to the modern API if a newer BlueZ ever shows up.
    try:
        agent_call("RegisterAgent", "os", [dbus.ObjectPath(AGENT_PATH), "DisplayYesNo"])
        print("registered via RegisterAgent(o,s) capability=DisplayYesNo", flush=True)
    except dbus.exceptions.DBusException as e:
        if "RegisterAgent" not in str(e):
            raise
        agent_call("RegisterApplication", "oa{sv}",
                   [dbus.ObjectPath(AGENT_PATH), dbus.Dictionary({"Capability": "NoDisplay"}, "sv")])
        print("registered via RegisterApplication (Capability=NoDisplay)", flush=True)
    # become the default so a later bluetoothctl or any other client sees us first
    try:
        agent_call("RequestDefaultAgent", "o", [dbus.ObjectPath(AGENT_PATH)])
    except dbus.exceptions.DBusException as e:
        print("RequestDefaultAgent: %s" % e, flush=True)
    print("ngp-bt-agent registered at %s" % AGENT_PATH, flush=True)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
