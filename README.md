# RematchBridge

**Use the wired Xbox-style controllers your Mac ignores.**

macOS has a built-in driver for wired Xbox controllers, but it only accepts four Microsoft models. Plug in almost anything else, like a Turtle Beach, PDP, PowerA or Hori pad, an older Microsoft Xbox One controller, or a third-party Xbox 360-style pad, and it shows up on USB but nothing can use it. RematchBridge talks to these controllers directly over USB. It needs no driver, no kernel extension and no administrator password.

- **Xbox Cloud Gaming & GeForce NOW** in Chrome, Edge, Brave or Arc: your controller shows up as a real Xbox gamepad, with analog sticks and triggers, the Xbox button and rumble.
- **Everything else** (emulators, Moonlight, Parsec, the desktop): the controller acts as a keyboard and mouse, with switchable profiles.

It started as a fix for the Turtle Beach Rematch Advanced Wired Controller, hence the name.

> Not affiliated with, endorsed by, or sponsored by Turtle Beach, Microsoft, or any controller maker. Product names and trademarks belong to their owners and are used here only to describe compatibility.

## Install

1. Download **RematchBridge.zip** from the [latest release](../../releases/latest), unzip it, and drag **RematchBridge.app** into **Applications**.
2. Open it. RematchBridge isn't notarized by Apple (it's a free hobby project), so macOS blocks it the first time:
   - Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the RematchBridge message. Confirm with your password.
3. Plug in your controller with a USB data cable (not a charge-only cable). The RematchBridge window shows **Controller ✓**, and on Xbox One/Series-style pads the Xbox button lights up.
4. Click **Allow…** next to *Keyboard & mouse*, and turn on **RematchBridge** in **Accessibility**. Without that, macOS silently drops its key and mouse events. After an update, macOS forgets the permission (the switch may still look on). Just click **Allow** again: it clears the old entry and asks fresh.

Click the controller icon in the menu bar for the control panel. Right-click it for the classic menu.

### Browser gamepad (Xbox Cloud Gaming, GeForce NOW)

1. Download **RematchBridge-Chrome-Extension.zip** from the [latest release](../../releases/latest) and unzip it somewhere permanent, for example your Documents folder. The browser keeps loading it from there.
2. Open the extensions page (`chrome://extensions`, `edge://extensions` or `brave://extensions`) and turn on **Developer mode**.
3. Click **Load unpacked** and choose the unzipped folder.
4. Open (or **reload**) [xbox.com/play](https://www.xbox.com/play). Test at [hardwaretester.com/gamepad](https://hardwaretester.com/gamepad).

RematchBridge detects the installed extension, even after a restart, and shows **Play** in its panel. Keyboard and mouse mapping pauses automatically while a game tab is in front, so inputs never double up.

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

RematchBridge only opens USB devices that identify themselves as Xbox-protocol controllers, and it leaves alone the models Apple's driver already handles. It reads Apple's list from macOS itself, so future macOS updates are respected automatically.

| Kind | Examples | Status |
| --- | --- | --- |
| Third-party wired **Xbox One / Series** pads (GIP protocol) | Turtle Beach Rematch, PDP, PowerA, Hori, other "Designed for Xbox" wired pads | ✅ Verified: Turtle Beach Rematch Advanced Wired (`10f5:711f`). Others should work; please report |
| Older **Microsoft Xbox One** pads that macOS skips | Original Xbox One controller (`045e:02d1`, `045e:02dd`), Elite Series 1 (`045e:02e3`) | 🧪 Expected to work, untested |
| Wired **Xbox 360-style** pads (XInput protocol) | Third-party 360 pads, Logitech F310/F710 in X mode, arcade sticks | 🧪 Experimental: built from the Linux driver's documentation, untested |
| Microsoft Xbox 360 wired, Xbox One S, Elite Series 2, Series X\|S | | macOS supports these itself; RematchBridge leaves them alone |
| Bluetooth controllers, PlayStation, Switch Pro | | macOS supports these itself |
| Xbox Wireless Adapter, Xbox 360 wireless receiver | | Not supported |

The Share button is only read on verified models, so it can't be misdetected on others.

**Tried a controller?** [Open an issue](../../issues) with its name and USB ID (System Information → USB), and say whether it worked. If it didn't, quit RematchBridge, run `build/gipdump 30` (see *Build from source*), press each button once, and paste the output.

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

Builds are ad-hoc signed, so macOS forgets the Accessibility permission after every rebuild. Click **Allow** in the app again and turn it on. (A self-signed certificate would keep the identity stable, but macOS 26 refuses Accessibility to apps signed with an untrusted certificate.)

**Diagnostics:**
- `build/gipdump 60` prints live button and stick state for 60 seconds. Quit RematchBridge first, since only one program can read the controller at a time.
- The log is at `~/Library/Logs/RematchBridge.log` (Open Log in the panel).

## Credits

The details of the Xbox controller USB protocol (GIP) come from the Linux [xpad](https://github.com/torvalds/linux/blob/master/drivers/input/joystick/xpad.c) driver and [OpenJoystickDriver](https://github.com/xsyetopz/OpenJoystickDriver). No code was copied from either.

## License

[MIT](LICENSE)
