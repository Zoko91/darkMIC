# DarkMic

Ultra-lightweight native macOS menu bar app that turns off the Corsair HS80 MAX live (white/blue) microphone LED while preserving the red mute LED — without iCUE.

## Supported Hardware
- **Corsair HS80 MAX Wireless** (`0x1B1C:0x0A97`, Bragi HID protocol, Usage Page `0xFF42`)

## Behavior
- **Mic down (live)**: Mic LED **off** (`RGB 0,0,0`) — no distracting white/blue glow
- **Mic up (muted)**: Mic LED **red** (`RGB 255,0,0`) — preserves clear mute feedback
- **Event-driven & works during display sleep**: reacts instantly to hardware HID notifications (`prop 0xA6`) with App Nap disabled (`userInitiatedAllowingIdleSystemSleep`), without blocking display or system sleep
- **Minimal footprint**: pure Swift (`AppKit` + `IOKit`, zero dependencies, no Swift concurrency thread pool), ~130 KB binary, ~0% idle CPU
- **Launch at Login**: built-in toggle (`~/Library/LaunchAgents/com.darkmic.app.plist`)
- **Coexists with PowerLevel** via non-exclusive HID access

## Build & Install

```bash
chmod +x scripts/bundle.sh
./scripts/bundle.sh
cp -R build/DarkMic.app /Applications/DarkMic.app
open /Applications/DarkMic.app
```
