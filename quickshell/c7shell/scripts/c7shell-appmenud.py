#!/usr/bin/env python3
"""com.canonical.AppMenu.Registrar for c7shell.

Quickshell 0.3.1 can neither own a DBus service name nor construct a
DBusMenuHandle, so the shell cannot be the registrar itself. This daemon is the
registrar: it owns the well-known name, pulls each caller's exported menu bar
over com.canonical.dbusmenu, and republishes it as JSON lines on a unix socket
that Services/AppMenuService.qml reads.

The join key is the PID, not the window id. Registrar callers pass an X11
`u windowId` that means nothing on Wayland, so instead every caller's unique bus
name is resolved to a PID via org.freedesktop.DBus.GetConnectionUnixProcessID;
the shell matches that against the focused Hyprland toplevel's
`lastIpcObject.pid`.

Protocol on $XDG_RUNTIME_DIR/c7shell-appmenu.sock (one JSON object per line):
  out  {"event":"menus","pid":N,"menus":[{"id":I,"label":L,"items":[...]}]}
  out  {"event":"gone","pid":N}
  in   {"event":"trigger","pid":N,"id":ITEM_ID}
  in   {"event":"trigger","pid":N,"path":[menuIndex,itemIndex]}
  in   {"event":"registrar","enabled":BOOL}
A fresh connection is sent the current snapshot, one "menus" line per PID.

"registrar" is the global-menu switch: false releases the well-known name, so
apps go back to drawing their own menu bars, and true takes it again. The
daemon starts owning it; the shell sends its setting once it has read it.

Requires python-dbus and python-gobject (both in the Arch repos, both already
installed here). Logs to stderr only; stdout carries --dump output.
"""

import argparse
import json
import os
import re
import socket
import sys
import time

DBUSMENU = "com.canonical.dbusmenu"
REGISTRAR = "com.canonical.AppMenu.Registrar"
REGISTRAR_PATH = "/com/canonical/AppMenu/Registrar"
CALL_TIMEOUT = 2.0  # seconds; a wedged app must not wedge the daemon

SOCK_PATH = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid(),
    "c7shell-appmenu.sock",
)


def log(*a):
    print("[appmenud]", *a, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# layout parsing -- pure, no DBus types needed. `--selftest` covers this half.
# --------------------------------------------------------------------------

# The only per-item properties the shell renders, and so the only ones an
# ItemsPropertiesUpdated payload can be applied to without a refetch.
PATCHABLE = {"label", "enabled", "shortcut"}

_MNEMONIC = re.compile(r"_(.)")
_MODS = {
    "control": "Ctrl",
    "ctrl": "Ctrl",
    "alt": "Alt",
    "shift": "Shift",
    "super": "Super",
    "meta": "Meta",
}


def clean_label(props):
    """dbusmenu labels carry '_' accelerator markers: 'Save _As' -> 'Save As'."""
    return _MNEMONIC.sub(r"\1", str(props.get("label", ""))).strip()


def shortcut(props):
    """`shortcut` is aas -- a list of key combinations. Render the first one."""
    combos = props.get("shortcut") or []
    if not combos:
        return ""
    keys = [str(k) for k in combos[0]]
    return "+".join(_MODS.get(k.lower(), k.upper() if len(k) == 1 else k) for k in keys)


def node(entry):
    """Unpack a dbusmenu (ia{sv}av) layout struct into (id, props, children)."""
    ident, props, children = entry
    return int(ident), dict(props), list(children)


def visible(props):
    return bool(props.get("visible", True))


_NODE = re.compile(r'<node name="([^"/]+)"')


def menubar_children(xml):
    """Child node names in an Introspect reply for /MenuBar -> full paths.

    Qt exports each window's bar at /MenuBar/<n>, so the parent node lists them.
    """
    return ["/MenuBar/" + n for n in _NODE.findall(str(xml))]


def as_item(entry):
    """One dropdown row in the shape Modules/Bar/GlobalMenuDropdown.qml renders."""
    ident, props, _ = node(entry)
    if str(props.get("type", "")) == "separator":
        return {"separator": True}
    return {
        "id": ident,
        "label": clean_label(props),
        "shortcut": shortcut(props),
        "enabled": bool(props.get("enabled", True)),
        # The dropdown is flat: a submenu row triggers its parent and nothing
        # opens. ponytail: nested submenus need a second dropdown level in the
        # renderer -- add that before making this field mean anything.
        "submenu": str(props.get("children-display", "")) == "submenu",
    }


def top_levels(root):
    """Root layout -> [(id, label, inline children)] for each visible menu."""
    tops = []
    for top in node(root)[2]:
        tid, tprops, inline = node(top)
        if not visible(tprops):
            continue
        label = clean_label(tprops)
        if not label:
            continue
        tops.append((tid, label, inline))
    return tops


def menu_entry(tid, label, kids):
    """One top-level menu in the shape the shell renders."""
    return {
        "id": tid,
        "label": label,
        "items": [as_item(k) for k in kids if visible(node(k)[1])],
    }


def build_menus(root, fetch_children):
    """Root layout + one level per top-level menu -> the shell's `menus` array.

    `fetch_children(id)` returns that menu's child entries; Qt apps only fill a
    submenu in after AboutToShow, so the children carried by the root layout are
    a fallback, not the source of truth.

    Synchronous, and used only by the selftest -- the daemon walks the same two
    steps through Daemon.refresh() so that no DBus call blocks the mainloop.
    """
    return [
        menu_entry(tid, label, fetch_children(tid) or inline)
        for tid, label, inline in top_levels(root)
    ]


# --------------------------------------------------------------------------
# the daemon
# --------------------------------------------------------------------------


class Daemon:
    def __init__(self, bus):
        self.bus = bus
        self.windows = {}  # windowId -> (sender, menu object path)
        self.by_pid = {}  # pid -> (sender, menu object path)
        self.menus = {}  # pid -> menus array
        self.clients = []  # connected shell sockets
        self.pending = {}  # pid -> GLib source id, refresh debounce
        self.gen = {}  # pid -> refresh generation; fences overlapping fetches
        self.shown = set()  # (sender, path, menu id) already sent AboutToShow
        self.owned = False  # do we hold REGISTRAR right now?
        self.object = None  # the exported RegistrarObject, while we do

        import dbus
        import dbus.bus

        self.dbus = dbus
        self.fdo = dbus.Interface(
            bus.get_object("org.freedesktop.DBus", "/org/freedesktop/DBus"),
            "org.freedesktop.DBus",
        )
        # path_keyword matters as much as sender_keyword: on Wayland these
        # signals are the only place the menu's object path is ever announced.
        # See on_layout_updated.
        bus.add_signal_receiver(
            self.on_layout_updated,
            signal_name="LayoutUpdated",
            dbus_interface=DBUSMENU,
            sender_keyword="sender",
            path_keyword="path",
        )
        # Its own handler, not LayoutUpdated's: this signal carries the changed
        # properties, and applying them beats refetching the whole bar.
        bus.add_signal_receiver(
            self.on_items_properties_updated,
            signal_name="ItemsPropertiesUpdated",
            dbus_interface=DBUSMENU,
            sender_keyword="sender",
            path_keyword="path",
        )
        # arg2 is new_owner: "" means the connection went away.
        bus.add_signal_receiver(
            self.on_name_lost,
            signal_name="NameOwnerChanged",
            dbus_interface="org.freedesktop.DBus",
            arg2="",
        )

    # -- registrar ownership -------------------------------------------------
    # The name IS the feature switch. A toolkit that finds REGISTRAR on the bus
    # hands its menu bar over and draws none of its own, so a shell that merely
    # stopped rendering the export would leave the user with no menus anywhere
    # (dolphin's whole settings menu, the case in issue #17). Turning the global
    # menu off therefore drops the name; turning it back on takes it again.
    #
    # dbus.service.BusName is deliberately not used: it is cached per (bus,
    # name) behind a weakref and releases only when the last reference is
    # collected, which makes "release now, request again later" depend on GC
    # timing. request_name/release_name on the connection is the same two bus
    # calls with none of that.

    def acquire(self):
        """Own REGISTRAR and export the object on it. False if someone else does."""
        if self.owned:
            return True
        reply = self.bus.request_name(REGISTRAR, self.dbus.bus.NAME_FLAG_DO_NOT_QUEUE)
        if reply not in (
            self.dbus.bus.REQUEST_NAME_REPLY_PRIMARY_OWNER,
            self.dbus.bus.REQUEST_NAME_REPLY_ALREADY_OWNER,
        ):
            log("%s is already owned -- another registrar is running" % REGISTRAR)
            return False
        self.owned = True
        if self.object is None:
            self.object = make_object(self, self.bus)
        log("owning %s (pid %d)" % (REGISTRAR, os.getpid()))
        # Apps that exported to a previous owner are still exporting; the ones
        # that started while nobody owned the name never will, until they open
        # another window. See scan().
        self.scan()
        return True

    def release(self):
        """Drop REGISTRAR, and every menu that came with it."""
        if not self.owned:
            return
        self.owned = False
        if self.object is not None:
            self.object.remove_from_connection()
            self.object = None
        self.bus.release_name(REGISTRAR)
        # The shell must not keep rendering a bar it no longer owns the source
        # of, so tell it every PID is gone rather than leaving stale menus up.
        for pid in list(self.menus):
            self.drop(pid)
        self.windows.clear()
        self.by_pid.clear()
        self.gen.clear()
        self.shown.clear()
        log("released %s" % REGISTRAR)

    def set_registrar(self, enabled):
        """The shell's answer to "global menu on?". Idempotent either way."""
        if enabled:
            self.acquire()
        else:
            self.release()

    # -- registrar interface ------------------------------------------------

    def adopt(self, sender, path, why):
        """Bind a menu bar at (sender, path) to its PID and queue a fetch.

        Idempotent: re-adopting the pair already held for that PID is a no-op,
        which is what keeps the LayoutUpdated discovery path below cheap.

        Nothing is adopted while the registrar is released: the dbusmenu signals
        this listens on are broadcast whether or not we own the name, and an app
        that kept exporting to nobody would otherwise walk straight back into
        the shell through the discovery path.
        """
        if not self.owned:
            return 0
        try:
            pid = int(self.fdo.GetConnectionUnixProcessID(sender))
        except self.dbus.DBusException as e:
            log("no pid for", sender, e)
            return 0
        if self.by_pid.get(pid) == (sender, path):
            return pid
        # ponytail: last menu bar wins per PID. A multi-window app exports one
        # per window and only the newest is kept -- fixable only with a window
        # key the compositor also sees, which Wayland does not give us.
        self.by_pid[pid] = (sender, path)
        self.forget_shown(sender, path)  # a new menu bar means a fresh layout
        log("%s pid=%d %s%s" % (why, pid, sender, path))
        # Deferred, never inline: on the RegisterWindow path the app is blocked
        # waiting for it to return, and calling GetLayout back into it from here
        # is a reentrant round trip. The debounce also swallows the
        # LayoutUpdated burst that follows.
        self.schedule(pid)
        return pid

    def register(self, window_id, path, sender):
        self.windows[window_id] = (sender, path)
        self.adopt(sender, path, "register window=%d" % window_id)

    def scan(self):
        """Adopt menu bars that were exported before this daemon started.

        Asynchronous like trigger(), and for the same reason: several peers on a
        normal session never answer Introspect, and synchronously they burned
        the timeout one after another and held the socket up for ~10s. Replies
        land once the mainloop runs.

        Unique names only (":1.23"), never well-known ones -- introspecting a
        well-known name would activate the service behind it. An app launched
        while no registrar owned the name has no menu bar to find at all (Qt
        decides that once, at first menu bar creation, and caches it), so this
        only ever recovers apps that outlived a previous daemon.
        """

        def found(xml, name):
            for path in menubar_children(xml):
                self.adopt(name, path, "discover")

        for name in self.fdo.ListNames():
            name = str(name)
            if not name.startswith(":"):
                continue
            self.dbus.Interface(
                self.bus.get_object(name, "/MenuBar", introspect=False),
                "org.freedesktop.DBus.Introspectable",
            ).Introspect(
                reply_handler=lambda xml, n=name: found(xml, n),
                error_handler=lambda _e: None,  # no /MenuBar, or no answer
            )

    def forget_shown(self, sender, path):
        self.shown -= {k for k in self.shown if k[0] == sender and k[1] == path}

    def unregister(self, window_id):
        win = self.windows.pop(window_id, None)
        if not win or win in self.windows.values():
            return  # unknown, or the same menu is still up under another id
        for pid, cur in list(self.by_pid.items()):
            if cur == win:
                self.drop(pid)

    def drop(self, pid):
        win = self.by_pid.pop(pid, None)
        self.gen.pop(pid, None)
        if win:
            self.forget_shown(*win)
        if self.menus.pop(pid, None) is not None:
            self.publish({"event": "gone", "pid": pid})

    # -- menu fetching ------------------------------------------------------

    def refresh(self, pid):
        """Pull this PID's menu bar WITHOUT blocking the mainloop.

        Every call uses the async reply_handler/error_handler form, the same one
        scan() and trigger() use, chained one menu at a time. dbus-python's
        blocking send does not pump the GLib loop, so the synchronous version
        froze the whole daemon -- no socket reads, no NameOwnerChanged, no
        signal dispatch -- for up to CALL_TIMEOUT per outstanding call, which a
        five-menu app that stopped answering turned into ~22 seconds.

        `gen` fences a chain that is still in flight when the next refresh
        starts: only the newest one is allowed to publish.
        """
        win = self.by_pid.get(pid)
        if not win:
            return
        sender, path = win
        menu = self.dbus.Interface(self.bus.get_object(sender, path), DBUSMENU)
        gen = self.gen[pid] = self.gen.get(pid, 0) + 1

        def current():
            return self.gen.get(pid) == gen and self.by_pid.get(pid) == win

        def root_failed(e):
            if not current():
                return
            log("fetch failed for pid", pid, e)
            self.drop(pid)

        def got_root(_revision, root):
            if not current():
                return
            tops = top_levels(root)
            menus = []

            def step(i):
                if not current():
                    return
                if i >= len(tops):
                    self.apply(pid, menus)
                    return
                tid, label, inline = tops[i]

                def got_kids(_rev, sub):
                    menus.append(menu_entry(tid, label, node(sub)[2] or inline))
                    step(i + 1)

                def kids_failed(e):
                    log("GetLayout(%d) failed:" % tid, e)
                    menus.append(menu_entry(tid, label, inline))
                    step(i + 1)

                def get_kids(*_reply):
                    menu.GetLayout(
                        tid,
                        1,
                        [],
                        timeout=CALL_TIMEOUT,
                        reply_handler=got_kids,
                        error_handler=kids_failed,
                    )

                # AboutToShow ONCE per menu: Qt fills a submenu in only when
                # asked, but answering also emits LayoutUpdated -- asking again
                # on every refetch is an endless fetch/signal loop. ponytail: a
                # menu that rebuilds itself on each open (recent files) therefore
                # shows its first contents; re-arm `shown` on menu open if that
                # ever matters. Its failure is not an error -- plenty of
                # exporters do not implement it -- so both handlers continue.
                key = (sender, path, tid)
                if key in self.shown:
                    get_kids()
                    return
                self.shown.add(key)
                menu.AboutToShow(
                    tid,
                    timeout=CALL_TIMEOUT,
                    reply_handler=get_kids,
                    error_handler=get_kids,
                )

            step(0)

        menu.GetLayout(
            0,
            1,
            [],
            timeout=CALL_TIMEOUT,
            reply_handler=got_root,
            error_handler=root_failed,
        )

    def apply(self, pid, menus):
        if self.menus.get(pid) == menus:
            return
        self.menus[pid] = menus
        self.publish({"event": "menus", "pid": pid, "menus": menus})

    def find_item(self, pid, ident):
        """A cached menu or row by dbusmenu id, or None if we do not hold it.

        item_at() resolves the shell's positional [menu, item] path instead;
        this one takes the id an ItemsPropertiesUpdated payload carries.
        """
        for m in self.menus.get(pid) or []:
            if m["id"] == ident:
                return m
            for it in m["items"]:
                if it.get("id") == ident:
                    return it
        return None

    def apply_props(self, pid, updated, removed):
        """Patch an ItemsPropertiesUpdated payload into the cache in place.

        Returns False when the payload touches anything the cache cannot express
        -- a removed property, an unknown id, a separator, or a key beyond the
        three the shell renders -- and the caller refetches instead.

        Refetching unconditionally is what made this signal dangerous: an app
        that updates Undo/Redo enablement on a timer (normal behaviour) drove a
        permanent cycle of round trips, invisible from the shell because the
        equality check in apply() suppresses the *publish*, not the *fetch*.
        """
        if removed or self.menus.get(pid) is None:
            return False
        dirty = False
        for entry in updated or []:
            try:
                ident, props = int(entry[0]), dict(entry[1])
            except (IndexError, TypeError, ValueError):
                return False
            if not {str(k) for k in props} <= PATCHABLE:
                return False
            item = self.find_item(pid, ident)
            if item is None or "separator" in item:
                return False
            if "label" in props:
                item["label"] = clean_label(props)
            # A top-level menu carries no shortcut or enabled state; writing one
            # would make the cache differ in shape from a fresh fetch and force a
            # spurious publish on the next one.
            if "items" not in item:
                if "shortcut" in props:
                    item["shortcut"] = shortcut(props)
                if "enabled" in props:
                    item["enabled"] = bool(props["enabled"])
            dirty = True
        if dirty:
            self.publish({"event": "menus", "pid": pid, "menus": self.menus[pid]})
        return True

    def pid_for(self, sender, path):
        for pid, cur in self.by_pid.items():
            if cur == (sender, path):
                return pid
        return None

    def on_items_properties_updated(self, updated, removed, **kw):
        pid = self.pid_for(kw.get("sender"), str(kw.get("path") or ""))
        if pid is None:
            self.discover(kw.get("sender"), str(kw.get("path") or ""))
        elif not self.apply_props(pid, updated, removed):
            self.schedule(pid)

    def on_layout_updated(self, *args, **kw):
        sender, path = kw.get("sender"), str(kw.get("path") or "")
        pid = self.pid_for(sender, path)
        if pid is None:
            self.discover(sender, path)
        else:
            self.schedule(pid)

    def discover(self, sender, path):
        # Nobody we know -- so discover it here. Qt on Wayland NEVER calls
        # RegisterWindow: the registrar's `u windowId` is an X11 XID, and the
        # Wayland path publishes the menu's (service, path) over the
        # org_kde_kwin_appmenu_manager protocol instead, which Hyprland does not
        # implement. Owning the registrar name is still what makes Qt export a
        # menu bar at all (QGenericUnixTheme only builds a QDBusMenuBar when the
        # name is on the bus), so the menu is there -- it is only the
        # announcement that never arrives. The burst of LayoutUpdated an app
        # emits while building the bar carries both halves we need.
        if path.startswith("/MenuBar"):
            self.adopt(sender, path, "discover")

    def schedule(self, pid):
        """Apps emit a burst of LayoutUpdated while building a menu; coalesce."""
        from gi.repository import GLib

        if pid in self.pending:
            GLib.source_remove(self.pending.pop(pid))

        def fire():
            self.pending.pop(pid, None)
            self.refresh(pid)
            return False

        self.pending[pid] = GLib.timeout_add(250, fire)

    def on_name_lost(self, name, old_owner, new_owner):
        for pid, (sender, _p) in list(self.by_pid.items()):
            if sender == name:
                log("gone pid=%d %s" % (pid, name))
                self.drop(pid)
        for wid, (sender, _p) in list(self.windows.items()):
            if sender == name:
                self.windows.pop(wid, None)

    # -- click ---------------------------------------------------------------

    def trigger(self, pid, item_id):
        win = self.by_pid.get(pid)
        if not win:
            log("trigger for unknown pid", pid)
            return
        menu = self.dbus.Interface(self.bus.get_object(*win), DBUSMENU)
        # Async: the handler may open a modal dialog and never return promptly.
        menu.Event(
            item_id,
            "clicked",
            self.dbus.String("", variant_level=1),
            self.dbus.UInt32(int(time.time())),
            reply_handler=lambda: None,
            error_handler=lambda e: log("Event failed:", e),
        )

    def item_at(self, pid, path):
        try:
            menu_i, item_i = int(path[0]), int(path[1])
            return self.menus[pid][menu_i]["items"][item_i].get("id")
        except (KeyError, IndexError, TypeError, ValueError):
            return None

    def on_message(self, msg):
        event = msg.get("event")
        if event == "registrar":
            self.set_registrar(bool(msg.get("enabled", True)))
            return
        if event != "trigger":
            return
        pid = int(msg.get("pid", 0))
        item_id = msg.get("id")
        if item_id is None:
            item_id = self.item_at(pid, msg.get("path") or [])
        if item_id is None:
            log("trigger without a resolvable item:", msg)
            return
        self.trigger(pid, int(item_id))

    # -- socket --------------------------------------------------------------

    def send(self, sock, line):
        # ponytail: blocking write. Lines are small and the only reader is the
        # shell; switch to a per-client queue if that ever stops holding.
        try:
            sock.sendall((json.dumps(line, separators=(",", ":")) + "\n").encode())
        except OSError:
            self.close_client(sock)

    def publish(self, line):
        for sock in list(self.clients):
            self.send(sock, line)

    def handle_line(self, line):
        """One socket line, and the guard that keeps the client alive.

        Broad on purpose: anything that escapes here escapes a GLib io watch,
        and PyGObject then removes that watch PERMANENTLY -- the daemon would
        stop reading this client forever while still publishing to it. A JSON
        line that parses to a non-object was enough, since msg.get() on it
        raises AttributeError, which the old (ValueError, KeyError) did not
        cover. A method rather than an inline try so the selftest can prove it.
        """
        if not line.strip():
            return
        try:
            self.on_message(json.loads(line))
        except Exception as e:
            log("bad line from shell:", repr(line[:200]), e)

    def close_client(self, sock):
        if sock in self.clients:
            self.clients.remove(sock)
        try:
            sock.close()
        except OSError:
            pass

    def listen(self, path):
        from gi.repository import GLib

        try:
            os.unlink(path)  # the bus name, acquired first, is the real lock
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
        os.chmod(path, 0o600)
        srv.listen(8)
        srv.setblocking(False)
        self.server = srv
        GLib.io_add_watch(srv.fileno(), GLib.PRIORITY_DEFAULT, GLib.IO_IN, self.accept)
        log("listening on", path)

    def accept(self, _fd, _cond):
        from gi.repository import GLib

        sock, _ = self.server.accept()
        sock.setblocking(True)
        self.clients.append(sock)
        buf = bytearray()

        def readable(_f, cond):
            if cond & (GLib.IO_HUP | GLib.IO_ERR):
                self.close_client(sock)
                return False
            try:
                chunk = sock.recv(65536)
            except OSError:
                chunk = b""
            if not chunk:
                self.close_client(sock)
                return False
            buf.extend(chunk)
            while b"\n" in buf:
                line, _, rest = bytes(buf).partition(b"\n")
                buf[:] = rest
                self.handle_line(line)
            return True

        GLib.io_add_watch(
            sock.fileno(),
            GLib.PRIORITY_DEFAULT,
            GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR,
            readable,
        )
        for pid, menus in self.menus.items():
            self.send(sock, {"event": "menus", "pid": pid, "menus": menus})
        log("shell connected (%d client(s))" % len(self.clients))
        return True


def make_object(daemon, conn):
    """Export the registrar interface on `conn` (a connection, not a BusName --
    see Daemon.acquire)."""
    import dbus.service

    class RegistrarObject(dbus.service.Object):
        @dbus.service.method(REGISTRAR, in_signature="uo", sender_keyword="sender")
        def RegisterWindow(self, windowId, menuObjectPath, sender=None):
            daemon.register(int(windowId), str(menuObjectPath), sender)
            self.WindowRegistered(windowId, sender, menuObjectPath)

        @dbus.service.method(REGISTRAR, in_signature="u")
        def UnregisterWindow(self, windowId):
            daemon.unregister(int(windowId))
            self.WindowUnregistered(windowId)

        @dbus.service.method(REGISTRAR, in_signature="u", out_signature="so")
        def GetMenuForWindow(self, windowId):
            sender, path = daemon.windows.get(int(windowId), ("", "/"))
            return (sender, dbus.ObjectPath(path))

        @dbus.service.method(REGISTRAR, out_signature="a(uso)")
        def GetMenus(self):
            return [
                (dbus.UInt32(wid), sender, dbus.ObjectPath(path))
                for wid, (sender, path) in daemon.windows.items()
            ]

        @dbus.service.signal(REGISTRAR, signature="uso")
        def WindowRegistered(self, windowId, service, menuObjectPath):
            pass

        @dbus.service.signal(REGISTRAR, signature="u")
        def WindowUnregistered(self, windowId):
            pass

    return RegistrarObject(conn, REGISTRAR_PATH)


def watch_compositor(loop, GLib):
    """Leave when the compositor that started us does.

    conf/autostart.lua launches this from hyprland's exec-once with `&`, so it
    is reparented rather than killed when the compositor exits. Everything else
    started there is a wayland client and dies on its own; this daemon holds no
    wayland connection, so nothing reaps it.

    That is not merely untidy. The surviving process keeps session-N.scope
    alive, so logind leaves the session `closing` while it still owns its VT,
    and the next login lands a second session on the same VT -- two compositors
    contending for one display, which presents as a frozen screen. Poll for the
    compositor's socket and quit when it goes.
    """
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    display = os.environ.get("WAYLAND_DISPLAY")
    if not runtime or not display:
        log("no wayland session to watch; not arming the compositor watchdog")
        return
    sock = display if os.path.isabs(display) else os.path.join(runtime, display)

    def check():
        if os.path.exists(sock):
            return True
        log("compositor socket %s is gone, exiting" % sock)
        loop.quit()
        return False

    GLib.timeout_add_seconds(5, check)


def run(dump_seconds=None, sock_path=SOCK_PATH):
    import dbus
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib

    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()

    loop = GLib.MainLoop()
    daemon = Daemon(bus)
    # scan() inside acquire() is queued here and answered once the loop runs.
    if not daemon.acquire():
        return 1

    def quit_loop():
        loop.quit()
        return False

    if dump_seconds is None:
        daemon.listen(sock_path)
        GLib.unix_signal_add(GLib.PRIORITY_HIGH, 2, quit_loop)  # SIGINT
        GLib.unix_signal_add(GLib.PRIORITY_HIGH, 15, quit_loop)  # SIGTERM
        watch_compositor(loop, GLib)
    else:
        log("collecting registrations for %ds" % dump_seconds)
        GLib.timeout_add_seconds(dump_seconds, lambda: (loop.quit(), False)[1])

    try:
        loop.run()
    except KeyboardInterrupt:
        pass

    if dump_seconds is not None:
        print(
            json.dumps(
                [
                    {"pid": pid, "menus": menus}
                    for pid, menus in sorted(daemon.menus.items())
                ],
                indent=2,
            )
        )
    else:
        try:
            os.unlink(sock_path)
        except OSError:
            pass
    return 0


# --------------------------------------------------------------------------


def selftest():
    """Layout parsing, offline. Structures are shaped exactly as dbusmenu sends."""
    root = (
        0,
        {"children-display": "submenu"},
        [
            (1, {"label": "_File", "children-display": "submenu"}, []),
            (9, {"label": "Hidden", "visible": False}, []),
            (2, {"label": "Ed_it", "children-display": "submenu"}, []),
        ],
    )
    kids = {
        1: [
            (11, {"label": "_New Window", "shortcut": [["Control", "n"]]}, []),
            (12, {"type": "separator"}, []),
            (13, {"label": "_Quit", "shortcut": [["Control", "Q"]], "enabled": False}, []),
            (14, {"label": "Never", "visible": False}, []),
        ],
        2: [(21, {"label": "Undo", "shortcut": [["Control", "Shift", "z"]]}, [])],
    }
    menus = build_menus(root, kids.get)
    assert [m["label"] for m in menus] == ["File", "Edit"], menus
    file_items = menus[0]["items"]
    assert len(file_items) == 3, file_items
    assert file_items[0] == {
        "id": 11,
        "label": "New Window",
        "shortcut": "Ctrl+N",
        "enabled": True,
        "submenu": False,
    }, file_items[0]
    assert file_items[1] == {"separator": True}
    assert file_items[2]["enabled"] is False and file_items[2]["shortcut"] == "Ctrl+Q"
    assert menus[1]["items"][0]["shortcut"] == "Ctrl+Shift+Z"
    # No children reported for a menu -> the inline layout is used instead.
    assert build_menus(root, lambda _i: [])[0]["items"] == []
    assert clean_label({"label": "Save _As"}) == "Save As"
    # dbusmenu's own escape: '__' is a literal underscore, not two markers.
    assert clean_label({"label": "Save __As"}) == "Save _As"
    assert clean_label({"label": "a__b"}) == "a_b"
    assert shortcut({}) == "" and shortcut({"shortcut": []}) == ""
    assert shortcut({"shortcut": [["Alt", "Left"]]}) == "Alt+Left"

    # /MenuBar discovery -- the Wayland path, where RegisterWindow never comes
    assert menubar_children(
        '<node name="/MenuBar"><node name="1"/><node name="2"/></node>'
    ) == ["/MenuBar/1", "/MenuBar/2"]
    assert menubar_children("<node/>") == []

    # trigger path resolution, the other half of the shell contract
    d = Daemon.__new__(Daemon)
    d.menus = {42: menus}
    assert d.item_at(42, [0, 0]) == 11
    assert d.item_at(42, [0, 1]) is None  # separator carries no id
    assert d.item_at(42, [5, 0]) is None and d.item_at(7, [0, 0]) is None

    # -- ItemsPropertiesUpdated applied in place, instead of refetching --------
    published = []
    d.publish = published.append
    assert d.find_item(42, 11)["label"] == "New Window"
    assert d.find_item(42, 1)["label"] == "File"  # a top-level menu
    assert d.find_item(42, 999) is None

    # The 4Hz case: an app toggling enablement. Applied, published, no refetch.
    assert d.apply_props(42, [(11, {"enabled": False})], []) is True
    assert d.find_item(42, 11)["enabled"] is False
    assert len(published) == 1 and published[0]["event"] == "menus"
    assert d.apply_props(42, [(11, {"label": "New _Window"})], []) is True
    assert d.find_item(42, 11)["label"] == "New Window"
    # A top-level menu takes a label and nothing else -- writing enabled there
    # would make the cache differ in shape from a fresh fetch.
    assert d.apply_props(42, [(1, {"enabled": False})], []) is True
    assert "enabled" not in d.find_item(42, 1)

    # Everything the cache cannot express falls back to a refetch (False).
    assert d.apply_props(42, [(11, {"visible": False})], []) is False
    assert d.apply_props(42, [(999, {"enabled": True})], []) is False
    assert d.apply_props(42, [(12, {"enabled": True})], []) is False  # separator
    assert d.apply_props(42, [], [(11, ["enabled"])]) is False  # a removal
    assert d.apply_props(7, [(11, {"enabled": True})], []) is False  # unknown pid
    assert d.apply_props(42, ["nonsense"], []) is False

    # -- the global-menu switch, dispatched off the same socket ---------------
    # Ownership itself needs a bus; what is checkable offline is that the line
    # reaches set_registrar with the right answer, and that a malformed one
    # defaults to on rather than silently killing the menus.
    switched = []
    d.set_registrar = switched.append
    for line, want in [
        (b'{"event":"registrar","enabled":false}', False),
        (b'{"event":"registrar","enabled":true}', True),
        (b'{"event":"registrar"}', True),
    ]:
        d.handle_line(line)
        assert switched[-1] is want, (line, switched)
    assert len(switched) == 3
    d.handle_line(b'{"event":"menus","pid":42}')
    assert len(switched) == 3  # only "registrar" flips it
    del d.set_registrar

    # -- malformed socket lines must not escape the GLib io watch -------------
    # handle_line() IS the guard the io watch runs, so this is the real check:
    # anything it lets through kills that watch permanently. A line parsing to a
    # non-object raises AttributeError out of on_message, which the old
    # (ValueError, KeyError) did not cover.
    for bad in [b"[]", b'"str"', b"3", b"null", b'{"event":"trigger"}', b"{}",
                b"not json at all", b"", b"   ", b'{"event":"trigger","pid":"x"}',
                b'{"event":"trigger","pid":1,"path":"nope"}']:
        assert d.handle_line(bad) is None, bad
    print("selftest ok")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--dump",
        nargs="?",
        type=int,
        const=5,
        metavar="SECONDS",
        help="collect registrations for SECONDS (default 5), print them as JSON, exit",
    )
    ap.add_argument("--socket", default=SOCK_PATH, help="unix socket path")
    ap.add_argument("--selftest", action="store_true", help="run offline parser checks")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    return run(dump_seconds=args.dump, sock_path=args.socket)


if __name__ == "__main__":
    sys.exit(main())
