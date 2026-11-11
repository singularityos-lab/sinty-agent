import time
from gi.repository import Gio, GLib

XML = """
<node>
 <interface name="org.freedesktop.Secret.Service">
  <method name="OpenSession"><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="v" direction="out"/><arg type="o" direction="out"/></method>
  <method name="ReadAlias"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
  <method name="Unlock"><arg type="ao" direction="in"/><arg type="ao" direction="out"/><arg type="o" direction="out"/></method>
  <method name="Lock"><arg type="ao" direction="in"/><arg type="ao" direction="out"/><arg type="o" direction="out"/></method>
 </interface>
 <interface name="org.freedesktop.Secret.Collection">
  <method name="CreateItem"><arg type="a{sv}" direction="in"/><arg type="(oayays)" direction="in"/><arg type="b" direction="in"/><arg type="o" direction="out"/><arg type="o" direction="out"/></method>
 </interface>
 <interface name="org.freedesktop.Secret.Item">
  <method name="GetSecret"><arg type="o" direction="in"/><arg type="(oayays)" direction="out"/></method>
  <method name="SetSecret"><arg type="(oayays)" direction="in"/></method>
  <method name="Delete"><arg type="o" direction="out"/></method>
 </interface>
 <interface name="org.freedesktop.DBus.Properties">
  <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
  <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
  <method name="Set"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/></method>
 </interface>
</node>
"""

COLL = "/org/freedesktop/secrets/collection/login"
items = {}
counter = [0]


def add(label, attrs, secret):
    counter[0] += 1
    path = "%s/%d" % (COLL, counter[0])
    items[path] = {"label": label, "attrs": dict(attrs), "secret": secret, "created": int(time.time())}
    return path


add("Example Mail", {"xdg:schema": "dev.sinty.Password", "url": "https://mail.example.org", "username": "ada"}, "SECRET-hunter2")
add("Example Shop", {"xdg:schema": "dev.sinty.Password", "url": "https://shop.example.org", "username": "ada@example.org"}, "SECRET-hunter2")
add("Bank", {"xdg:schema": "dev.sinty.Password", "url": "https://bank.example.org", "username": "ada"}, "SECRET-Zq8#vL2!mN9x$Rt4pW")

node = Gio.DBusNodeInfo.new_for_xml(XML)
iface = {i.name: i for i in node.interfaces}
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)


def props(path, name):
    if path == "/org/freedesktop/secrets":
        return {"Collections": GLib.Variant("ao", [COLL])}
    if path == COLL:
        return {"Label": GLib.Variant("s", "Login"), "Locked": GLib.Variant("b", False),
                "Items": GLib.Variant("ao", sorted(items.keys()))}
    it = items[path]
    return {"Label": GLib.Variant("s", it["label"]), "Type": GLib.Variant("s", "dev.sinty.Password"),
            "Created": GLib.Variant("t", it["created"]), "Modified": GLib.Variant("t", it["created"]),
            "Attributes": GLib.Variant("a{ss}", it["attrs"]), "Locked": GLib.Variant("b", False)}


def handle(conn, sender, path, interface, method, params, inv):
    p = params.unpack()
    if method == "OpenSession":
        inv.return_value(GLib.Variant("(vo)", (GLib.Variant("s", ""), "/org/freedesktop/secrets/session/1")))
    elif method == "ReadAlias":
        inv.return_value(GLib.Variant("(o)", (COLL,)))
    elif method in ("Unlock", "Lock"):
        inv.return_value(GLib.Variant("(aoo)", (p[0], "/")))
    elif method == "CreateItem":
        pr = p[0]
        label = pr.get("org.freedesktop.Secret.Item.Label", "")
        attrs = pr.get("org.freedesktop.Secret.Item.Attributes", {})
        secret = bytes(p[1][2]).decode()
        np = add(label, attrs, secret)
        pass
        inv.return_value(GLib.Variant("(oo)", (np, "/")))
    elif method == "GetSecret":
        s = items[path]["secret"].encode()
        inv.return_value(GLib.Variant("((oayays))", (("/org/freedesktop/secrets/session/1", b"", s, "text/plain"),)))
    elif method == "SetSecret":
        items[path]["secret"] = bytes(p[0][2]).decode()
        inv.return_value(None)
    elif method == "Delete":
        items.pop(path, None)
        inv.return_value(GLib.Variant("(o)", ("/",)))
    elif method == "Get":
        inv.return_value(GLib.Variant("(v)", (props(path, p[0])[p[1]],)))
    elif method == "GetAll":
        inv.return_value(GLib.Variant("(a{sv})", (props(path, p[0]),)))
    elif method == "Set":
        if p[1] == "Label":
            items[path]["label"] = p[2]
        elif p[1] == "Attributes":
            items[path]["attrs"] = dict(p[2])
        inv.return_value(None)


class Inv:
    def __init__(self, conn, msg):
        self.conn, self.msg = conn, msg

    def return_value(self, v):
        r = self.msg.new_method_reply()
        if v is not None:
            r.set_body(v)
        self.conn.send_message(r, Gio.DBusSendMessageFlags.NONE)

    def error(self, text):
        r = self.msg.new_method_error_literal("org.freedesktop.DBus.Error.Failed", text)
        self.conn.send_message(r, Gio.DBusSendMessageFlags.NONE)


def filt(conn, msg, incoming):
    if not incoming or msg.get_message_type() != Gio.DBusMessageType.METHOD_CALL:
        return msg
    path = msg.get_path() or ""
    if not path.startswith("/org/freedesktop/secrets"):
        return msg
    inv = Inv(conn, msg)
    body = msg.get_body() or GLib.Variant("()", ())
    def run():
        try:
            handle(conn, msg.get_sender(), path, msg.get_interface(), msg.get_member(), body, inv)
        except Exception as e:
            inv.error(repr(e))
        return False
    GLib.idle_add(run)
    return None


bus.add_filter(filt)
Gio.bus_own_name_on_connection(bus, "org.freedesktop.secrets", Gio.BusNameOwnerFlags.NONE, None, None)
GLib.MainLoop().run()
