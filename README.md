# Onyx

Onyx is a native macOS app that turns the screen notch into a compact, customizable workspace for live information and quick controls.

## Getting Started

This walks you through installing Onyx and opening it for the first time. It takes about five minutes.

### 1. Check your Mac

You need a Mac with Apple silicon (M1 or later) running macOS 26 or later. Onyx AI's free on-device assistant also needs Apple Intelligence turned on in **System Settings › Apple Intelligence & Siri**. You can use Onyx without it, or connect Claude, ChatGPT or Gemini in Settings instead.

### 2. Download and install

1. Open the [latest release](https://github.com/qPublic/Onyx/releases/latest) and download **Onyx.dmg** under **Assets**.
2. Open the downloaded file. In the window that appears, drag **Onyx** onto the **Applications** folder.
3. Eject the Onyx disk in Finder's sidebar.

### 3. Open Onyx the first time

Onyx isn't notarized by Apple yet, so the first time you open it macOS says it can't check the app. You only have to allow it once:

1. Open **Onyx** from your Applications folder. When macOS says it was blocked, click **Done**.
2. Open **System Settings › Privacy & Security** and scroll down to **Security**.
3. Next to "Onyx was blocked to protect your Mac", click **Open Anyway**, then enter your Mac password.
4. If macOS asks one last time, click **Open Anyway** again.

Onyx has no Dock icon. It lives in your notch and in the menu bar, at the capsule icon.

### 4. The welcome window

The first time Onyx opens, a welcome window lists the permissions it can use. Click **Grant** next to each one you want; macOS shows its own prompt for each.

| Permission | What it's for |
|---|---|
| Accessibility | Onyx's volume and brightness display, and keeping the notch clear of app menus |
| Screen Recording | Circle to Search, AI reading your screen, screenshots and recordings |
| Calendar & Reminders | Your calendar in the notch, and letting AI add events and reminders |
| Automation | Showing and controlling Spotify and Apple Music |
| Camera | The Mirror widget |
| Bluetooth | Connecting and disconnecting devices from the notch |
| Location | Local weather and rain alerts |
| Microphone | Talking to Onyx AI (speech is recognized on your Mac) |
| Focus | Showing when a Focus is on |
| Downloads folder | Download progress in the notch |

None of them are required. Skip any you don't want, and grant them later from the menu bar icon › **Set Up Permissions…**. Granting Screen Recording may ask you to quit and reopen Onyx; that's normal, and the welcome window comes back afterward.

Turn on **Open Onyx automatically at login** so it's always there, then click **Take the Tour**. The tour shows every feature in about two minutes.

### 5. Use it

- **Open the notch:** move your pointer to the notch at the top of the screen. It opens into five tabs: **Home**, **Shelf**, **AI**, **Live** and **Tools**.
- **Settings:** click the capsule icon in the menu bar › **Settings…**. The search field at the top finds any setting, even if you don't know its name.
- **Help:** the menu bar icon has **Take the Tour…**, **What's New…** and **Report a Problem…**. You can find them in Settings › Behavior › Help too.
- **Updates:** Onyx checks GitHub for new versions, downloads them in the background, and installs them the next time it starts. **What's New** then shows what changed.

### 6. Set up the extras (optional)

Some features need a little setup in Settings first:

- **Calendar & Mail:** add your Google accounts and email so every calendar shows in one place and events from your email land on it.
- **Academy Sign-Up (TeachMore):** in Settings › Academy Sign-Up, paste your school's TeachMore link, choose a teacher, and Onyx signs you up the moment they post the academy. Turn on **View › Developer › Allow JavaScript from Apple Events** in Chrome first (Safari: **Develop › Allow JavaScript from Apple Events**).
- **Onyx AI with a cloud model:** Settings › Privacy › AI model, where you can paste a key for Claude, ChatGPT, Gemini or another provider.
- **Canvas:** Settings › Live › Canvas connects your school's Canvas so you can see what's due.
- **Live Wallpapers:** menu bar icon › **Live Wallpapers…**, or create your own with AI.

### Something not working?

- **The notch doesn't open:** make sure Onyx is running (look for the capsule in the menu bar). If it isn't, open it from Applications.
- **A feature does nothing:** it probably needs a permission. Open **System Settings › Privacy & Security**, find the matching section (for example Accessibility or Screen Recording), and turn Onyx on.
- **Still stuck:** menu bar icon › **Report a Problem…** opens a GitHub issue you can read before sending.

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