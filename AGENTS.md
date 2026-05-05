# Repository Guidelines

## Development Install

After any code or app-behavior change, replace the installed app before handing the work back:

```bash
make install
```

This packages the current build, replaces `/Applications/WindowLockRecorder.app`, refreshes Launch Services, resets Screen Recording permission when `RESET_TCC=1`, and relaunches the app when it was already running.

For documentation-only changes, `make install` is not required unless the user explicitly asks for the installed app to be refreshed.
