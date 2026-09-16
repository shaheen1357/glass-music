# Cash-drawer helper

The POS till runs in a browser, which cannot send raw bytes to the receipt
printer. `drawer_helper.py` is a tiny native service that does it for the till:
the **Open Drawer** button (receipt screen) POSTs to `http://localhost:9110/kick`
and the helper sends the ESC/POS drawer-kick (`1B 70 00 19 FA`) to the printer —
opening the drawer with **no paper**.

One helper runs per till PC. `localhost` is the point: an Odoo.sh (HTTPS) page is
allowed to call `http://localhost`, but would be blocked calling a LAN IP.

## Configure (`config.ini`, next to the script/exe)

Set **one** transport:

```ini
[printer]
ip   = 192.168.1.50     ; Ethernet printer -> TCP 9100 (recommended; no drivers)
port = 9100
name =                  ; OR a Windows printer name -> RAW via pywin32 (USB)
[server]
listen_port = 9110      ; must match HELPER_URL in ../static/src/drawer_buttons.js
```

> For a **service**, prefer the **Ethernet (ip)** path — a Windows service often
> can't see a user-installed USB printer, and TCP works from any account.

Env vars (`PRINTER_IP`, `PRINTER_NAME`, `PRINTER_PORT`, `LISTEN_PORT`) override
`config.ini` if you'd rather not edit the file.

---

## Level 1 — run as a script (Python on the till)

```
python drawer_helper.py
```
Test:  `curl http://localhost:9110/kick`  → drawer opens.

## Level 2 — build a standalone .exe (no Python on the tills)

PyInstaller can't cross-compile, so **run this on a Windows machine** with Python:

```
build.bat
```
Produces `dist\drawer_helper.exe` + `dist\config.ini`. Ship that `dist\` folder
to each till and edit `config.ini` there for the till's printer.

## Level 3 — install as an auto-start service (NSSM)

On each till, in the folder holding `drawer_helper.exe`, `config.ini`, and
`nssm.exe` (download from https://nssm.cc), **as Administrator**:

```
install_service.bat        REM installs + starts service "CoccinelleDrawer"
```
It prompts you to set `config.ini` first, then auto-starts on every boot. Logs:
`drawer_helper.log` (rotating) plus `service.out.log` / `service.err.log`.
Remove with `uninstall_service.bat`.

---

## Files

| File | Purpose |
|------|---------|
| `drawer_helper.py` | the service (config + rotating log) |
| `config.ini` | per-till printer settings |
| `requirements.txt` | build/runtime deps (pyinstaller, pywin32) |
| `build.bat` | build the .exe (Windows) |
| `install_service.bat` / `uninstall_service.bat` | NSSM service (Windows, admin) |

## Notes
- The helper only ever sends the 5-byte kick — it never prints or reads anything.
- Chrome's Private Network Access preflight is handled
  (`Access-Control-Allow-Private-Network: true`).
- If the button does nothing, check the till browser console for a
  `[sdm-drawer] FAIL: …` line, and the helper's `drawer_helper.log`.
