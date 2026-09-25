# Onyx

Onyx is a native macOS app that turns the screen notch into a compact, customizable workspace for live information and quick controls.

## Features

- Customizable widgets for time, weather, battery, media, timers, and more
- Home panels for music, Bluetooth devices, calendars, notes, Canvas to-dos, flashcards, and utilities
- Media-key, accessibility, and screen-capture controls
- Configurable layouts, shortcuts, appearance, and menu bar behavior

## Requirements

- Apple silicon Mac
- macOS 26 or later
- Xcode Command Line Tools with the macOS 26 SDK

## Build and Run

```sh
./build.sh
open build/Onyx.app
```

To create a disk image:

```sh
./build.sh dmg
```

The app may request macOS permissions for features such as Accessibility, Calendar, Reminders, Bluetooth, and Camera access. Canvas access tokens are stored in the macOS Keychain.

## License

Released under the [MIT License](LICENSE).