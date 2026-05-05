# WindowLockRecorder

Tiny macOS app for recording one selected window without OBS.

It uses ScreenCaptureKit's window-only capture path, so the recording is locked
to the selected window instead of a fixed screen rectangle.

## Build

```bash
make package
```

The app bundle is written to:

```text
dist/WindowLockRecorder.app
```

Install it like Magnify:

```bash
make install
open /Applications/WindowLockRecorder.app
```

## Use

1. Click Refresh Windows.
2. Pick a window.
3. Optionally set a duration in seconds. Leave it blank to record until Stop.
4. Click Record.

Recordings are saved automatically to Desktop with a timestamped `.mov`
filename based on the selected app/window.

`Cmd` + `Shift` + `6` hides/unhides the app window while the app is running.

The first run may require granting Screen Recording permission to the app in
System Settings.
