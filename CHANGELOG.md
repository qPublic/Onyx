# Changelog

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
