#!/usr/bin/python3
"""The VPinOS console menu, in Textual.

Started by /usr/bin/vpinos-menu wherever Textual can draw: kmscon on
tty1, or any other real terminal. The Linux text console (TERM=linux,
the getty@tty1 fallback on fbcon) gets vpinos-menu-classic instead.

This file only draws menus and asks questions. What an item does --
launching through vpinos-launch, apt, nmtui, the settings and their log
lines -- is in vpinos-menu-actions, shared with the classic menu, and
runs in the real terminal: the menu suspends itself while an action
runs, so Hyprland, apt output, nmtui and the "Press Enter" pauses work
exactly as they do in the classic menu.

Same items and numbers as the classic menu, so the number keys and the
docs carry over. Settings with a few fixed values (Console Rotation, GPU
Driver, Boot on startup, SSH Password Authentication) get a choice
screen and run without the terminal; their messages come back as
notifications.
"""

import asyncio
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import Callable, Optional

from rich.table import Table
from rich.terminal_theme import TerminalTheme
from rich.text import Text
from textual import on
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Center, Horizontal, Vertical
from textual.screen import ModalScreen, Screen
from textual.widgets import Button, OptionList, Static
from textual.widgets.option_list import Option

ACTIONS = os.environ.get("VPINOS_MENU_ACTIONS", "/usr/libexec/vpinos/vpinos-menu-actions")
# Next to this file's own usr/: /usr/share/vpinos/logo.ans when
# installed, the checkout's copy when run from vpinos-core/src (with a
# dry-run VPINOS_MENU_ACTIONS, see the manage-boot-programs skill,
# "Testing before building").
LOGO = os.environ.get(
    "VPINOS_MENU_LOGO",
    os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "..", "share", "vpinos", "logo.ans"),
)
MENU_LOG = "/var/log/vpinos-menu.log"
SSH_TESTING_CONF = "/etc/ssh/sshd_config.d/99-vpinos-live-testing.conf"

# The logo was drawn for the console's own 16 colours, so map them the
# way xterm (and kmscon's default palette) does rather than through
# Textual's theme.
XTERM_COLOURS = TerminalTheme(
    (0, 0, 0),
    (229, 229, 229),
    [
        (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
        (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
    ],
    [
        (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
        (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
    ],
)


# --- What the menus show ---------------------------------------------------

def read(path: str, default: str = "") -> str:
    try:
        with open(path) as f:
            return f.read().strip() or default
    except OSError:
        return default


def is_installed() -> bool:
    """Live vs installed, the same test as the actions' is_installed."""
    return "boot=live" not in read("/proc/cmdline")


def is_persistent() -> bool:
    """A live session whose settings survive a reboot, the same test as
    the actions' is_persistent."""
    return " /run/live/persistence/" in read("/proc/mounts")


def settings_kept() -> bool:
    """Where Boot on startup means something (the actions' settings_kept)."""
    return is_installed() or is_persistent()


def output(*cmd: str) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def persistence() -> tuple[str, str]:
    """vpinos-persistence.sh status: the state (saving, other, off,
    failed, or none without the "save settings" boot entry) and the
    sentence to show."""
    lines = output("/usr/libexec/vpinos/vpinos-persistence.sh", "status").splitlines()
    return (lines[0] if lines else "none", lines[1] if len(lines) > 1 else "")


def gpu_driver() -> str:
    return read("/etc/vpinos/gpu-driver", "default")


def boot_mode() -> str:
    return read("/etc/vpinos/boot-mode", "menu")


ROTATIONS = {"0": "Normal", "3": "90 Left", "1": "90 Right"}


def console_rotation() -> str:
    """fbcon's numbering (see vpinos-console-rotation.sh)."""
    value = read("/etc/vpinos/console-rotation", "0")
    return value if value in ROTATIONS else "0"


def ssh_password_auth() -> str:
    return "on" if os.path.exists(SSH_TESTING_CONF) else "off"


def vr_installed() -> bool:
    return output("/usr/libexec/vpinos/vpinos-vr-setup.sh", "status") == "installed"


def is_amd64() -> bool:
    return output("dpkg", "--print-architecture") == "amd64"


def vpx_editor_state() -> str:
    if not is_amd64():
        return "amd64 only"
    if output("/usr/libexec/vpinos/vpinos-vpx-editor-setup.sh", "status") == "installed":
        return ""
    return "not installed"


def version() -> str:
    """vpinos-core's version is the VPinOS version (it moves with every
    update); os-release's VERSION_ID only names the ISO the system was
    installed from, so it's just the fallback."""
    ver = output("dpkg-query", "-W", "-f=${Version}", "vpinos-core")
    if not ver:
        for line in read("/etc/os-release").splitlines():
            if line.startswith("VERSION_ID="):
                ver = line.split("=", 1)[1].strip('"')
    return ver or "unknown"


def ip_address() -> str:
    """First address from `hostname -I`; empty before DHCP has finished
    or with nothing connected."""
    addrs = output("hostname", "-I").split()
    return addrs[0] if addrs else "not connected"


def log(message: str) -> None:
    try:
        with open(MENU_LOG, "a") as f:
            # The same timestamp as the actions' `date -Is`.
            f.write(f"{datetime.now().astimezone().isoformat(timespec='seconds')}: menu: {message}\n")
    except OSError:
        pass


# --- The logo ----------------------------------------------------------------

class Logo(Static):
    """The ANSI art from /usr/share/vpinos/logo.ans, with the version and
    IP drawn over its second-to-last row -- the same place the classic
    menu puts them (its print_logo), at the same columns. The IP is
    re-read every few seconds, so it appears once DHCP finishes."""

    def on_mount(self) -> None:
        self.ver = version()
        self.update_logo()
        self.set_interval(5, self.update_logo)

    def update_logo(self) -> None:
        try:
            with open(LOGO, encoding="utf-8") as f:
                lines = [Text.from_ansi(line) for line in f.read().splitlines()]
        except OSError:
            self.update(Text("VPinOS", style="bold bright_cyan"))
            return
        if len(lines) >= 2:
            left = Text.assemble(("Version: ", "red"), (self.ver, "bright_white"))
            right = Text.assemble(("IP: ", "red"), (ip_address(), "bright_white"))
            row = lines[-2]
            row = self.overlay(row, 7, left)
            row = self.overlay(row, 52 - right.cell_len, right)
            lines[-2] = row
        self.update(Text("\n").join(lines))

    @staticmethod
    def overlay(row: Text, start: int, piece: Text) -> Text:
        start = max(0, start)
        return Text.assemble(row[:start], piece, row[start + piece.cell_len:])


# --- Menu items ------------------------------------------------------------

@dataclass
class Item:
    key: str
    label: str
    run: Callable[[], None]
    value: str = ""
    help: str = ""
    marked: Optional[bool] = None  # choice screens: True = the current value


SEPARATOR = None


class MenuScreen(Screen):
    """One menu: the logo, a panel titled with where you are, the items,
    and a line describing the highlighted one. Subclasses list their
    items in items(); they're rebuilt every time the screen comes back,
    so values changed by an action or a choice screen show up."""

    BINDINGS = [
        Binding("escape", "back", "Back", show=False),
        Binding("backspace", "back", "Back", show=False),
    ]

    title_text = ""
    info_text = ""

    def __init__(self, path: tuple[str, ...] = ()) -> None:
        super().__init__()
        self.path = path + (self.title_text,)
        self.current: list[Optional[Item]] = []

    def compose(self) -> ComposeResult:
        with Center(id="logo-row"):
            yield Logo(id="logo")
        with Center(id="panel-row"):
            with Vertical(id="panel"):
                yield Static(id="info")
                yield OptionList(id="menu")
                yield Static(id="help")
        yield Static(
            "↑↓ Move   Enter Select   Esc Back   1-9 / letters: shortcut",
            id="keys",
        )

    def on_mount(self) -> None:
        self.query_one("#panel").border_title = " › ".join(self.path)
        self.rebuild()

    def on_screen_resume(self) -> None:
        self.rebuild()

    def items(self) -> list[Optional[Item]]:
        return []

    def info(self) -> str:
        return self.info_text

    def rebuild(self) -> None:
        menu = self.query_one("#menu", OptionList)
        keep = menu.highlighted
        self.current = self.items()
        menu.clear_options()
        for item in self.current:
            if item is SEPARATOR:
                menu.add_option(None)
            else:
                menu.add_option(Option(self.prompt(item), id=item.key))
        info = self.info()
        info_widget = self.query_one("#info", Static)
        info_widget.update(info)
        info_widget.display = bool(info)
        options = [i for i in self.current if i is not SEPARATOR]
        if options:
            menu.highlighted = keep if keep is not None and keep < menu.option_count else 0
        menu.focus()

    @staticmethod
    def prompt(item: Item) -> Table:
        grid = Table.grid(expand=True, padding=(0, 1))
        grid.add_column(width=2, style="bold #7fd8e6")
        grid.add_column(ratio=1)
        grid.add_column(justify="right", style="#9fb3c8")
        label = item.label
        if item.marked is not None:
            label = ("● " if item.marked else "○ ") + label
        grid.add_row(item.key, label, item.value)
        return grid

    def item_for(self, key: str) -> Optional[Item]:
        for item in self.current:
            if item is not SEPARATOR and item.key == key:
                return item
        return None

    @on(OptionList.OptionHighlighted)
    def show_help(self, event: OptionList.OptionHighlighted) -> None:
        item = self.item_for(event.option_id or "")
        self.query_one("#help", Static).update(item.help if item else "")

    @on(OptionList.OptionSelected)
    def select(self, event: OptionList.OptionSelected) -> None:
        item = self.item_for(event.option_id or "")
        if item:
            item.run()

    def on_key(self, event) -> None:
        """Number and letter shortcuts, as in the classic menu."""
        key = event.character.lower() if event.character else ""
        item = self.item_for(key) if key else None
        if item:
            event.stop()
            menu = self.query_one("#menu", OptionList)
            menu.highlighted = menu.get_option_index(item.key)
            item.run()

    def action_back(self) -> None:
        if len(self.app.screen_stack) > 2:
            self.app.pop_screen()

    def back_item(self) -> Item:
        return Item("q", "Back", self.action_back, help="Back to the previous menu.")

    # Helpers for subclasses

    def open(self, screen_class: type["MenuScreen"]) -> Callable[[], None]:
        return lambda: self.app.push_screen(screen_class(self.path))

    def terminal(self, *action: str, restart: bool = False) -> Callable[[], None]:
        return lambda: self.app.run_action_in_terminal(action, restart=restart)


class ChoiceScreen(MenuScreen):
    """A setting with a few fixed values. Selecting one runs the setter
    action (captured, not in the terminal) and goes back."""

    setter = ""
    choices: list[tuple[str, str, str]] = []  # (value, label, help)

    def current_value(self) -> str:
        return ""

    def items(self) -> list[Optional[Item]]:
        cur = self.current_value()
        items: list[Optional[Item]] = []
        for n, (value, label, help_text) in enumerate(self.choices, 1):
            items.append(Item(str(n), label, self.chooser(value, label), help=help_text, marked=value == cur))
        items += [SEPARATOR, Item("q", "Cancel, no change", self.action_back, help="Keep the current setting.")]
        return items

    def chooser(self, value: str, label: str) -> Callable[[], None]:
        def choose() -> None:
            if value == self.current_value():
                self.action_back()
                return
            self.app.run_worker(self.apply(value, label), exclusive=True)
        return choose

    async def apply(self, value: str, label: str) -> None:
        busy = BusyScreen(f"{self.title_text}: {label}…")
        await self.app.push_screen(busy)
        rc, text = await self.app.run_action_captured(self.setter, value)
        self.app.pop_screen()
        if rc == 0:
            if text:
                self.app.notify(" ".join(text.split()), timeout=5)
            self.app.pop_screen()
        else:
            # The actions' messages are wrapped for an 80-column console;
            # the dialog wraps them itself.
            text = " ".join(text.split())
            self.app.push_screen(MessageScreen(text or f"{self.title_text} failed (exit {rc})."))


# --- Dialogs ---------------------------------------------------------------

class ConfirmScreen(ModalScreen[bool]):
    BINDINGS = [
        Binding("y", "answer(True)", show=False),
        Binding("n", "answer(False)", show=False),
        Binding("escape", "answer(False)", show=False),
        Binding("left", "app.focus_previous", show=False),
        Binding("right", "app.focus_next", show=False),
    ]

    def __init__(self, question: str) -> None:
        super().__init__()
        self.question = question

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog"):
            yield Static(self.question, classes="question")
            with Horizontal(classes="buttons"):
                yield Button("Yes", id="yes", variant="error")
                yield Button("No", id="no", variant="primary")

    def on_mount(self) -> None:
        self.query_one("#no", Button).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")

    def action_answer(self, answer: bool) -> None:
        self.dismiss(answer)


class MessageScreen(ModalScreen[None]):
    BINDINGS = [Binding("escape,enter,space,q", "close", show=False)]

    def __init__(self, message: str) -> None:
        super().__init__()
        self.message = message

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog"):
            yield Static(self.message, classes="question")
            with Horizontal(classes="buttons"):
                yield Button("OK", id="ok", variant="primary")

    def on_mount(self) -> None:
        self.query_one("#ok", Button).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss()

    def action_close(self) -> None:
        self.dismiss()


class BusyScreen(ModalScreen[None]):
    """Up while a setter runs. On kmscon a Console Rotation or GPU Driver
    change restarts the console, which ends this menu while this is still
    showing; autologin brings a fresh menu back."""

    def __init__(self, message: str) -> None:
        super().__init__()
        self.message = message

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog"):
            yield Static(self.message, classes="question")


# --- The menus ---------------------------------------------------------------

class MainScreen(MenuScreen):
    title_text = "Main"

    def __init__(self) -> None:
        super().__init__(())

    def items(self) -> list[Optional[Item]]:
        items: list[Optional[Item]] = [
            Item("1", "Setup", self.open(SetupScreen),
                 help="Screens, GPU driver, network, VPinball and VPinFE settings."),
        ]
        if is_installed():
            items += [
                Item("2", "VPinFE", self.terminal("vpinfe"), help="Start the VPinFE frontend."),
                Item("3", "VR", self.open(VrScreen), help="Play in a VR headset over WiVRn."),
                Item("4", "Update VPinOS", self.terminal("update", restart=True),
                     help="Install the latest VPinOS updates (needs internet)."),
                Item("5", "Testing", self.open(TestingScreen), help="Try the cabinet out."),
                Item("6", "Tools", self.open(ToolsScreen), help="System info and the VPX Editor."),
            ]
        else:
            items += [
                Item("2", "Testing", self.open(TestingScreen), help="Try the cabinet out, VPinFE included."),
                Item("3", "VR", self.open(VrScreen), help="Play in a VR headset over WiVRn."),
                Item("4", "Install VPinOS", self.terminal("install"),
                     help="Install VPinOS from this USB stick to a disk."),
                Item("5", "Tools", self.open(ToolsScreen), help="System info and the VPX Editor."),
            ]
        items += [
            SEPARATOR,
            Item("q", "Quit to shell", self.quit, help="Leave the menu for a command prompt (type vpinos-menu to come back)."),
            Item("s", "Shutdown", self.confirm("Shut down now?", "shutdown"), help="Turn the cabinet off."),
            Item("r", "Reboot", self.confirm("Reboot now?", "reboot"), help="Restart the cabinet."),
        ]
        return items

    def info(self) -> str:
        """On a live session, whether its settings survive a reboot."""
        if is_installed():
            return ""
        state, message = persistence()
        if state == "none":
            return 'Settings are lost on reboot. To keep them, pick "save settings to USB" at the boot menu.'
        return message

    def quit(self) -> None:
        self.app.exit()

    def confirm(self, question: str, action: str) -> Callable[[], None]:
        return confirm(self, question, action, action)

    def action_back(self) -> None:
        pass


def confirm(screen: MenuScreen, question: str, action: str, name: str) -> Callable[[], None]:
    """Asks first, then runs the action in the terminal. A No is logged
    as "selected <name>, cancelled", the action itself logs a Yes."""
    def ask() -> None:
        def answered(yes: Optional[bool]) -> None:
            if yes:
                screen.app.run_action_in_terminal((action,))
            else:
                log(f"selected {name}, cancelled")
        screen.app.push_screen(ConfirmScreen(question), answered)
    return ask


class SetupScreen(MenuScreen):
    title_text = "Setup"

    def items(self) -> list[Optional[Item]]:
        items: list[Optional[Item]] = [
            Item("1", "Console Rotation", self.open(ConsoleRotationScreen),
                 value=ROTATIONS[console_rotation()],
                 help="Turn this menu for a Table screen mounted in portrait."),
            Item("2", "GPU Driver", self.open(GpuDriverScreen), value=gpu_driver(),
                 help="Open-source Mesa/NVK, or the NVIDIA proprietary driver."),
            Item("3", "VPinOS Configuration", self.terminal("vpinos-config"),
                 help="Screens, refresh rates, table rotation, VPinball and VPinFE options."),
            Item("4", "Network Settings", self.terminal("network"),
                 help="Wired and Wi-Fi connections, and the hostname."),
            Item("5", "VPXConfig", self.terminal("vpxconfig"),
                 help="Advanced VPinball configuration (VPinballX.ini)."),
            Item("6", "VPinFE Map Controls", self.terminal("vpinfe-map-controls"),
                 help="Map your buttons and controller in VPinFE."),
        ]
        if settings_kept():
            items.append(Item("7", "Boot on startup", self.open(BootModeScreen), value=boot_mode(),
                              help="What starts when the cabinet is switched on."))
        return items + [SEPARATOR, self.back_item()]


class ConsoleRotationScreen(ChoiceScreen):
    title_text = "Console Rotation"
    setter = "set-console-rotation"
    choices = [
        ("0", "Normal", "Landscape (the default)."),
        ("3", "90 Left", "Portrait, turned 90° to the left."),
        ("1", "90 Right", "Portrait, turned 90° to the right."),
    ]

    def current_value(self) -> str:
        return console_rotation()


class GpuDriverScreen(ChoiceScreen):
    title_text = "GPU Driver"
    setter = "set-gpu-driver"
    choices = [
        ("default", "Default", "The open-source Mesa/NVK driver."),
        ("nvidia", "NVIDIA proprietary", "NVIDIA's own driver (Turing/GTX 16 and newer; Secure Boot must be off)."),
    ]

    def current_value(self) -> str:
        return gpu_driver()


class BootModeScreen(ChoiceScreen):
    # To add a program here, see the `manage-boot-programs` skill in
    # notes/skills/: this list, the classic menu's, the action, the
    # profile script, the audit check and the docs move together.
    title_text = "Boot on startup"
    setter = "set-boot-mode"
    choices = [
        ("menu", "VPinOS menu", "Start in this menu (the default)."),
        ("vpinfe", "VPinFE", "Start straight in VPinFE."),
    ]

    def current_value(self) -> str:
        return boot_mode()


class SshPasswordAuthScreen(ChoiceScreen):
    title_text = "SSH Password Authentication"
    setter = "set-ssh-password-auth"
    choices = [
        ("on", "Enable", "Allow SSH logins with a password (live USB testing)."),
        ("off", "Disable", "Keys only (the default)."),
    ]

    def current_value(self) -> str:
        return ssh_password_auth()


class TestingScreen(MenuScreen):
    title_text = "Testing"

    def items(self) -> list[Optional[Item]]:
        items: list[Optional[Item]] = [
            Item("1", "Launch VPinball Example Table", self.terminal("example-table"),
                 help="Play VPinball's bundled example table."),
        ]
        if not is_installed():
            items += [
                Item("2", "VPinFE", self.terminal("testing-vpinfe"), help="Start the VPinFE frontend."),
                Item("3", "SSH Password Authentication", self.open(SshPasswordAuthScreen),
                     value=ssh_password_auth(), help="Allow SSH logins with a password while testing."),
            ]
        return items + [SEPARATOR, self.back_item()]


class ToolsScreen(MenuScreen):
    title_text = "Tools"

    def items(self) -> list[Optional[Item]]:
        items: list[Optional[Item]] = [
            Item("1", "System Info (Debug)", self.terminal("sysinfo"),
                 help="Hardware, drivers, screens and sound devices."),
            Item("2", "VPX Editor", self.terminal("vpx-editor"), value=vpx_editor_state(),
                 help="Edit tables (installs on first use, ~530 MB)."),
        ]
        if persistence()[0] == "saving":
            items.append(Item("3", "Reset Saved Settings",
                              confirm(self, "Clear all saved settings on this USB stick and reboot?",
                                      "reset-saved-settings", "tools/reset-saved-settings"),
                              help="Start fresh: clears what's saved on this USB stick, then reboots."))
        return items + [SEPARATOR, self.back_item()]


class VrScreen(MenuScreen):
    title_text = "VR"

    def info(self) -> str:
        if not vr_installed():
            return "Components: not installed (see Setup)"
        status = output("/usr/libexec/vpinos/vpinos-vr.sh", "status")
        return "Components: installed" + (f"\n{status}" if status else "")

    def items(self) -> list[Optional[Item]]:
        return [
            Item("1", "Setup", self.open(VrSetupScreen), help="GPU driver and installing the VR components."),
            Item("2", "Start VR server", self.vr("vr-start"), help="Start WiVRn and turn VR on in VPinball."),
            Item("3", "Stop VR server", self.vr("vr-stop"), help="Stop WiVRn and put VPinball's VR setting back."),
            Item("4", "WiVRn Dashboard", self.vr("vr-dashboard"), help="WiVRn's own settings window."),
            Item("5", "Connect headset over USB", self.vr("vr-connect-usb"), help="Use a headset plugged in by USB."),
            Item("6", "Pair new headset (Wi-Fi)", self.vr("vr-pair"), help="Pair a headset on the same network."),
            Item("7", "Launch VPinball Example Table", self.vr("vr-example-table"),
                 help="Play the example table in the headset."),
            Item("8", "Show server log", self.vr("vr-log"), help="Follow the WiVRn log (Ctrl+C to stop)."),
            SEPARATOR,
            self.back_item(),
        ]

    def vr(self, action: str) -> Callable[[], None]:
        def run() -> None:
            if not vr_installed():
                self.app.notify("VR components not installed, run VR > Setup first.", severity="warning")
                return
            self.app.run_action_in_terminal((action,))
        return run


class VrSetupScreen(MenuScreen):
    title_text = "Setup"

    def info(self) -> str:
        lines = []
        if not is_installed():
            lines.append("Live USB: VR components are lost on reboot.")
        if vr_installed():
            ver = output("dpkg-query", "-W", "-f=${Version}", "wivrn")
            lines.append(f"WiVRn {ver} -- the headset's WiVRn app must be this same version.")
        return "\n".join(lines)

    def items(self) -> list[Optional[Item]]:
        # GPU Driver is the same screen as Setup > GPU Driver -- a second
        # way in for VR-only users (NVENC needs the proprietary driver).
        return [
            Item("1", "GPU Driver", self.open(GpuDriverScreen), value=gpu_driver(),
                 help="NVIDIA's encoder (NVENC) needs the proprietary driver."),
            Item("2", "Install VR components", self.terminal("vr-install"),
                 value="installed" if vr_installed() else "not installed",
                 help="Install WiVRn, adb and the encoder libraries (needs internet)."),
            SEPARATOR,
            self.back_item(),
        ]


# --- The app ---------------------------------------------------------------

class VpinosMenu(App):
    CSS = """
    Screen {
        background: #000000;
        layout: vertical;
    }
    #logo-row {
        height: auto;
        margin-top: 1;
    }
    #logo {
        width: auto;
        height: auto;
    }
    #panel-row {
        height: 1fr;
        margin-top: 1;
    }
    #panel {
        width: 66;
        max-width: 100%;
        height: auto;
        max-height: 100%;
        border: round #2ab7ca;
        border-title-color: #ffffff;
        border-title-style: bold;
        background: transparent;
        padding: 0 1;
    }
    #info {
        color: #c8d3dc;
        padding: 0 1;
        margin-bottom: 1;
        height: auto;
    }
    #menu {
        background: transparent;
        border: none;
        height: auto;
        padding: 0;
    }
    #menu:focus {
        border: none;
    }
    #menu > .option-list--option-highlighted,
    #menu:focus > .option-list--option-highlighted {
        background: #1d6f87;
        color: #ffffff;
        text-style: bold;
    }
    #menu > .option-list--separator {
        color: #2a4552;
    }
    #help {
        color: #8fa3b3;
        padding: 0 1;
        margin-top: 1;
        height: auto;
        min-height: 1;
    }
    #keys {
        dock: bottom;
        height: 1;
        background: #0b2230;
        color: #8fa3b3;
        content-align: center middle;
    }
    ModalScreen {
        background: #000000 60%;
        align: center middle;
    }
    .dialog {
        width: 52;
        max-width: 100%;
        height: auto;
        border: round #2ab7ca;
        background: #06121a;
        padding: 1 2;
    }
    .question {
        width: 100%;
        content-align: center middle;
        text-align: center;
    }
    .buttons {
        width: 100%;
        height: auto;
        align: center middle;
        margin-top: 1;
    }
    .buttons Button {
        margin: 0 2;
        min-width: 10;
    }
    """

    ENABLE_COMMAND_PALETTE = False

    def __init__(self) -> None:
        super().__init__()
        self.ansi_theme_dark = XTERM_COLOURS

    def on_mount(self) -> None:
        self.push_screen(MainScreen())

    def run_action_in_terminal(self, action: tuple[str, ...], restart: bool = False) -> None:
        """Runs a vpinos-menu-actions action in the real terminal, with
        this menu suspended -- Hyprland launches, apt and nmtui need the
        terminal to themselves."""
        with self.suspend():
            sys.stdout.write("\033[H\033[2J")
            sys.stdout.flush()
            try:
                subprocess.run([ACTIONS, *action])
            except OSError as e:
                print(f"vpinos-menu: can't run {ACTIONS}: {e}")
                input("Press Enter to continue...")
        if restart:
            # The update may have replaced this menu (vpinos-core): start
            # the new one rather than keep running the old code.
            self.exit("restart")

    async def run_action_captured(self, *action: str) -> tuple[int, str]:
        """Runs an action that only prints a message (the setters)."""
        try:
            proc = await asyncio.create_subprocess_exec(
                ACTIONS, *action,
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
        except OSError as e:
            return 1, f"Can't run {ACTIONS}: {e}"
        out, _ = await proc.communicate()
        return proc.returncode or 0, out.decode(errors="replace").strip()


def main() -> None:
    result = VpinosMenu().run()
    if result == "restart":
        os.execv("/usr/bin/vpinos-menu", ["vpinos-menu"])


if __name__ == "__main__":
    main()
