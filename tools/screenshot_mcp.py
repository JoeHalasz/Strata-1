#!/usr/bin/env python3
"""tools/screenshot_mcp.py - an MCP server that takes screenshots of this PC.

    claude mcp add screenshot -- python /path/to/Strata/tools/screenshot_mcp.py

Two tools: take_screenshot (whole desktop, one monitor, or a region -> a PNG under screenshots\\
plus the picture itself) and list_displays (what monitors there are).  It speaks MCP (JSON-RPC 2.0,
one message per line) over stdin/stdout, uses the Python standard library only (Python 3.10 or
newer), and needs no daemon, no Docker and no network: on Windows the capture is PowerShell's
[System.Drawing.Graphics]::CopyFromScreen, on Linux grim / spectacle / gnome-screenshot / scrot /
ImageMagick's import, whichever is installed, on macOS screencapture.

Strata starts it itself: launcher\\make_configs.py puts it in every generated config under
"mcp_servers", so the chat page gets screenshot__take_screenshot.  Add it to opencode.json under
"mcp.servers" (this repo's copy has it) for OpenCode, or to Claude Code / Cursor / VS Code with the
line above.

Check it works without any MCP client:

    .venv\\Scripts\\python.exe tools\\screenshot_mcp.py --selftest   # takes one shot, prints the path

Privacy: a screenshot is the whole screen - passwords, e-mail, anything visible.  The PNGs land in
screenshots\\ (git-ignored); delete them when you are done.
"""
from __future__ import annotations

import base64
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path

PROTOCOL = "2025-06-18"
PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")
VERSION = "0.1.0"
WIN = os.name == "nt"
ROOT = Path(__file__).resolve().parent.parent
SHOT_DIR = ROOT / "screenshots"
MAX_DELAY_S = 10.0

INSTRUCTIONS = ("take_screenshot captures this PC's screen(s) to a PNG and returns it.  "
                "list_displays says what monitors exist and where.  A screenshot shows everything "
                "on screen - treat what you see as private.")


def log(msg: str) -> None:
    print(f"screenshot-mcp: {msg}", file=sys.stderr, flush=True)


class ToolError(Exception):
    """A problem the model can read and react to."""


# ---------------------------------------------------------------- the capture backends
def png_size(path: Path) -> tuple[int, int]:
    """A PNG's width and height from its IHDR header (bytes 16..24, big-endian)."""
    with path.open("rb") as f:
        head = f.read(24)
    if len(head) < 24 or not head.startswith(b"\x89PNG\r\n\x1a\n") or head[12:16] != b"IHDR":
        raise ToolError(f"{path} is not a PNG the capture could write")
    w, h = struct.unpack(">II", head[16:24])
    return w, h


# PowerShell: DPI-aware so the bounds and the pixels agree, then CopyFromScreen into a PNG.
# The region comes in through environment variables - no quoting of paths or numbers.
_PS_DPI = ('Add-Type -MemberDefinition \'[System.Runtime.InteropServices.DllImport("user32.dll")] '
           'public static extern bool SetProcessDPIAware();\' -Name U32 -Namespace Strata | Out-Null; '
           '[void][Strata.U32]::SetProcessDPIAware();')
_PS_CAPTURE = ('$ErrorActionPreference = "Stop"; '
               'Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; '
               + _PS_DPI +
               '$bmp = New-Object System.Drawing.Bitmap([int]$env:SX_W, [int]$env:SX_H); '
               '$g = [System.Drawing.Graphics]::FromImage($bmp); '
               '$g.CopyFromScreen([int]$env:SX_X, [int]$env:SX_Y, 0, 0, $bmp.Size); '
               '$bmp.Save($env:SX_OUT, [System.Drawing.Imaging.ImageFormat]::Png); '
               '$g.Dispose(); $bmp.Dispose();')
_PS_DISPLAYS = ('$ErrorActionPreference = "Stop"; Add-Type -AssemblyName System.Windows.Forms; '
                + _PS_DPI +
                '[System.Windows.Forms.Screen]::AllScreens | ForEach-Object { [PSCustomObject]@{ '
                'name = $_.DeviceName; x = $_.Bounds.X; y = $_.Bounds.Y; width = $_.Bounds.Width; '
                'height = $_.Bounds.Height; primary = $_.Primary } } | ConvertTo-Json -Compress;')


def run(cmd: list[str], env: dict | None = None) -> str:
    """Run a capture command; its stderr is the error we show if it fails."""
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=30, env=env)
    except FileNotFoundError:
        raise ToolError(f"{cmd[0]!r} is not installed") from None
    except subprocess.TimeoutExpired:
        raise ToolError(f"{cmd[0]} did not finish within 30 s") from None
    if p.returncode:
        err = (p.stderr.decode("utf-8", "replace") or p.stdout.decode("utf-8", "replace")).strip()
        raise ToolError(f"{cmd[0]} exited {p.returncode}" + (f": {err}" if err else ""))
    return p.stdout.decode("utf-8", "replace")


def capture_windows(out: Path, x: int, y: int, w: int, h: int) -> None:
    env = dict(os.environ, SX_X=str(x), SX_Y=str(y), SX_W=str(w), SX_H=str(h), SX_OUT=str(out))
    run(["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
         "-Command", _PS_CAPTURE], env=env)


def capture_linux(out: Path, x: int, y: int, w: int, h: int) -> None:
    """The first screen-grab tool that exists here does the job; region support varies, so the
    region is only passed to the tools that take one."""
    region = (w, h, x, y)
    wayland = bool(os.environ.get("WAYLAND_DISPLAY"))
    if wayland and shutil.which("grim"):
        geom = f"-g={w}x{h}+{x}+{y}" if (w, h) != (0, 0) else "-"
        run(["grim", geom, str(out)])
        return
    for exe, args in (("spectacle", ["-b", "-n", str(out)]),                      # KDE (region: -r)
                      ("gnome-screenshot", ["-f", str(out)]),                     # GNOME
                      ("scrot", str(out)),                                        # any X11
                      ("import", ["-window", "root", str(out)])):                 # ImageMagick
        if shutil.which(exe):
            if exe == "gnome-screenshot" and region:
                args = ["-a", f"{x},{y},{w},{h}", "-f", str(out)]
            elif exe == "scrot" and region:
                args = ["-a", f"{x},{y},{w},{h}", str(out)]
            run([exe, *args])
            return
    raise ToolError("no screenshot tool found (tried grim, spectacle, gnome-screenshot, scrot, "
                    "import); install one, e.g. sudo apt install grim or scrot")


def capture_mac(out: Path, x: int, y: int, w: int, h: int) -> None:
    args = ["screencapture", "-x"]
    if (w, h, x, y):
        args += ["-R", f"{x},{y},{w},{h}"]
    args.append(str(out))
    run(args)


def displays() -> list[dict]:
    """The monitors: name, position and size in pixels, and which is primary."""
    if WIN:
        out = run(["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                   "-Command", _PS_DISPLAYS])
        try:
            got = json.loads(out.strip() or "[]")
        except ValueError:
            raise ToolError("PowerShell did not answer with the display list") from None
        return got if isinstance(got, list) else [got]
    if sys.platform == "darwin":
        out = subprocess.run(["system_profiler", "SPDisplaysDataType", "-json"],
                             capture_output=True, timeout=30).stdout.decode()
        try:
            cards = json.loads(out).get("SPDisplaysDataType", [])
            return [{"name": d.get("_name", "display"), "x": 0, "y": 0,
                     "width": 0, "height": 0, "primary": i == 0,
                     "resolution": (d.get("spdisplays_resolution") or "").split(" x ")[0:2]}
                    for i, card in enumerate(cards) for d in card.get("spdisplays_ndrvs", [])]
        except ValueError:
            return []
    try:                                                # X11: xrandr's "connected ... 1920x1080+0+0" line
        out = subprocess.run(["xrandr"], capture_output=True, timeout=10).stdout.decode()
        got = []
        for line in out.splitlines():
            if " connected" not in line:
                continue
            name, tail = line.split(" connected", 1)[0], line.split(" connected", 1)[1]
            tok = re.search(r"(\d+)x(\d+)\+(-?\d+)\+(-?\d+)", tail)
            if not tok:
                continue
            w, h, x, y = (int(v) for v in tok.groups())
            got.append({"name": name, "x": x, "y": y, "width": w, "height": h,
                        "primary": " primary" in tail.split("+")[0]})
        return got
    except FileNotFoundError:
        return []


def virtual_bounds(disp: list[dict]) -> tuple[int, int, int, int]:
    """The box around every monitor - the whole desktop, gaps between monitors included."""
    if not disp:
        raise ToolError("no displays found")
    x0 = min(d["x"] for d in disp)
    y0 = min(d["y"] for d in disp)
    x1 = max(d["x"] + d["width"] for d in disp)
    y1 = max(d["y"] + d["height"] for d in disp)
    return x0, y0, x1 - x0, y1 - y0


# ---------------------------------------------------------------- the tools
def tool_list_displays(args: dict) -> dict:
    disp = displays()
    return {"displays": disp,
            "desktop": dict(zip(("x", "y", "width", "height"), virtual_bounds(disp))),
            "note": "monitor numbers for take_screenshot are 1-based, in this order"}


def tool_take_screenshot(args: dict) -> dict:
    for key in ("x", "y", "width", "height", "monitor"):
        if key in args and not isinstance(args[key], int):
            raise ToolError(f"{key} must be a whole number of pixels")
    delay = float(args.get("delay_s") or 0)
    if not 0 <= delay <= MAX_DELAY_S:
        raise ToolError(f"delay_s must be between 0 and {MAX_DELAY_S:g}")
    if delay:
        time.sleep(delay)

    region = None
    if all(k in args for k in ("x", "y", "width", "height")):
        region = (args["x"], args["y"], args["width"], args["height"])
        if region[2] <= 0 or region[3] <= 0:
            raise ToolError("width and height must be positive")
    elif any(k in args for k in ("x", "y", "width", "height")):
        raise ToolError("a region needs all of x, y, width and height")

    disp = displays()
    if region is None:
        monitor = int(args.get("monitor") or 0)
        if monitor:
            if not 1 <= monitor <= len(disp):
                raise ToolError(f"monitor must be 1-{len(disp)} (see list_displays)")
            d = disp[monitor - 1]
            region = (d["x"], d["y"], d["width"], d["height"])
        else:
            region = virtual_bounds(disp)
    x, y, w, h = region

    out = args.get("path")
    out = Path(out) if out else SHOT_DIR / f"screenshot-{time.strftime('%Y%m%d-%H%M%S')}.png"
    if not out.is_absolute():
        out = ROOT / out
    if out.suffix.lower() != ".png":
        raise ToolError("path must end in .png")
    out.parent.mkdir(parents=True, exist_ok=True)

    if WIN:
        capture_windows(out, x, y, w, h)
    elif sys.platform == "darwin":
        capture_mac(out, x, y, w, h)
    else:
        capture_linux(out, x, y, w, h)
    if not out.exists() or out.stat().st_size == 0:
        raise ToolError("the capture tool reported success but wrote no file")
    pw, ph = png_size(out)
    return {"path": str(out), "width": pw, "height": ph, "bytes": out.stat().st_size,
            "region": {"x": x, "y": y, "width": w, "height": h},
            "displays": disp,
            "note": "the cursor itself is not captured; the picture is also returned as an image"}


TOOLS = {
    "take_screenshot": (
        {"name": "take_screenshot",
         "description": "Screenshot this PC's screen to a PNG file and return the picture. "
                        "No arguments = the whole desktop (all monitors). monitor = one monitor "
                        "(1-based, from list_displays); or give x, y, width, height for a region "
                        "in desktop pixels. delay_s waits before capturing (for a menu or a "
                        "window that needs a moment). path = where to save (default "
                        "screenshots/screenshot-<time>.png under the Strata folder).",
         "inputSchema": {"type": "object", "properties": {
             "monitor": {"type": "integer", "description": "1-based monitor number, 0 = all"},
             "x": {"type": "integer"}, "y": {"type": "integer"},
             "width": {"type": "integer"}, "height": {"type": "integer"},
             "delay_s": {"type": "number", "description": "wait this many seconds first (0-10)"},
             "path": {"type": "string", "description": "save file, .png"}},
             "additionalProperties": False}},
        tool_take_screenshot),
    "list_displays": (
        {"name": "list_displays",
         "description": "List this PC's monitors: name, position and size in pixels, and which "
                        "is primary, plus the box around the whole desktop.",
         "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
        tool_list_displays),
}


# ---------------------------------------------------------------- the MCP server
class McpServer:
    """JSON-RPC 2.0, one message per line on stdin/stdout - the same shape as tools/strata_mcp.py."""

    def __init__(self):
        self.out = sys.stdout.buffer
        self.write_lock = threading.Lock()
        self.protocol = PROTOCOL

    def send(self, msg: dict) -> None:
        data = (json.dumps(msg, ensure_ascii=False) + "\n").encode("utf-8")
        with self.write_lock:
            self.out.write(data)
            self.out.flush()

    @staticmethod
    def result(rid, result):
        return {"jsonrpc": "2.0", "id": rid, "result": result}

    @staticmethod
    def error(rid, code, message):
        return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}

    def handle(self, msg) -> dict | None:
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0":
            return self.error(msg.get("id") if isinstance(msg, dict) else None, -32600, "invalid request")
        if "method" not in msg:
            return None
        method, rid, params = msg["method"], msg.get("id"), msg.get("params") or {}
        if "id" not in msg:
            return None                                     # notifications: nothing to say
        if not isinstance(params, dict):
            return self.error(rid, -32602, "params must be an object")
        if method == "initialize":
            asked = str(params.get("protocolVersion") or PROTOCOL)
            self.protocol = asked if asked in PROTOCOLS else PROTOCOL
            return self.result(rid, {"protocolVersion": self.protocol,
                                     "capabilities": {"tools": {"listChanged": False}},
                                     "serverInfo": {"name": "screenshot", "title": "Screenshots",
                                                    "version": VERSION},
                                     "instructions": INSTRUCTIONS})
        if method == "ping":
            return self.result(rid, {})
        if method == "tools/list":
            return self.result(rid, {"tools": [t[0] for t in TOOLS.values()]})
        if method == "tools/call":
            name = params.get("name")
            if name not in TOOLS:
                return self.error(rid, -32602, f"unknown tool: {name}")
            args = params.get("arguments") or {}
            if not isinstance(args, dict):
                return self.error(rid, -32602, "arguments must be an object")
            try:
                res = TOOLS[name][1](args)
                return self.result(rid, self.content(res, error=False))
            except ToolError as e:
                return self.result(rid, self.content({"error": str(e)}, error=True))
            except Exception as e:                          # noqa: BLE001 - a bug must not end the server
                log("tool failed:\n" + traceback.format_exc())
                return self.result(rid, self.content({"error": f"internal error in {name}: {e}"},
                                                     error=True))
        if method in ("resources/list", "prompts/list"):
            return self.result(rid, {method.split("/")[0]: []})
        return self.error(rid, -32601, f"method not found: {method}")

    def content(self, res: dict, error: bool) -> dict:
        """Text the model reads, plus the PNG itself for clients that show pictures (Strata's chat
        page keeps the text and names the image; OpenCode shows the image)."""
        out = {"content": [{"type": "text", "text": json.dumps(res, indent=1, ensure_ascii=False)}],
               "isError": error}
        if not error and "path" in res:
            try:
                data = base64.b64encode(Path(res["path"]).read_bytes()).decode()
                out["content"].append({"type": "image", "data": data, "mimeType": "image/png"})
            except OSError:
                pass                                        # the text result already says the path
        if self.protocol >= "2025-06-18":
            out["structuredContent"] = res
        return out

    def serve(self, inp) -> None:
        for raw in inp:
            line = raw.decode("utf-8", "replace").strip() if isinstance(raw, bytes) else raw.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                self.send(self.error(None, -32700, "parse error"))
                continue
            if isinstance(msg, list) or (isinstance(msg, dict) and msg.get("method") == "tools/call"):
                threading.Thread(target=self._run, args=(msg,), daemon=True).start()
            else:
                self._run(msg)

    def _run(self, msg) -> None:
        if isinstance(msg, list):
            out = [r for r in (self.handle(m) for m in msg) if r is not None]
            if out:
                data = (json.dumps(out, ensure_ascii=False) + "\n").encode("utf-8")
                with self.write_lock:
                    self.out.write(data)
                    self.out.flush()
            return
        r = self.handle(msg)
        if r is not None:
            self.send(r)


def selftest() -> int:
    """Take one screenshot and print where it went - no MCP client needed."""
    res = tool_take_screenshot({"path": sys.argv[2]} if len(sys.argv) > 2 else {})
    shown = ", ".join("{} {}x{}".format(d["name"], d["width"], d["height"]) for d in res["displays"])
    print(f"  displays: {shown}")
    print(f"  wrote {res['path']}  {res['width']}x{res['height']}  {res['bytes']:,} bytes")
    return 0


def main(argv=None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    if "--selftest" in argv:
        try:
            return selftest()
        except ToolError as e:
            print(f"  [X] {e}", file=sys.stderr)
            return 1
    if "--version" in argv:
        print(f"screenshot-mcp {VERSION}  (python {sys.version.split()[0]}, "
              f"{'windows' if WIN else sys.platform})")
        return 0
    log(f"serving on stdin/stdout; screenshots to {SHOT_DIR}")
    server = McpServer()
    server.serve(sys.stdin.buffer)
    return 0


if __name__ == "__main__":
    sys.exit(main())
