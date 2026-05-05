# WindowLockRecorder

Tiny macOS app for recording one selected window without OBS.

It uses ScreenCaptureKit's window-only capture path, so the recording is locked
to the selected window instead of a fixed screen rectangle.

## Build

```bash
./Scripts/build_app.sh
```

The app bundle is written to:

```text
.build/WindowLockRecorder.app
```

Launch it with:

```bash
open .build/WindowLockRecorder.app
```

## Use

1. Click Refresh Windows.
2. Pick a window.
3. Choose an output `.mov` path.
4. Optionally set a duration in seconds. Leave it blank to record until Stop.
5. Click Record.

`Cmd` + `Shift` + `6` toggles Record/Stop while the app is running.

The first run may require granting Screen Recording permission to the app in
System Settings.
