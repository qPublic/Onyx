# Changelog

## Unreleased

### New
- **Snap layouts.** Drag a window up to the notch to choose a layout: halves, **top/bottom** (new), ⅔ + ⅓, thirds, quarters, one big window with two small ones stacked beside it, full screen or centered. While you hover over a layout, a see-through outline shows where the window will land. You can turn this off in **Settings › Behavior › Snap layouts**.

### Improved
- **Lower CPU and battery use.** The notch no longer redraws twice a second in the background when no focus timer is running.
- Clicking elsewhere on your Mac no longer makes Onyx do any work. Snap layouts only starts checking once you actually drag a window.
- If another app freezes, Onyx can no longer get stuck waiting on it. Checks involving other apps now give up after half a second instead of 6 seconds.
- **Sports scores** update every 30 seconds only while the Live tab is open or one of your favorite teams is playing. Otherwise they update every 5 minutes.
- **Stock prices** are only downloaded while something on screen shows them: the ticker, the Watchlist box, a stock widget or the Live tab.
- **Download progress** checks your Downloads folder less often while nothing is downloading.
- Background timers are grouped together so your Mac wakes up less often.
- **Tabs** switch after you rest on them for a moment (0.15s), so moving the pointer across the tab bar no longer flips tabs by accident. Clicking still switches right away.

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
