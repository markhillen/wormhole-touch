# Touch control (Wormhole Touch fork)

AirPlay carries picture and sound from the sender to the receiver only; it has no channel for input
coming back. This fork adds one, so that the Portal's touchscreen can drive the Mac screen it is
showing, much like Sidecar does for an iPad.

It has two parts:

| Part | Where | What it does |
|---|---|---|
| `TouchBridge` | Portal (this app) | Captures touches on the mirrored video, normalises them to the video (0–1) and streams them to any connected helper. Advertised over Bonjour. |
| `PortalTouch` | Mac (`mac-helper/`) | Finds the Portal, turns the touch stream into gestures and posts mouse/scroll events onto the Portal's display. |

## Gestures

| On the Portal | On the Mac |
|---|---|
| Tap | Left click (two quick taps: double-click) |
| Drag | Click-and-drag (move windows, select text) |
| Two-finger drag | Scroll (vertical and horizontal) |
| Press and hold (~0.5 s) | Right click |

## Install

1. Build and install the Android app as usual (see the main README). The touch bridge is always on;
   it costs nothing when no helper is connected.
2. On the Mac:

   ```
   ./mac-helper/build.sh        # optionally: SIGN_IDENTITY="Apple Development: …" ./mac-helper/build.sh
   ./mac-helper/install.sh
   ```

   Then allow **PortalTouch** under System Settings → Privacy & Security → **Accessibility** (it needs
   this to move the pointer and click), and allow **Local Network** access when asked.
3. Connect from Control Center → Screen Mirroring and use the Portal as an extended display or mirror.

`./mac-helper/uninstall.sh` removes the helper. Its log is at `~/Library/Logs/PortalTouch.log`.

## How it works

- The Portal listens on **TCP 7213** and advertises `_wormholetouch._tcp` with a TXT record
  `display=<receiver name>`. (TCP 7100 is taken by UxPlay's mirror data socket.)
- Each touch event is one ASCII line, with coordinates normalised to the visible video:
  - `P <count> <x1> <y1> [<x2> <y2> …]`: fingers still down after the event. `count` 0 means the last
    finger was lifted; its position follows.
  - `C`: the gesture was cancelled.
- The helper acts only while a display with the receiver's name is attached to that Mac (macOS names
  it `<receiver name> (AirPlay)`), and maps the coordinates onto that display's bounds. Taps are
  delayed until it is clear whether they become a drag, a scroll or a long press.

## Security

- The touch stream is unauthenticated and unencrypted. Anyone on the same network can connect to
  port 7213 and see where the screen is being touched, but cannot send input to the Portal.
- A Mac acts on touches only while it is itself showing a display with the Portal's name. A device
  on the network could advertise a fake service under that name and inject clicks onto that display
  while it is connected. Use it on networks you trust, and turn on **Require PIN** so that
  unpaired senders cannot use the receiver.
