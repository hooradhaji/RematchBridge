# RematchBridge

A macOS menu-bar app that makes the **Turtle Beach Xbox Rematch Advanced Wired Controller** (and other wired Xbox One/Series-style "GIP" pads) usable on Apple Silicon Macs by turning it into **keyboard and mouse input**.

macOS 26 has a built-in driver for wired Xbox controllers, but it only accepts Microsoft's own controllers. Third-party pads like the Rematch (USB `10f5:711f`) show up on USB and nothing uses them. RematchBridge talks to the controller directly over USB (IOUSBHost, no driver or kernel extension) and sends keyboard and mouse events.

## Xbox Cloud Gaming / GeForce NOW (browser gamepad)

Browsers read controllers through the web Gamepad API, so a Chrome extension can supply one without Apple's entitlement. RematchBridge streams the controller's state over a loopback-only WebSocket (`127.0.0.1:37121`). It accepts only pages from xbox.com, play.geforcenow.com and hardwaretester.com; any other origin gets `403` and no data. The extension in `Extension/` presents the controller to those pages as a standard Xbox gamepad with analog sticks and triggers, the Xbox and Share buttons, and rumble. Keyboard/mouse mapping pauses automatically while one of those tabs is in front.

Setup (Chrome):
1. Open `chrome://extensions` and turn on **Developer mode**.
2. Click **Load unpacked** and choose this repo's `Extension` folder. The menu item **Set Up Browser Gamepad…** also copies a version to your Library folder and puts the path on the clipboard (press Cmd+Shift+G in the picker).
3. Reload any xbox.com or GeForce NOW tab that was already open. Test at https://hardwaretester.com/gamepad.

## Why keyboard/mouse and not a virtual controller?

To create a virtual game controller, macOS needs the `com.apple.developer.hid.virtual.device` entitlement, which only Apple can grant. Even running as root doesn't get around it (tested on macOS 26.5). So native Mac games won't see a controller. Anything that accepts keyboard and mouse works, including emulators, Moonlight and Parsec. Browser games, such as Xbox Cloud Gaming, get a real gamepad through the extension above.

## Features

- **RematchBridge window:** setup checklist (controller, keyboard & mouse permission, browser gamepad), a live controller view that doubles as a tester, profile picker, mapping switch and Open at Login. It opens on first launch, from the menu, or when you open the app again.
- **On-screen HUD:** a brief banner when the controller connects or disconnects, mapping pauses or resumes, or the profile changes.

- Detects the controller on plug-in and unplug. A USB reset on connect wakes the pad fully (the Xbox button lights up).
- Profiles: **Desktop** (mouse, scroll, clicks, arrows), **Emulator** (RetroArch default keys), **Streaming (FPS)** (WASD, mouse look).
- Per-app profiles: "Always Use for…" in the menu, or `"apps": [bundle IDs]` in the profile file.
- The Xbox button pauses or resumes mapping.
- Smooth analog mouse with deadzone and response curve, pixel scrolling, double-click, held keys, key repeat, and combos like `cmd+tab`.
- Launch at login.

## Requirements

- macOS 14 or later on Apple Silicon (tested on macOS 26.5.1)
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't needed.

## Build and install

```bash
./build.sh
```

```bash
ditto build/RematchBridge.app /Applications/RematchBridge.app
```

```bash
open /Applications/RematchBridge.app
```

On first launch, allow RematchBridge in **System Settings → Privacy & Security → Accessibility**. Without that, macOS drops its keyboard and mouse events. The build is ad-hoc signed, so after every rebuild you have to switch that permission off and on again.

## Profiles

The profiles are JSON files in `~/Library/Application Support/RematchBridge/Profiles/`. Use **Edit Profiles…** in the menu to open the folder; there's a README in it covering every option. Choose **Reload Profiles** after you edit a file. Delete all the files to get the built-in profiles back.

```json
{
  "name": "Streaming (FPS)",
  "buttons": { "a": "space", "rt": "mouse:left", "view": "tab", "guide": "toggle" },
  "leftStick":  { "mode": "keys", "up": "w", "down": "s", "left": "a", "right": "d", "deadzone": 0.25 },
  "rightStick": { "mode": "mouse", "speed": 1.6, "deadzone": 0.1 },
  "triggerThreshold": 0.2
}
```

The back paddles send whatever you assign in Turtle Beach Control Hub (A and B by default).

## Diagnostics

- `build/gipdump 60` prints live button and stick state for 60 seconds. Quit RematchBridge first, since only one program can read the controller at a time.
- `build/make-icon <dir>` regenerates the app and extension icons (run by `build.sh`).
- `./test.sh` runs the unit tests (key parsing, profiles, and decoding of packets captured from the Rematch).
- The log is at `~/Library/Logs/RematchBridge.log` (menu: Open Log).

## Supported controllers

- **Verified:** Turtle Beach Xbox Rematch Advanced Wired Controller (`10f5:711f`).
- **Other wired GIP pads** (USB class `FF/47/D0`, not Microsoft) are picked up too, but they're untested and the Share button is only decoded on verified models.
- **Microsoft controllers** are left to Apple's built-in driver.

## Credits

The GIP protocol details come from the Linux [xpad](https://github.com/torvalds/linux/blob/master/drivers/input/joystick/xpad.c) driver and [OpenJoystickDriver](https://github.com/xsyetopz/OpenJoystickDriver) (MIT). No code was copied from either.
