# RematchBridge

Use a **Turtle Beach Rematch Advanced Wired Controller** (and other wired Xbox-style controllers that macOS ignores) on your Mac:

- **Xbox Cloud Gaming & GeForce NOW in Chrome:** your controller shows up as a real Xbox gamepad, with analog sticks and triggers, the Xbox button and rumble.
- **Everything else** (emulators, Moonlight, Parsec, the desktop): the controller acts as a keyboard and mouse, with switchable profiles.

macOS has a built-in driver for wired Xbox controllers, but it only accepts Microsoft's own pads. Third-party pads like the Rematch (USB ID `10f5:711f`) show up on USB and nothing uses them. RematchBridge talks to the controller directly over USB. It needs no driver, no kernel extension and no administrator password.

> Not affiliated with, endorsed by, or sponsored by Turtle Beach or Microsoft. "Rematch", "Turtle Beach", "Xbox" and "Xbox Cloud Gaming" are trademarks of their owners and are used here only to describe compatibility.

## Install

1. Download **RematchBridge.zip** from the [latest release](../../releases/latest), unzip it, and drag **RematchBridge.app** into **Applications**.
2. Open it. RematchBridge isn't notarized by Apple (it's a free hobby project), so macOS blocks it the first time:
   - Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the RematchBridge message. Confirm with your password.
3. Plug in your controller with a USB cable. The Xbox button lights up and the RematchBridge window shows **Controller ✓**.
4. Click **Allow…** next to *Keyboard & mouse*, and turn on **RematchBridge** in **Accessibility**. Without that, macOS silently drops its key and mouse events.

Click the controller icon in the menu bar for the control panel. Right-click it for the classic menu.

### Browser gamepad (Xbox Cloud Gaming, GeForce NOW)

1. Download **RematchBridge-Chrome-Extension.zip** from the [latest release](../../releases/latest) and unzip it somewhere permanent, for example your Documents folder.
2. In Chrome, open `chrome://extensions` and turn on **Developer mode** (top right).
3. Click **Load unpacked** and choose the unzipped folder.
4. Open (or **reload**) [xbox.com/play](https://www.xbox.com/play). Test at [hardwaretester.com/gamepad](https://hardwaretester.com/gamepad).

Keyboard and mouse mapping pauses automatically while one of those tabs is in front, so inputs never double up.

## Features

- **Menu-bar panel:** status, a mini live controller, keyboard & mouse switch, browser gamepad status, profile buttons and quick actions.
- **RematchBridge window:** a setup checklist, a live controller view that doubles as a tester, the profile picker and Open at Login.
- **On-screen banner** when the controller connects or disconnects, mapping pauses or resumes, or the profile changes.
- **Profiles:**
  - **Desktop:** left stick = mouse, right stick = scroll, A/B = clicks, D-pad = arrow keys.
  - **Emulator:** RetroArch's default keyboard layout.
  - **Streaming (FPS):** WASD on the left stick, mouse look on the right stick, triggers = mouse buttons.
- **Per-app profiles:** "Always use a profile for …" switches automatically when that app is in front.
- **The Xbox button** pauses or resumes keyboard & mouse mapping.
- Smooth analog mouse with deadzone and response curve, pixel scrolling, double-click, held keys, key repeat and shortcuts like `cmd+tab`.
- Plug-and-play. A USB reset on connect fully wakes the controller.

## Profiles

Profiles are JSON files in `~/Library/Application Support/RematchBridge/Profiles/`. **Edit Profiles** opens the folder, which has a README covering every option. Choose **Reload Profiles** after editing. Delete all the files to get the built-in profiles back.

```json
{
  "name": "Streaming (FPS)",
  "buttons": { "a": "space", "rt": "mouse:left", "view": "tab", "guide": "toggle" },
  "leftStick":  { "mode": "keys", "up": "w", "down": "s", "left": "a", "right": "d", "deadzone": 0.25 },
  "rightStick": { "mode": "mouse", "speed": 1.6, "deadzone": 0.1 },
  "triggerThreshold": 0.2
}
```

The Rematch's back paddles send whatever you assign in Turtle Beach Control Hub (A and B by default).

## Supported controllers

- **Verified:** Turtle Beach Rematch Advanced Wired Controller (`10f5:711f`).
- **Probably works:** other wired Xbox One / Series-style controllers that macOS doesn't support itself. RematchBridge picks up any non-Microsoft controller that uses the same Xbox USB protocol, but these are untested, and the Share button is only read on verified models.
- **Microsoft controllers** are left to macOS's built-in support.

Tried another controller? [Open an issue](../../issues) with its name and USB ID (System Information → USB), plus the output of `build/gipdump 30` while you press each button.

## Why keyboard & mouse instead of a virtual controller?

To create a virtual game controller, macOS requires the `com.apple.developer.hid.virtual.device` entitlement, which only Apple grants. Running as root doesn't get around it. So native Mac games won't see a controller, but anything that accepts keyboard and mouse works. Browsers are different: they read controllers through the web Gamepad API, and the Chrome extension can supply one there.

**How the browser bridge works:** RematchBridge streams the controller's state over a loopback-only WebSocket (`127.0.0.1:37121`). It accepts connections only from xbox.com, play.geforcenow.com and hardwaretester.com; any other origin gets `403` and no data. Nothing leaves your Mac.

## Build from source

Requirements: macOS 14 or later (Apple Silicon or Intel) and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't needed.

```bash
./build.sh
```

```bash
./test.sh
```

```bash
ditto build/RematchBridge.app /Applications/RematchBridge.app
```

Local builds are ad-hoc signed, so macOS forgets the Accessibility permission after every rebuild. Switch it off and on again after installing a new build.

**Diagnostics:**
- `build/gipdump 60` prints live button and stick state for 60 seconds. Quit RematchBridge first, since only one program can read the controller at a time.
- The log is at `~/Library/Logs/RematchBridge.log` (Open Log in the panel).

## Credits

The details of the Xbox controller USB protocol (GIP) come from the Linux [xpad](https://github.com/torvalds/linux/blob/master/drivers/input/joystick/xpad.c) driver and [OpenJoystickDriver](https://github.com/xsyetopz/OpenJoystickDriver). No code was copied from either.

## License

[MIT](LICENSE)
