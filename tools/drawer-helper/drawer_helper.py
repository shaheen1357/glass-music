#!/usr/bin/env python3
"""Cash-drawer kick relay for Coccinelle POS tills.

The POS runs in a browser, which cannot send raw bytes to the receipt printer.
This tiny native service bridges that gap: the "Open Drawer" button POSTs to
http://localhost:9110/kick and this process sends the ESC/POS drawer-kick
(1B 70 00 19 FA) to the printer -- opening the drawer with no paper.

Runs as a plain script (Python installed) or as a PyInstaller .exe / NSSM
service. Reads config.ini sitting next to the script/exe; env vars override.

config.ini:
    [printer]
    ip   = 192.168.1.50     ; Ethernet printer -> kick over TCP 9100 (no deps)
    port = 9100
    name =                  ; OR a Windows printer name -> RAW via pywin32 (USB)
    [server]
    listen_port = 9110
    [log]
    file = drawer_helper.log

Stdlib only unless the USB (printer name) path is used.
"""
import os
import sys
import socket
import logging
from configparser import ConfigParser
from logging.handlers import RotatingFileHandler
from http.server import BaseHTTPRequestHandler, HTTPServer

# ESC p m t1 t2 -- pin 2, on 25ms, off 250ms. Standard cash-drawer kick.
KICK = bytes([0x1B, 0x70, 0x00, 0x19, 0xFA])


def base_dir():
    """Folder of the .exe when frozen, else of this script."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


BASE = base_dir()


def load_config():
    cfg = ConfigParser()
    cfg.read(os.path.join(BASE, "config.ini"))

    def g(section, key, default=""):
        return (cfg.get(section, key, fallback=default) or "").strip()

    return {
        "ip": g("printer", "ip") or os.environ.get("PRINTER_IP", ""),
        "port": int(g("printer", "port", "9100") or 9100),
        "name": g("printer", "name") or os.environ.get("PRINTER_NAME", ""),
        "listen_port": int(g("server", "listen_port", "9110")
                           or os.environ.get("LISTEN_PORT", "9110")),
        "log_file": g("log", "file", "drawer_helper.log"),
    }


CFG = load_config()

logger = logging.getLogger("drawer_helper")
logger.setLevel(logging.INFO)
_fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
try:
    _fh = RotatingFileHandler(os.path.join(BASE, CFG["log_file"]),
                              maxBytes=512 * 1024, backupCount=3)
    _fh.setFormatter(_fmt)
    logger.addHandler(_fh)
except Exception:  # noqa: BLE001 -- a read-only dir must not stop the service
    pass
_ch = logging.StreamHandler()
_ch.setFormatter(_fmt)
logger.addHandler(_ch)


def send_kick():
    """Deliver the kick over whichever transport is configured."""
    if CFG["ip"]:
        with socket.create_connection((CFG["ip"], CFG["port"]), timeout=5) as s:
            s.sendall(KICK)
        return "tcp %s:%d" % (CFG["ip"], CFG["port"])
    if CFG["name"]:
        import win32print  # pip install pywin32
        h = win32print.OpenPrinter(CFG["name"])
        try:
            win32print.StartDocPrinter(h, 1, ("DrawerKick", None, "RAW"))
            win32print.StartPagePrinter(h)
            win32print.WritePrinter(h, KICK)
            win32print.EndPagePrinter(h)
            win32print.EndDocPrinter(h)
        finally:
            win32print.ClosePrinter(h)
        return "raw %s" % CFG["name"]
    raise RuntimeError("No printer configured: set [printer] ip or name in config.ini")


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        # Allow the call from the (HTTPS in production) Odoo page. The
        # Private-Network header satisfies Chrome's Private Network Access for
        # a public page reaching localhost.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Private-Network", "true")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def _kick(self):
        try:
            where = send_kick()
            logger.info("kick OK via %s", where)
            body = ("OK via %s\n" % where).encode()
            self.send_response(200)
        except Exception as e:  # noqa: BLE001
            logger.error("kick FAILED: %s", e)
            body = ("ERR %s\n" % e).encode()
            self.send_response(500)
        self._cors()
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path.rstrip("/") == "/kick":
            self._kick()
        else:
            self.send_response(404)
            self._cors()
            self.end_headers()

    def do_GET(self):
        if self.path.rstrip("/") == "/kick":
            self._kick()
        else:
            self.send_response(200)
            self._cors()
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"drawer_helper alive\n")

    def log_message(self, *args):  # silence default stderr access log
        pass


def main():
    logger.info("drawer_helper starting on http://localhost:%d (ip=%r name=%r)",
                CFG["listen_port"], CFG["ip"], CFG["name"])
    try:
        HTTPServer(("127.0.0.1", CFG["listen_port"]), Handler).serve_forever()
    except Exception as e:  # noqa: BLE001
        logger.error("server stopped: %s", e)
        raise


if __name__ == "__main__":
    main()
