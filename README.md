# Mustard — end-to-end UI tests on iOS and Android

The same journey as `../test-web`, run on the native app in an iOS simulator or an Android
emulator: sign up, fill in the profile, add household members, income, investments and expenses,
check the Home statement, plan a scenario, ask the assistant for a change, then reinstall the app
(a "second device"), sign in and find everything synced, then sign out and back in. Each step is
a [Maestro](https://maestro.dev) flow in `flows/`, run in order on the same device.

```bash
./run.sh                    # build the app, run every flow, stop the stack
./run.sh --no-build         # reuse the last app build
./run.sh 04 assistant       # only flows whose file name contains one of these
./run.sh --device "iPhone 17 Pro"
./run.sh --up               # stack + app only, for writing flows (Ctrl+C stops it)
```

Each flow is recorded to `videos/<test name>.mp4`, named after the flow's `name:`. Maestro's
screenshots, logs and the screen hierarchy at each step are in `reports/`. A failing flow stops
the run, since later flows build on its data.

## What it needs

- **Xcode 27.** Simulator.app is gone; Device Hub shows the device (`run.sh` opens it with
  `devices://device/open?id=<UDID>`), and `xcrun devicectl` installs the app and records the
  screen (`devicectl device capture screen-record`).
- **Maestro** (`~/.maestro/bin/maestro` or on `PATH`). It drives the app through XCUITest.
  `run.sh` turns off its anonymous analytics.
- **Postgres binaries** (Postgres.app or Homebrew) and **Go**: the stack runs on this Mac, not in
  Docker, because the simulator reaches the backend at `localhost`:
  a private Postgres cluster in a temp folder (port 18191), the stand-in AI model from
  `../test-web/fake-llm` (18192) and the backend from `../customer-data` (18190). All of it is
  removed when the run ends. Override the ports with `E2E_DB_PORT`, `E2E_LLM_PORT`, `E2E_API_PORT`.

The app is a Release simulator build in `../website/ios/build-e2e` (`npm run ios:build` with
`IOS_BUILD_DIR`), pointed at the test backend with `EXPO_PUBLIC_API_URL`. Run without
`--no-build` after changing the website.

## Simulator setup

Before the flows, `run.sh` turns off **password AutoFill** in the simulator's Settings
(`setup/ios-autofill-off.yaml`). With it on, iOS covers the sign-up form with "Use Strong
Password?" and asks to save the password after signing in. Neither prompt is part of the app, so
Maestro can't see or dismiss them. Settings is changed through its UI, which may need updating
when iOS moves the page.

## Writing flows

- Start the stack with `./run.sh --up`; it writes the device and test account to
  `.generated/account.env`. Then run one flow:
  `maestro --device <UDID> test -e EMAIL=… -e PASSWORD=… flows/04-w2-income.yaml`.
  `maestro hierarchy` shows what Maestro can see.
- Fill text fields with `common/fill.yaml`: it scrolls the field to the middle of the screen
  (clear of the keyboard), types, and puts the keyboard away. Maestro's `hideKeyboard` can't close
  a number pad, so `common/hide-keyboard.yaml` drags the page instead (pages dismiss the keyboard
  on drag).
- Selectors are regexes matched against the whole text: escape `( ) $ +`, and quote values that
  contain `: `.
- Open pages from the menu with `common/open-section.yaml` (top-level sections) or
  `common/open-home-page.yaml` (Profile, Settings).
- A field's visible label is hidden from accessibility on native, since the field itself carries
  the label. Each field therefore appears once in the hierarchy, under its label.
- The assistant uses the stand-in model, which only knows the prompts in
  `../test-web/fake-llm/server.py`.

## Android

`run-android.sh` runs the same flows on an Android emulator, with the same options as `run.sh`
(`--no-build`, `--device <AVD name>`, flow name filters, `--up`). It needs the Android SDK
(Android Studio's, or `ANDROID_HOME`), Maestro, and Postgres and Go as above; it builds a
release APK with `npm run android:build` (kept in `.generated/android/`), lets the emulator reach
the backend on its own `localhost` with `adb reverse`, and records each flow through the
emulator's console to `videos/android/<test name>.webm`. Reports go to `reports/android/`. Its
stack uses ports 18290–18292, so it can run at the same time as the iOS one.

What differs on Android, and how the flows deal with it:
- Maestro still sees the page behind the open menu, and the labels above fields, so a menu entry
  is looked for inside the menu (`common/menu-entry.yaml`, via the menu's `testID`), and a
  dropdown by its Android name, "<label>, <value>" (`common/choose.yaml`). Those helpers branch on
  `platform`, so the iOS steps are unchanged.
- A tap straight after launch can land before the app responds; `common/open-menu.yaml` taps the
  menu button until the menu is open.
- Steps that only make sense on one platform are wrapped in `runFlow: { when: { platform: … } }`.
