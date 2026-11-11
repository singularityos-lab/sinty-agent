import json, sys
from gi.repository import Gio, GLib

XML = """<node><interface name="dev.sinty.AgentClipboard1">
<method name="Copy"><arg type="s" direction="in"/><arg type="b" direction="in"/><arg type="u" direction="in"/></method>
</interface></node>"""
out = sys.argv[1]
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)


def handle(conn, sender, path, iface, method, params, inv):
    text, sensitive, clear = params.unpack()
    with open(out, "a") as f:
        f.write(json.dumps({"text": text, "sensitive": sensitive, "clear_after": clear, "sender": sender}) + "\n")
    inv.return_value(None)


bus.register_object("/dev/sinty/Shell/AgentClipboard", Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], handle, None, None)
Gio.bus_own_name_on_connection(bus, "dev.sinty.desktop", Gio.BusNameOwnerFlags.NONE, None, None)
GLib.MainLoop().run()
