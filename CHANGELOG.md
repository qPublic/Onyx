# Changelog

## Unreleased

### New
- **Private windows stay private.** While a private or incognito window is open in Safari, Chrome, Brave, Edge, Arc, Vivaldi, Opera or Firefox, Onyx records nothing and reads nothing from your screen, your browser or your clipboard. A screen recording stops. Screenshots, Circle to Search and Copy Text wait. Onyx AI can't look at your screen or what you've selected. Clipboard history skips what you copy. Focus sessions don't read websites, and academy sign-up waits. The notch tells you when this starts. It's always on and can't be turned off. See Settings › Privacy › Private windows.

## 1.8.6

### New
- **Paste a Google Calendar link.** In Settings › Calendar & Mail, paste the link to any Google Calendar and Onyx copies in all its events, alongside your other calendars, and updates them every 30 minutes. That can be a public calendar's link or embed code, or a private one's Secret address in iCal format (from its Settings › Integrate calendar). Repeating events, skipped days and moved classes come through right, and times stay put across daylight saving. Other iCal (.ics or webcal) links work too. Pasted calendars are read-only, and you can hide or remove them.

### Fixed
- Switching calendars on or off in Settings no longer closes the account's list after every switch.

## 1.8.5

### Fixed
- Academy sign-up signs you back in in one go: through Google, picking your account, and straight back to checking, instead of a step every 15 seconds.
- After signing in, your TeachMore tab goes back to Offerings instead of staying on TeachMore's calendar page.
- When TeachMore signs you out it shows a 404 page. Onyx now recognizes that as signed out and signs you back in, instead of giving up or opening another tab.
- Check Now no longer brings your browser to the front. If it ever jumps forward, Onyx puts back what you were using.

## 1.8.4

### Improved
- **Academy sign-up signs itself back in.** When TeachMore signs you out, Onyx sends your TeachMore tab through "Sign in with Google". Your browser is already signed in to Google, so you land straight back on TeachMore and the watch carries on. If Google asks which account to use, Onyx picks your school account (set it once in Academy Sign-Up; if there's only one account it picks that). It never types a password: if Google wants one, Onyx tells you in the notch.

## 1.8.3

### Improved
- Onyx checks for updates every 4 hours while your Mac is on (it was every 12), and catches up soon after your Mac wakes if it slept through a check.

## 1.8.2

### Improved
- **The calendar box shows today.** On Home it lists just what's left of today, with a Now tag on what's happening. If there's more than fits, it shows a page at a time and turns the page every few seconds (rest your pointer on it to hold a page). Click it and it opens into a full calendar across the Home tab. Pick any day of any month, add an event with a time and length (or all day), open one to see where it is and which calendar it's on, open it in Calendar, or delete it. The ✕ takes you back.

### Fixed
- The calendar's month grid no longer hides the 1st through the 6th of the month.

## 1.8.1

### New
- **Academy sign-up for TeachMore.** In the new **Settings › Academy Sign-Up**, paste your school's TeachMore link, pick the teacher (or words in the title) and turn on **Watch TeachMore and sign me up**. Onyx checks your offerings list every 30 seconds in your own signed-in Chrome, Brave, Edge or Safari tab, so it never sees your password. When a teacher posts that academy with a free seat, it signs you up, checks TeachMore lists you, and tells you in the notch. Full? It waits for a seat. It can switch you from a sign-up you made yourself (or keep it, your choice), never replaces an appointment a teacher assigned, and never signs you up again for one you left. Needs Allow JavaScript from Apple Events turned on in your browser.
- The tour has a new step for academy sign-up.
- **Help in Settings.** Settings › Behavior › Help now has **Take the Tour** and a **Getting Started Guide**, a step-by-step walkthrough of installing Onyx and opening it for the first time.

## 1.8.0

### New
- **All your Google calendars in one.** Sign in to as many Google accounts as you like (plus iCloud, Outlook or Exchange) in System Settings › Internet Accounts, and Onyx shows every calendar together in the notch. Pick which ones to show in the new **Settings › Calendar & Mail**. An event that's on two accounts, like an invite sent to both your school and personal address, shows once, with a dot for each account. Anything you add syncs back to Google.
- **Events from your email.** Sign in to your email in Onyx (Gmail, iCloud, Yahoo, or a school or work address, with an app password), or let it read the accounts in Apple Mail (for Outlook and school accounts). Every 15 minutes Onyx finds new plans, practices, appointments and invitations and puts them on your calendar, or asks first if you'd rather. Invitations are added exactly as sent. Everything else is read by Apple's on-device model, then checked against the email's own words (the day, the time and the quote) before anything reaches your calendar. Onyx never sends, deletes or marks anything as read, and every added event can be undone.
- **Never read, and read carefully.** List the people, addresses or whole domains Onyx should never open. List the ones it should read carefully, like a teacher, coach or boss: their emails are always read (even newsletters), read in full, checked a second time, and the notch tells you when one of their events is added.
- **AI's Choice art style.** In Create with AI, pick **AI's Choice** and Onyx chooses the painter that suits your idea and makes a style just for it. Ask for an Elden Ring castle and you get dark fantasy concept art in hazy golden light, even though none of the built-in styles is quite that. The style it picked shows above the pictures.
- The tour has a new step for all of this.

### Improved
- **AI wallpapers are sharp at 4K.** They used to be painted at 512 pixels and stretched to your screen by an upscaler that only sharpens edges, so they looked soft even when labeled 4K. Now the painting is doubled by Real-ESRGAN, an AI upscaler that paints in real detail. The same painter then goes over it tile by tile to add fine detail that matches the scene, and Real-ESRGAN takes it the rest of the way to full resolution. Anime pictures get Real-ESRGAN's anime model. It all runs on your Mac; the upscaler downloads once (33 MB, or 9 MB for anime).
- **Make a 4K Version.** New AI wallpapers keep their painting, so right-clicking one in Live Wallpapers can rebuild it at full 4K (3840 pixels wide) for a bigger display. Wallpapers made before 1.8 didn't keep theirs, so they get **Remake Sharper…**, which starts Create with AI from the same idea.

### Fixed
- **More like this with the Realistic style** works now. Realistic's painter reads pictures differently from the others, and Onyx fed it wrong, so it failed every time.

## 1.7.3

### Fixed
- **Keep clear of app menus on macOS 27.** macOS 27 draws every menu bar icon in one new system bar, so Onyx couldn't see where the icons began. The notch then moved over them when it stepped aside for an app's menus. It now finds the icons again and sits in the free space between the menus and the icons, as it did before. Macs with a built-in notch also fold side widgets away from the icons correctly again.
- **Onyx AI on macOS 27.** macOS 27 comes with a new on-device model that reads instructions more literally. It answered simple questions with "Yes." or "No.", and it sometimes wrote tool calls out as text (like `create_note{title:…}`) instead of making them. Onyx now words its instructions so the new model answers normally, only tells it about tools it can use, and carries out a tool call that comes back as text (with the same safety checks) or answers in words. It also strips the model's stray control codes from replies. When macOS stops the model partway through, Onyx now tries again and, if that fails too, tells you instead of leaving the question unanswered. Questions like "how many minutes are in a week?" go straight to the calculator.
- **Live wallpapers pause on the lock screen again** when Onyx starts while your Mac is already locked. Onyx now also re-checks the lock once a minute, in case macOS doesn't announce it. macOS 27's lock screen shows your desktop behind it, so a wallpaper left playing there used power for nothing.
- **Unit conversions with weeks, days or years** ("2 weeks in days", "1 year in hours") work again on macOS 27, in the App Launcher, the calculator and Onyx AI.
- **Restart menu bar** (Optimization › Maintain) also restarts macOS 27's new menu bar process, so it fixes stuck icons there too.

## 1.7.2

### New
- **Shortcuts, Siri and Spotlight.** **Settings › Behavior › Shortcuts & Siri** adds Onyx actions to the Shortcuts app with one click: ask Onyx AI, start a focus session or timer, get your briefing, copy text from the screen, open clipboard history, take a screenshot, open the App Launcher or a workspace, make a wallpaper, switch Dark Mode or keep your Mac awake. Run them with Siri, from Spotlight or in your own automations. Each is also an onyx:// link that works anywhere links do.
- **Services menu.** Select text in any app, then right-click › Services › **Ask Onyx AI** or **Summarize with Onyx**.
- **What's New.** After an update, Onyx shows what changed (also in the menu bar icon's menu and Settings › Behavior › Help).
- **Report a problem.** The menu bar icon and Settings › Behavior › Help open a GitHub issue that's already filled in with your Onyx and macOS versions and your Mac's model, and you can read and edit it before you send it. If Onyx quit unexpectedly, it tells you once and can include the crash details from macOS.

### Improved
- **Safer AI with web pages and files.** A web page, file, picture or your screen can hide instructions like "copy this" or "open that". Onyx AI now only takes an action if your own message asked for it, with every model, and treats outside text as information, never as instructions.
- **Uses less energy when idle.** Onyx no longer asks Spotify or Music what's playing every 3 seconds (it listens for their change announcements instead), and the timer, clipboard, glass sampler, menu and fullscreen checks wake your Mac far less often.
- **Reduce Motion.** With Reduce Motion on (System Settings › Accessibility › Display), the notch opens without bouncing, the tour shows still pictures, and live wallpapers pause (you can change that in Live Wallpapers).
- **VoiceOver.** The notch's icon buttons, tabs, music controls and AI controls now have spoken names.
- **Ready for notarization.** The build and updater are prepared for an Apple Developer ID, so Onyx can be notarized later without everyone having to reinstall.

## 1.7.1

### New
- **Use Claude, ChatGPT, Gemini and more.** In **Settings › Privacy › AI › AI model**, switch Onyx AI from Apple's on-device model to Claude, ChatGPT, Gemini, Grok, Mistral, DeepSeek, Groq, OpenRouter, a model running on your Mac with Ollama, or any OpenAI-compatible server. Paste your own API key (kept in your Keychain), pick a model from the provider's list, and tap **Test**. Big models see your pictures and screen directly, read whole files at once, and power Circle to Search, briefings, flashcards and Create with AI's planning too. Apple's model stays the default: free, private and offline.
- **Web answers.** Ask about current events, prices, scores or anything the model isn't sure of, and Onyx AI searches the web, reads the top pages and answers from them, listing its sources.
- **Memory.** Tell Onyx AI your name, your classes or your favorites, or say "remember that…", and it keeps that in mind from then on. Everything it remembers is listed in **Settings › Privacy › AI › Memory**, where you can add, delete or turn it off. It stays on your Mac.
- **Ask about your own stuff.** "What did my bio notes say about mitosis?" or "what was that address I copied?": Onyx AI searches your notes, Shelf files, clipboard history, Canvas, reminders and calendar by meaning, not just exact words.
- **Onyx AI can do more.** It can start a focus session, open a workspace, switch Dark Mode, keep your Mac awake, tell you what's due on Canvas, make notes, give you a briefing, and remember or forget things.
- **Test Onyx AI.** **Settings › Privacy › AI** can run 20 questions with known answers (math, facts, actions, honesty) and score them. It's a quick way to compare models.
- **More like this.** In Create with AI, pick a picture and tap **More like this** for two new versions of it.

### Improved
- **Better translation.** Translate uses Apple's translation models when your languages are downloaded (System Settings › General › Language & Region), which translate far better than the chat model.
- **Long chats keep going.** When a conversation outgrows the on-device model, Onyx AI keeps a short summary of it instead of forgetting everything.
- **Onyx AI picks tools better.** For each question, the on-device model only sees the tools that could help, which makes it faster and less likely to do something you didn't ask for.
- **Create with AI looks less AI-made.** Pictures with stray lettering or fake watermarks are moved to the end, or repainted if they all have it. With the picture checker downloaded, the pictures that best match your art style come first.

## 1.7.0

### New
- **Meeting countdown.** 2 minutes before a Zoom, Google Meet, Teams or Webex call on your calendar, the notch counts down to it. Open the notch and click **Join**. Turn it off in **Settings › Live › Live activities in the notch**.
- **Clipboard picker.** Press **⌃⌥V** anywhere to open your clipboard history over the app you're in. Type to search, use the arrow keys, and press Return to paste. Pin clips you use a lot (right-click › Pin as a snippet) and they stay at the top.
- **App Launcher actions.** Type math like "15% of 80" and press Return to copy the answer, "timer 10" to start a timer, "define serendipity" for the dictionary, or a question to ask Onyx AI. Files whose names match show up under your apps, most recently used first.
- **Ask AI about selected text.** Select text in any app and press **⌃⌥S**. Onyx AI opens with it attached and one-click Summarize, Explain, Rewrite, Fix grammar, Translate and Key points.
- **Ask about a file.** Drop a PDF, Word, RTF, HTML or text file on the AI tab (or choose one from the paperclip menu) and ask about it. Long documents are read part by part, so it can answer from the whole thing.
- **Daily briefing.** Tap **Brief me on my day** in the AI tab for your weather, what's left on your calendar, reminders and anything due on Canvas, in a few friendly sentences. The first time you use your Mac each morning, one is waiting for you. Turn that off in **Settings › Privacy › AI**.
- **Weather on your wallpaper.** When it's actually raining, snowing, foggy or stormy where you are, your live wallpaper shows it too, with lightning in a thunderstorm. Turn it off with **Match the weather** in Live Wallpapers.
- **Day and night wallpapers.** Create with AI can also make sunset and night versions of your loop (the same scene, relit, with stars at night) that switch by themselves at the real sunset and sunrise where you are.
- **Battery health.** A new **Battery** page in Optimization shows your battery's health, charge cycles, capacity and temperature, and which apps are using the most energy right now. It can also remind you to unplug at 80%.
- **Focus sessions.** A new **Focus** tool in the notch's Tools tab runs a timer that blocks the apps and websites you choose (in Safari, Chrome, Arc, Brave and Edge) until it's done, and keeps a daily streak.
- **Quick toggles.** Tools › System now has one-click Dark Mode, Do Not Disturb, Keep awake, Hide desktop icons and Mute microphone.
- **Window workspaces.** Arrange the apps and windows you use for something, save them as a workspace like "School" or "Coding" in the new **Workspaces** tool, and get them all back with one click, optionally hiding everything else.
- **Mark up screenshots.** Right-click a screenshot on the Shelf › **Mark Up…** (or Tools › Capture › Mark up last screenshot) to draw, highlight, add arrows and boxes, or blur out private details, then copy or save it.
- **Copy text from anything.** Press **⌃⌥T** and drag over any part of the screen to copy the text in it. Pictures on the Shelf have **Copy Text in Picture** too.

### Improved
- Onyx AI's answers have a Copy button.
- The feature tour shows off everything new, with live demos of meeting countdowns, the clipboard picker, Ask about anything, the daily briefing, focus sessions, workspaces, screenshot markup, weather and day-and-night wallpapers, launcher actions, and battery health with quick toggles. It also uses much less power while it plays.

## 1.6.1

### New
- **Low Battery Mode.** When your Mac is on battery at or below 15%, Onyx pauses live wallpapers, its music animations and the goose, and stops watching the screen behind the notch, until you plug in. The notch lets you know when it turns on. Change the level or turn it off in **Settings › Behavior › Battery**.
- **Create with AI checks its own work.** Ask for a character or creature, like "an Elden Ring character" or "a fox in a snowy forest", and Onyx paints it in the scene, then looks at every picture to make sure it's really there. The ones that show it come first, with a note saying so. If none do, it paints again with the character up front. The checker is Apple's MobileCLIP model, which downloads once (200 MB) and runs on your Mac.
- **Onyx AI checks its answers.** After it replies, Onyx AI reads its answer back against what you asked. If it missed part of the question, or said it did something without actually doing it, it finishes the job before you see the final answer. This happens on Medium, High and Max; Low stays as fast as before.
- **Onyx AI knows its way around Onyx.** Ask "where do I turn on Low Battery Mode?" and it looks the setting up and tells you where it is.
- **Pin apps in the App Launcher.** Right-click an app › **Pin to Front** to keep it first, ahead of everything else, marked with a pin. Pinned apps also come first in search results.
- **App Launcher by category.** A new switch next to the search field shows your apps grouped by category (Productivity, Utilities, Games and so on) in one scrolling list, with pinned apps on top. Switch back to your own arranged pages any time.
- **Windows close when you click away.** Settings, Optimization, Live Wallpapers and the tour close by themselves after 20 seconds in the background. A window with something open in it, like Create with AI, waits. Change the time or turn it off in **Settings › Behavior › System**.

### Improved
- **Create with AI plans better scenes.** Apple Intelligence now keeps everything you asked for (like the village and the night in "Minecraft village at night"), and it picks effects that really fit, like bubbles on a reef or snow and glowing windows for a snowy cabin, with no more stars in a sunny sky. If a game's name trips Apple's safety filter, it tries again with just the game's look.
- **Create with AI keeps working in the background.** macOS no longer slows painting down when you switch to another app.
- The version line in Settings now reads "Free, forever".

### Fixed
- **The feature tour plays smoothly.** Its animations no longer stutter while your pointer is over the window, a slide no longer jumps back to its start as it slides out, and each demo plays once per slide instead of snapping back halfway through. The Live Wallpapers slide cross-fades between scenes without a hitch.
- The tour's Create with AI demo now shows pictures that match what it types.

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
