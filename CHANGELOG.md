# Changelog

## 1.6.0

### New
- **Sync notes with Apple Notes.** Turn it on from the folder menu in Notes, or in **Settings › Widgets & Tabs › Notes**. Onyx keeps your notes in an "Onyx" folder in Apple Notes, with a subfolder for each Onyx folder. That puts them on your iPhone and iPad too, and edits, new notes, moves and deletions on either side show up on the other.
  - Syncs every 30 seconds while Apple Notes is open, a few seconds after you stop typing in Onyx, and every 15 minutes otherwise.
  - **Nothing gets lost:** if a note changed on both sides, you get both versions. If a note was deleted in Apple Notes but you'd since edited it in Onyx, it's kept. Notes deleted from Onyx go to Apple Notes' Recently Deleted. If most of your synced notes suddenly disappear from Apple Notes, syncing pauses instead of deleting anything.
  - Notes with checklists, pictures, tables or other formatting are read-only in Onyx, with an **Open** button to edit them in Apple Notes. Locked notes are left alone, and your other Apple notes are never touched.
  - The first time, macOS asks to let Onyx control Notes.
- **Ask Onyx AI by voice.** Tap the new mic button in the AI tab and just talk. Your words appear as you speak, and your question sends when you pause. Speech is recognized on your Mac with Apple's on-device model, which downloads the first time you use it. The notch stays open while you're talking.
- **Spoken answers.** Onyx AI reads its answer aloud when you asked by voice. Change this to **Always** or **Off** in **Settings › Privacy › AI**. Every answer also has a speaker button to hear it or stop it, and math like "m∠A" is read as "the measure of angle A".
- **AirPods battery pop-up.** When AirPods, Beats or other Bluetooth headphones connect, the notch shows their battery for a few seconds: one number when both buds match, left and right when they don't, plus the case. Anything at 20% or lower is red.
- **Rain alerts.** A heads-up in the notch like "Rain in ~15 min" or "Snow starting soon" when rain, snow or a storm is about to start where you are and it's dry now. At most once every 3 hours.
- **Sync settings between your Macs.** Turn it on in **Settings › Behavior › Back up & sync** to keep Onyx's settings the same on every Mac signed in to your iCloud account, through iCloud Drive. The first time, if another Mac's settings are already there, you choose which to keep. You can also **Export** your settings to a file and **Import** them later. Notes, Shelf files and permissions stay on each Mac, and passwords (like your Canvas token) are never included.

- **Live Wallpapers.** Your own videos, or one of three animated scenes (Aurora, Liquid Glass and Night Sky), playing behind your desktop icons. Open it from the menu bar icon › **Live Wallpapers…** or the notch's ••• menu.
  - **Add your own videos:** MP4 or MOV, from **Add Videos** or by dropping them on the window.
  - **Every display:** the same wallpaper everywhere, or a different one per display.
  - **Shuffle** every 15 minutes, hour or day, and pick a different wallpaper **after sunset**, based on where you are.
  - **Uses almost nothing:** about 0% CPU. It pauses when the desktop is covered, behind fullscreen apps, while your Mac is locked or asleep, and in Low Power Mode. It can also pause on battery. Videos never keep your screen awake.
  - **Match my desktop picture** optionally sets a still as your real desktop picture, so the lock screen and Mission Control match, and puts your old picture back when you turn it off.
- **Enhance with AI.** Right-click a video wallpaper › **Enhance with AI…** to make it smoother and sharper, all on your Mac with Apple's video models. Frame interpolation takes it to 60 or 120 fps. Super resolution upscales it 4×, for example 720p to 5K. The upscaling model downloads once. Your original stays in the library, and enhanced copies play without sound.
- **Game-style scene pack.** Five new animated wallpapers drawn live by your Mac's graphics chip: **Neon Horizon** (an 80s synthwave sunset over a neon grid), **Rain City** (a night skyline scrolling past in the rain), **Pixel Dusk** (a pixel-art sunset over the sea), **Hyperspace** and **Code Rain**. They stay sharp on any display and pause when nobody can see them.
- **Create with AI.** In Live Wallpapers, describe any game's world, a place or a mood, and Onyx makes it into a looping live wallpaper. Apple Intelligence plans it and picks the effects, Image Playground paints four versions to choose from, and Onyx brings the one you pick to life: near things drift against far things, with rain, snow, embers, fireflies, twinkling stars, fog, falling leaves or petals, dust, bubbles or wind. The motion is gentle on purpose: near things slide in front of far ones as solid shapes, effects sit behind whatever is in front of them, and photo-like loops get a touch of film grain, so it looks filmed rather than generated. The loop is sharpened to your screen's resolution and repeats seamlessly. You can also bring your own picture to life, like a game screenshot. Everything happens on your Mac.
- **Art styles for Create with AI.** Pick **Realistic**, **Anime**, **Painted**, **Animated** or **Illustration**. Realistic, Anime and Painted are painted on your Mac by Stable Diffusion models made for each look (a one-time 2 GB download per style, which you can remove again); Animated and Illustration use Image Playground.
- **Feature tour.** The end of onboarding is now a tour that plays a short live demo of each feature: the notch, music, the Shelf, Onyx AI, Circle to Search, widgets, notes, snap layouts, Live Wallpapers, Create with AI, the App Launcher and Optimization. Watch it again any time from the menu bar icon › **Take the Tour…**.
- **App Launcher.** Every app in a full-screen Liquid Glass grid, like Launchpad, which macOS Tahoe removed. Open it from the menu bar icon › **App Launcher** or the notch's ••• menu, or give it a keyboard shortcut in **Settings › Behavior › Shortcuts**. The search field is ready as soon as it opens, so you can just start typing.
  - **Pages:** swipe, scroll or use the arrow keys, with page dots at the bottom.
  - **Folders:** drop one app onto another to make a folder, named for what's in it. Drop onto a folder to add, click a folder to open and rename it, and drag an app out to take it out.
  - **Your order:** drag apps to rearrange them, or drop one on a page dot to move it to that page.
  - **Search as you type:** press Return to open the best match.
  - Right-click an app to show it in Finder or hide it from the launcher. Esc or clicking outside closes it.
- **⌘Space can open the App Launcher.** A switch in **Settings › Behavior › Shortcuts** moves Spotlight to ⌥⌘Space and gives ⌘Space to the launcher. Turning it off puts Spotlight back the way it was.
- **Onboarding asks for everything up front.** Setup now includes Location, Microphone, Focus and Downloads folder access, plus optional switches for Apple Notes sync and settings sync. **Settings › Privacy** lists every permission with a shortcut to its System Settings page.

### Improved
- **Much more accurate weather.** Onyx now uses your Mac's location, if you allow it, instead of guessing from your internet connection, which can be tens of kilometers off or wrong on a VPN. It's rounded to about 1 km before being sent to weather services.
- **Current conditions from the closest weather station.** The temperature and conditions "now" come from the closest station that reported in the last 90 minutes: US National Weather Service stations, or airport weather reports anywhere in the world. If none is within 20 km, Onyx uses the forecast model for your exact spot. **Settings › Live › Weather** shows which station it's using and how far away it is.

## 1.5.2

### Improved
- **Built-in notch: menus and menu bar icons stay uncovered.** When an app's menus or the menu bar icons are right next to the camera:
  - The closed notch's side widgets fold away.
  - Live activities (timers, downloads, reminders, messages and the compact volume/brightness HUD) hang just below the camera instead of spreading over the menu bar. They only widen past the camera where there's free space.
- **Hidden header widgets show a "+2" button.** If some of your widgets don't fit next to the camera, a small button shows how many are hidden. Click it to remove any of them.
- **Settings explains the width limit.** On a Mac with a built-in notch, **Size & Position** shows how wide the open notch needs to be to fit around the camera.

### Fixed
- The built-in notch notes in Settings now update right away when you plug in or unplug a display.

## 1.5.1

### Improved
- **Macs with a built-in notch.** Onyx now works around the camera:
  - The closed notch always stays black so it blends in, even with Liquid Glass or Frosted. Your style shows once it opens.
  - It opens around the camera, with your tabs on the left and the clock, widgets and buttons on the right. Nothing ends up behind the camera: header widgets that don't fit are left out, and the open notch gets a little wider if it needs the room.
  - It always stays centered on the camera and is never smaller than it. The horizontal offset setting only applies to Macs without a notch.
  - When an app's menus reach the notch, the side widgets fold away instead of the notch sliding off the camera.
  - The Center widget for the closed notch is hidden, since it would sit behind the camera.

## 1.5.0

### New
- **Automatic updates.** Onyx now checks GitHub for new versions, downloads them in the background, and installs them the next time Onyx starts or when you quit it. The notch lets you know when an update is ready and again after it's installed. To install right away, use **Restart Now** in **Settings › Behavior › Updates** or **Restart to Install** in the menu bar icon's menu. You can turn automatic updates off in Settings, and **Check Now** (or **Check for Updates…** in the menu bar icon's menu) checks on demand.
  - **Safe by design:** an update is only installed if it's signed with the same certificate as your copy of Onyx and is a newer version. Anything else is deleted. Because the signature stays the same, macOS keeps your Accessibility and Screen Recording permissions.
  - Updates come from this repo's latest GitHub release, over HTTPS.

## 1.4.0

### New
- **AI effort.** Choose how hard Onyx AI works with the new gauge button in the AI tab (also in **Settings › Privacy › AI**):
  - **Low:** fastest, short answers
  - **Medium:** the default
  - **High:** works the problem out step by step before answering
  - **Max:** makes three separate attempts, and if two agree on the answer it uses that one
  Higher effort is slower but gets harder questions right more often.
- **Ask about any image.** Use the new 📎 button in the AI tab to capture an area of the screen, choose an image, or paste one, or just drag an image onto the AI tab. Onyx reads it with on-device image recognition:
  - text in reading order
  - tables, as rows and columns (High and Max)
  - QR codes and barcodes
  - what's in the picture, plus people, faces and animals
- **Built-in calculator for the AI.** On High and Max effort, and in Agent mode, Onyx AI checks its arithmetic with an exact calculator. The calculator can also solve equations like 5x + 30 = 180, so math answers are right more often.
- **Circle to Search → Ask AI.** Circling something now shows an **Ask AI** button that opens the AI tab with the image attached. "Explain this with AI" also solves circled problems, and uses your effort setting.

### Improved
- **Math symbols are read correctly.** Onyx checks the actual shape of symbols that screen text reading gets wrong, so ∠ is no longer mistaken for <, and ≤, ≥, ≅, √ and ° come through correctly. That means geometry problems on your screen or in images make sense to the AI.
- **Answers are plain text.** They no longer include raw LaTeX like `\[ … \]`.
- **Long conversations recover.** If a chat gets too long for the on-device model, Onyx retries automatically with a fresh, shorter request instead of giving up.

## 1.3.0

### New
- **Onyx reminders.** Ask Onyx AI things like "remind me to call mom in 20 minutes" or "remind me to study at 7". When a reminder is due, the notch shows a bouncing orange bell with the reminder and plays a sound. It stays until you open the notch and choose **Done** or **Snooze** (5 minutes to 1 hour). Reminders that came due while your Mac was asleep go off as soon as it wakes. You can also ask the AI to list or cancel your reminders. To add something to Apple's Reminders app instead, mention "Reminders app".
- **Optimization**, inspired by OnyX, in its own window. Open it with the new gauge button in the notch (between the pin and the gear) or from the menu bar icon › **Optimization…**. Searching in Settings for things like "dns" or "hidden files" also opens it at the right page.
  - **Overview:** disk space and memory at a glance, plus **Quick Optimize**, which moves app caches and old logs to the Trash. You can also turn on a low-disk-space warning in the notch and a weekly clean.
  - **Clean:** scans caches, logs and Xcode build files and shows how big each one is. You choose what to remove, and it all goes to the Trash so you can put anything back. There's also an **Empty Trash** button.
  - **Maintain:** one-click fixes: flush the DNS cache, free up memory, rebuild the "Open With" menu, rebuild Spotlight, reset Quick Look, clear font caches, restart Finder, Dock or the menu bar, and check your startup disk. Tasks that need your Mac password ask for it in macOS's own window, and Onyx never sees it.
  - **Tweaks:** hidden macOS settings for Finder, the Dock, screenshots, speed and save dialogs, such as showing hidden files, an instant Dock, screenshot format and location, or faster key repeat. Each shows its current value, and **Reset all tweaks** undoes everything you changed. Security settings are never touched.
  - **Startup:** see which apps use the most CPU or memory right now, and what runs in the background. You can turn your own background items off and on again.
  - **Quit apps with no windows:** Onyx can quit an app once it has had no windows for a time you choose (1–60 minutes), like closing the last window on Windows. Minimized windows and windows on other desktops count as open. Finder, the app you're using, music that's playing and apps on your "Never quit" list are never quit. It's off by default, and you'll find it under Optimization › Startup.
  - **"Using the most right now"** measures memory the way Activity Monitor does, including each app's helper processes.
  - **Storage:** find files over 500 MB and downloads you haven't opened in 90+ days, then show them in Finder or move them to the Trash.

## 1.2.1

### Fixed
- **Settings shows the right version number.** It said "Version 1.0" no matter which version was installed.

## 1.2.0

### New
- **Snap layouts.** Drag a window up to the notch to choose a layout: halves, **top/bottom** (new), ⅔ + ⅓, thirds, quarters, one big window with two small ones stacked beside it, full screen or centered. While you hover over a layout, a see-through outline shows where the window will land. You can turn this off in **Settings › Behavior › Snap layouts**.
- **The dancing cow dances to the beat.** It matches its steps to the tempo of the song playing in Spotify or Apple Music, and very fast or slow songs get a half-time or double-time dance. The tempo is looked up by song title and artist on Deezer. Songs Deezer doesn't know get the normal dance. You can turn this off in **Settings › Widgets › Home boxes › Dance to the beat**.

### Improved
- **Lower CPU and battery use.** The notch no longer redraws twice a second in the background when no focus timer is running.
- Clicking elsewhere on your Mac no longer makes Onyx do any work. Snap layouts only starts checking once you actually drag a window.
- If another app freezes, Onyx can no longer get stuck waiting on it. Checks involving other apps now give up after half a second instead of 6 seconds.
- **Sports scores** update every 30 seconds only while the Live tab is open or one of your favorite teams is playing. Otherwise they update every 5 minutes.
- **Stock prices** are only downloaded while something on screen shows them: the ticker, the Watchlist box, a stock widget or the Live tab.
- **Download progress** checks your Downloads folder less often while nothing is downloading.
- Background timers are grouped together so your Mac wakes up less often.
- **Tabs** switch after you rest on them for a moment (0.15s), so moving the pointer across the tab bar no longer flips tabs by accident. Clicking still switches right away.
- **The File Shelf stays open** when you click somewhere else or switch apps, so you can drag files in and out without it disappearing. Close it with the new **×** button. You can turn this off in **Settings › Widgets › File Shelf**.

### Fixed
- **Onyx AI no longer does things you didn't ask for.** Previously it could, for example, make up a calendar event when asked a math question. Each action now only runs if your message asks for it (calendar events need words like "calendar", "meeting" or "event"), and it won't create events or reminders with titles you didn't give it. Its answers are also steadier.
- **Math and unit questions in Onyx AI are answered instantly by the calculator**, for example "what is 32/40", "15% of 80" or "5 ft in cm". These work even without Apple Intelligence.

## 1.1.0

### New
- **Editable tab bar.** You can now rearrange the tabs on the left of the notch (Home, Shelf, AI, Live, Tools). Open ⋯ › **Edit Tabs & Widgets**, then:
  - drag a tab to move it
  - tap the red **−** to hide a tab
  - use the blue **+** to bring a hidden tab back
- You can also reorder tabs in **Settings › Widgets › Tabs** with the new ↑/↓ arrows.

### Fixed
- **Hide while an app is fullscreen** now works on MacBooks with a notch. Onyx now asks macOS whether an app is fullscreen, so the notch hides in fullscreen videos, games and apps and comes back when you leave fullscreen.

## 1.0.0

- First release.
