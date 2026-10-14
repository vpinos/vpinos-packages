#!/usr/bin/env python3
# Debugging snapshot tool: VPinOS version, video driver (mode + the GPU(s)
# actually detected, VRAM, kernel driver in use), display info (from
# Hyprland), CPU and memory. Gathers everything first and always writes a
# fresh, timestamped text file to the vpinos home dir -- before ever
# touching a display -- so it's still useful run headless over SSH when
# that's exactly the kind of thing being debugged; showing it fullscreen on
# screen (same content, same order) is attempted afterward, best-effort.
#
# Run as a vpinos-launch "sysinfo" client, same pattern as vpinos-config
# (`vpinos-launch shell ...`) -- Hyprland needs to already be up with
# WAYLAND_DISPLAY set, which vpinos-launch's own launch_client() handles; this
# script doesn't start Hyprland itself:
#   /usr/bin/vpinos-launch sysinfo /usr/libexec/vpinos/vpinos_sysinfo.py
#
# Tkinter (via python3-tk), same as vpinos-config and for the same
# reason: it has no native Wayland backend in trixie's version, so it needs
# Xwayland's DISPLAY, discovered the same way (ensure_display() below is
# copied from that file almost verbatim -- same problem, same fix).
import glob
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime

HOME = os.path.expanduser("~")
OS_RELEASE = "/etc/os-release"
GPU_DRIVER_FILE = "/etc/vpinos/gpu-driver"
GPU_CLASSES = ("VGA compatible controller", "3D controller", "Display controller")


# ---- Hyprland/Xwayland plumbing -- copied from vpinos-config, same
# reasoning: hyprctl needs HYPRLAND_INSTANCE_SIGNATURE, which vpinos-launch's
# generic client path never sets (it only knows plain Wayland), and
# tkinter needs an X11 DISPLAY that only Hyprland's own Xwayland provides,
# discovered the same socket-glob-and-wait way vpinos-launch uses for the
# installer's DISPLAY. ---------------------------------------------------
def ensure_instance_signature():
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    matches = glob.glob(os.path.join(runtime_dir, "hypr", "*", ".socket.sock"))
    if not matches:
        return
    os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = os.path.basename(os.path.dirname(matches[0]))


def ensure_display(timeout=15):
    if os.environ.get("DISPLAY"):
        return
    deadline = time.time() + timeout
    sock = None
    while time.time() < deadline:
        matches = glob.glob("/tmp/.X11-unix/X*")
        if matches:
            sock = matches[0]
            break
        time.sleep(0.2)
    if not sock:
        raise RuntimeError("timed out waiting for Xwayland's X11 socket")
    os.environ["DISPLAY"] = ":" + os.path.basename(sock)[1:]


def hyprctl_json(*args):
    proc = subprocess.run(["hyprctl", "-j", *args], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "hyprctl failed")
    return json.loads(proc.stdout)


def run_text(argv):
    # Generic "run it, give me stdout or None" helper -- every info source
    # below is best-effort (a debugging tool that crashes because one
    # signal was unavailable defeats its own purpose), so every caller
    # treats a missing/failing command the same way: skip that one row,
    # keep going.
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=10)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    return proc.stdout if proc.returncode == 0 else None


# ---- VPinOS ---------------------------------------------------------------
def read_os_release():
    values = {}
    try:
        with open(OS_RELEASE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                values[key] = value.strip('"')
    except OSError:
        pass
    return values


def vpinos_section():
    rel = read_os_release()
    # Same live-vs-installed check vpinos-menu's is_installed() already
    # uses (boot=live on the kernel cmdline, set by the ISO's own
    # bootappend-live) -- genuinely cheap and often the first question in
    # any support request ("are you on the USB stick or did you install?"),
    # so it belongs in a debugging snapshot even though it wasn't spelled
    # out as its own bullet.
    try:
        with open("/proc/cmdline", encoding="utf-8") as f:
            session = "Live (booted from USB/ISO)" if "boot=live" in f.read() else "Installed"
    except OSError:
        session = "unknown"
    # The VPinOS version is vpinos-core's: it moves with every update,
    # while /etc/os-release only names the ISO the cabinet was installed
    # from (see notes/vpinos-core-update-plan.md).
    core = dpkg_version("vpinos-core")
    return [
        ("Version", f"VPinOS {core}" if core else "unknown"),
        ("Base image", rel.get("PRETTY_NAME", "unknown")),
        ("Session", session),
    ]


# ---- Failed services --------------------------------------------------------
def failed_services_section():
    # `systemctl --failed`, not `systemctl status` per-unit -- this is the
    # same thing a sysadmin would run first after a bad boot, and
    # unprivileged users can query unit state over the bus without sudo
    # (confirmed directly, no root needed). JSON output (systemd's own
    # machine-readable unit-list schema, supported since well before this
    # image's systemd 257) avoids parsing the human `●`-prefixed table.
    out = run_text(["systemctl", "--failed", "--output=json", "--no-legend"])
    if out is None:
        return [("Failed services", "systemctl unavailable")]
    try:
        units = json.loads(out)
    except json.JSONDecodeError:
        return [("Failed services", "could not parse systemctl output")]
    if not units:
        return [("Failed services", "none")]
    return [
        (u.get("unit", "?"), f"{u.get('active', '?')}/{u.get('sub', '?')} -- {u.get('description', '')}")
        for u in units
    ]


# ---- GPU / video driver ----------------------------------------------------
def dpkg_version(pkg):
    # Installed-package version, not the running module/library itself --
    # works whether or not that driver is actually loaded right now
    # (e.g. the nvidia-driver-libs package is always present in this image
    # regardless of /etc/vpinos/gpu-driver mode, confirmed directly via
    # audit.sh's own package checks), and needs no extra tools beyond dpkg,
    # which is always present. Strips the Debian revision (everything from
    # the first "-") to leave the upstream version a user would recognize,
    # e.g. "615.71.09-2" -> "615.71.09", "25.2.6-1~bpo13+1" -> "25.2.6".
    out = run_text(["dpkg-query", "-W", "-f=${Version}", pkg])
    if not out:
        return None
    return out.strip().split("-", 1)[0] or None


def parse_lspci_size(text):
    # "256M" / "8G" / "512K" -> bytes. lspci's own unit letters, decimal
    # (it says so in `man lspci`: "M" = 1024*1024, etc -- binary, not SI).
    m = re.match(r"(\d+)([KMGT])$", text)
    if not m:
        return None
    value, unit = int(m[1]), m[2]
    return value * {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}[unit]


def human_bytes(n):
    if n is None:
        return None
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024
    return None


def vram_for_slot(slot):
    # Preferred source: the driver's own sysfs number (amdgpu and nouveau
    # both expose this under the PCI device directly, confirmed directly:
    # /sys/bus/pci/devices/0000:<slot>/mem_info_vram_total, raw bytes) --
    # exact, not an approximation. NVIDIA's proprietary driver doesn't
    # populate this, and this image doesn't ship nvidia-smi (confirmed
    # directly: not in the built ISO's /usr/bin, so not assumed present),
    # so that case falls through to the PCI BAR size below instead.
    path = f"/sys/bus/pci/devices/0000:{slot}/mem_info_vram_total"
    try:
        with open(path, encoding="utf-8") as f:
            return int(f.read().strip()), "reported by driver"
    except (OSError, ValueError):
        pass

    # Fallback: the largest prefetchable PCI memory BAR, which on a
    # discrete GPU is almost always the VRAM aperture -- an approximation
    # (Resizable BAR, virtualization, etc. can make this not match actual
    # VRAM exactly), labeled as such rather than presented as exact.
    out = run_text(["lspci", "-v", "-s", slot])
    if not out:
        return None, None
    best = 0
    for line in out.splitlines():
        m = re.search(r"Memory at .+\(.*prefetchable\) \[size=(\d+[KMGT])\]", line)
        if m:
            size = parse_lspci_size(m[1])
            if size and size > best:
                best = size
    return (best, "approx., from PCI BAR size") if best else (None, None)


def gpu_devices():
    out = run_text(["lspci", "-nnk"])
    if not out:
        return []
    devices = []
    cur = None
    class_re = re.compile(
        r"^(\S+) (" + "|".join(GPU_CLASSES) + r") \[\w+\]: (.+) \[([0-9a-f]{4}):([0-9a-f]{4})\](?: \(rev .+\))?\s*$"
    )
    for line in out.splitlines():
        if not line.startswith("\t"):
            # A new device header -- lspci -nnk's indented detail lines
            # (Subsystem/Kernel driver/Kernel modules) always belong to
            # whichever header came right before them, GPU or not. Without
            # resetting `cur` here, a later non-GPU sibling device's own
            # "Kernel driver in use:" line (confirmed directly: the GPU's
            # own HDMI audio function, right after it in lspci's output)
            # would silently overwrite the real GPU's driver.
            m = class_re.match(line)
            cur = None
            if m:
                cur = {
                    "slot": m[1], "description": m[3], "vendor_id": m[4], "device_id": m[5],
                    "driver": None,
                }
                devices.append(cur)
            continue
        if cur is not None:
            m2 = re.match(r"\tKernel driver in use: (.+)$", line)
            if m2:
                cur["driver"] = m2[1]
    return devices


def gpu_section():
    rows = []
    mode = "default (open-source)"
    try:
        with open(GPU_DRIVER_FILE, encoding="utf-8") as f:
            raw = f.read().strip()
            if raw == "nvidia":
                mode = "nvidia (proprietary)"
    except OSError:
        pass
    rows.append(("Configured mode", mode))

    devices = gpu_devices()
    if not devices:
        rows.append(("GPU", "none detected via lspci"))
        return rows

    for i, dev in enumerate(devices, 1):
        prefix = f"GPU {i}" if len(devices) > 1 else "GPU"
        rows.append((prefix, dev["description"]))
        driver = dev["driver"] or "none bound"
        rows.append((f"{prefix} kernel driver", driver))
        if driver == "nvidia":
            # The proprietary driver's own version (dpkg, not
            # /proc/driver/nvidia/version -- that file only exists while
            # the module is actually loaded, but the installed package
            # version is just as accurate and always available).
            version = dpkg_version("nvidia-driver-libs") or "unknown"
        else:
            # amdgpu/nouveau/i915 ship as part of the kernel itself, no
            # separate version number of their own -- the kernel release
            # IS their version, so show that instead of leaving this
            # blank (see the Mesa version row below for the userspace
            # half of this driver stack, which does version separately).
            version = f"kernel {os.uname().release} (in-tree)"
        rows.append((f"{prefix} driver version", version))
        vram_bytes, source = vram_for_slot(dev["slot"])
        vram_label = f"{human_bytes(vram_bytes)} ({source})" if vram_bytes else "unknown"
        rows.append((f"{prefix} VRAM", vram_label))

    mesa_version = dpkg_version("libgl1-mesa-dri") or dpkg_version("mesa-vulkan-drivers")
    rows.append(("Mesa version", mesa_version or "unknown"))
    return rows


# ---- Displays ---------------------------------------------------------------
def display_section():
    try:
        monitors = hyprctl_json("monitors")
    except RuntimeError as exc:
        return [("Displays", f"could not query Hyprland: {exc}")]
    if not monitors:
        return [("Displays", "none reported by Hyprland")]
    rows = []
    for mon in sorted(monitors, key=lambda m: m.get("id", 0)):
        label = mon.get("description") or mon.get("name", "?")
        value = (
            f"{mon.get('width', '?')}x{mon.get('height', '?')} "
            f"@ {mon.get('refreshRate', 0):.2f} Hz, position ({mon.get('x', '?')}, {mon.get('y', '?')})"
        )
        rows.append((f"{mon.get('name', '?')} -- {label}", value))
    return rows


# ---- CPU ----------------------------------------------------------------
def cpu_section():
    out = run_text(["lscpu", "-J"])
    wanted = [
        "Model name", "Architecture", "CPU(s)", "Socket(s)",
        "Core(s) per socket", "Thread(s) per core", "CPU max MHz",
    ]
    fields = {}
    if out:
        try:
            for entry in json.loads(out)["lscpu"]:
                key = entry["field"].rstrip(":")
                if key in wanted:
                    fields[key] = entry.get("data", "")
        except (json.JSONDecodeError, KeyError):
            pass
    if not fields:
        return [("CPU", "lscpu unavailable")]
    return [(key, fields[key]) for key in wanted if key in fields]


# ---- Memory ---------------------------------------------------------------
def memory_section():
    values = {}
    try:
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                key, _, rest = line.partition(":")
                if key in ("MemTotal", "MemAvailable"):
                    values[key] = int(rest.strip().split()[0]) * 1024  # kB -> bytes
    except (OSError, ValueError, IndexError):
        pass
    if "MemTotal" not in values:
        return [("Memory", "/proc/meminfo unavailable")]
    total = values["MemTotal"]
    available = values.get("MemAvailable", 0)
    used = total - available
    rows = [("Total", human_bytes(total))]
    if "MemAvailable" in values:
        rows.append(("Used", f"{human_bytes(used)} ({used * 100 // total}%)"))
        rows.append(("Available", human_bytes(available)))
    return rows


# ---- Pull it together -------------------------------------------------------
def gather_report():
    # One source of truth for both the on-screen display and the text
    # file, in the order the user asked to see it -- so they can never
    # drift apart, which matters here since the whole point of the file is
    # "the same info that's on screen", not a close approximation of it.
    return [
        ("VPinOS", vpinos_section()),
        ("Failed services", failed_services_section()),
        ("Video driver", gpu_section()),
        ("Displays", display_section()),
        ("CPU", cpu_section()),
        ("Memory", memory_section()),
    ]


def write_report_file(report):
    # A new file every run, never overwritten -- second-resolution
    # timestamp is plenty: this is launched by hand from the menu, not
    # scripted in a tight loop.
    stamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    path = os.path.join(HOME, f"vpinos_sysinfo_{stamp}.txt")
    lines = [f"VPinOS System Info -- {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}", ""]
    for title, rows in report:
        lines.append(f"== {title} ==")
        for label, value in rows:
            lines.append(f"{label}: {value}")
        lines.append("")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return path


# ---- GUI --------------------------------------------------------------------
BG = "#0d1117"
CARD_BG = "#161b22"
BORDER = "#30363d"
TEXT = "#e6edf3"
MUTED = "#8b949e"
ACCENT = "#2f81f7"
NEUTRAL = "#30363d"
NEUTRAL_HOVER = "#3d444d"


def render_gui(report, file_path):
    import tkinter as tk
    from tkinter import ttk

    root = tk.Tk()
    root.title("VPinOS -- System Info")
    root.configure(bg=BG)
    root.attributes("-fullscreen", True)

    style = ttk.Style(root)
    style.theme_use("clam")
    style.configure("TLabel", background=BG, foreground=TEXT, font=("sans", 14))
    style.configure("Header.TLabel", background=BG, foreground=TEXT, font=("sans", 24, "bold"))
    style.configure("Sub.TLabel", background=BG, foreground=MUTED, font=("sans", 12))
    style.configure("Section.TLabel", background=CARD_BG, foreground=ACCENT, font=("sans", 15, "bold"))
    style.configure("TButton", font=("sans", 14, "bold"), padding=(24, 12), relief="flat", borderwidth=0)
    style.configure("Quit.TButton", background=NEUTRAL, foreground=TEXT)
    style.map("Quit.TButton", background=[("active", NEUTRAL_HOVER)])

    # Same scrollable Canvas+Scrollbar body as vpinos-config, same
    # reason: this is a fixed-size fullscreen window with no window chrome
    # to resize, and five sections (more with multiple monitors/GPUs) can
    # easily run taller than the screen -- see that file's own comment for
    # the real 1280x800 report that made this necessary there.
    outer = tk.Frame(root, bg=BG)
    outer.pack(fill="both", expand=True)
    canvas = tk.Canvas(outer, bg=BG, highlightthickness=0)
    scrollbar = ttk.Scrollbar(outer, orient="vertical", command=canvas.yview)
    canvas.configure(yscrollcommand=scrollbar.set)
    scrollbar.pack(side="right", fill="y")
    canvas.pack(side="left", fill="both", expand=True)

    scroll_frame = tk.Frame(canvas, bg=BG)
    scroll_window = canvas.create_window((0, 0), window=scroll_frame, anchor="nw")
    scroll_frame.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
    canvas.bind("<Configure>", lambda e: canvas.itemconfig(scroll_window, width=e.width))

    def on_mousewheel(event):
        canvas.yview_scroll(-1 if (event.num == 4 or event.delta > 0) else 1, "units")

    canvas.bind_all("<Button-4>", on_mousewheel)
    canvas.bind_all("<Button-5>", on_mousewheel)
    canvas.bind_all("<MouseWheel>", on_mousewheel)

    ttk.Label(scroll_frame, text="VPinOS System Info", style="Header.TLabel").pack(pady=(36, 4))
    ttk.Label(scroll_frame, text=f"Saved to {file_path}", style="Sub.TLabel").pack(pady=(0, 28))

    content = tk.Frame(scroll_frame, bg=BG)
    content.pack(padx=60, fill="x")

    for title, rows in report:
        card = tk.Frame(content, bg=CARD_BG, highlightbackground=BORDER, highlightthickness=1)
        card.pack(fill="x", pady=8)
        ttk.Label(card, text=title, style="Section.TLabel").pack(anchor="w", padx=18, pady=(14, 8))
        grid = tk.Frame(card, bg=CARD_BG)
        grid.pack(anchor="w", fill="x", padx=18, pady=(0, 16))
        grid.grid_columnconfigure(1, weight=1)
        for r, (label, value) in enumerate(rows):
            tk.Label(
                grid, text=label, bg=CARD_BG, fg=TEXT, font=("sans", 13, "bold"), anchor="w",
            ).grid(row=r, column=0, sticky="nw", padx=(0, 24), pady=3)
            tk.Label(
                grid, text=str(value), bg=CARD_BG, fg=MUTED, font=("sans", 13), anchor="w",
                justify="left", wraplength=900,
            ).grid(row=r, column=1, sticky="nw", pady=3)

    button_row = tk.Frame(scroll_frame, bg=BG)
    button_row.pack(pady=(8, 30))
    ttk.Button(button_row, text="Quit", style="Quit.TButton", command=root.destroy).pack()
    root.bind("<Escape>", lambda e: root.destroy())

    root.mainloop()


def main():
    ensure_instance_signature()
    report = gather_report()
    path = write_report_file(report)
    print(f"Wrote {path}")

    try:
        ensure_display()
    except RuntimeError as exc:
        print(f"No display available ({exc}) -- file written, nothing to show on screen.")
        return

    render_gui(report, path)


if __name__ == "__main__":
    main()
