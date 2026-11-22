# Atoll — Dynamic Island research

Research done 22 Nov 2026. Every number below cites a source. **[EST]** marks an estimate or a value tuned by eye rather than published by Apple.

## 1. States (Apple HIG, Live Activities)

Source: Apple HIG "Live Activities" — https://developer.apple.com/design/human-interface-guidelines/live-activities

- **Compact**: used when *one* activity runs. Two separate elements, **leading** and **trailing**, on either side of the TrueDepth camera.
- **Minimal**: used when *several* activities run. One attaches to the island; a second (and a third "when supported") appears **detached** as a circle or oval on one or both sides.
- **Expanded**: shown when people **touch and hold** a compact/minimal activity, or when the system expands it to alert about an event. Tap opens the app.
- Limited-width mode (landscape): compact/minimal content should fit a **28 pt circle**; leading-only is allowed and the trailing view is hidden.
- WWDC23 "Design dynamic Live Activities" (https://developer.apple.com/videos/play/wwdc2023/10194/): three size classes (compact, expanded, minimal); "as narrow as possible with no wasted space", content snug to the sensor; avoid a "forehead" above content in expanded; expand to alert instead of sending a notification; content must be **concentric** with the island (even margins, use ContainerRelativeShape); separate blocks with an inset shape or a thick line, never draw to the edge; extra-rounded thick shapes, large heavy-weight text, colour for identity.
- Motion intent (same talk): "Inspired by biological form and motion, the Dynamic Island is designed to feel like a living organism, with a deliberate elasticity". Apps "swoop up" into the island when you leave them.
- Recommended transitions inside: `.contentTransition(.numericText())` for counting numbers, content-replace transitions for swapping glyphs/text; custom = scale + opacity + position.

## 2. Dimensions (points)

Apple HIG table (iOS dimensions):

| Presentation | 393×852 screens | 430×932 screens |
|---|---|---|
| Compact leading / trailing | 52.33 × 36.67 | 62.33 × 36.67 |
| Minimal | 36.67–45 × 36.67 | 36.67–45 × 36.67 |
| Expanded | 371 × 84–160 | 408 × 84–160 |

- Island width in compact/minimal: **230 pt** (Pro / base) and **250 pt** (Pro Max / Plus / Air). Expanded: **371 / 408 pt**.
- Corner radius: **44 pt** for the expanded island; "its rounded corner shape matches the TrueDepth camera".
- Lock Screen margin: 14 pt.
- Resting (idle) pill: about **126 × 37.33 pt** on iPhone 14 Pro — widely quoted community measurement, not an Apple table. **[EST]**

### The smaller island (iPhone 18 Pro, Sept 2026)
- Bloomberg via MacRumors (9 Sep 2026) and AppleInsider: iPhone 18 Pro / Pro Max have a "smaller and improved" island that can **toggle between three Live Activities** (was two since iPhone 14 Pro). https://www.macrumors.com/2026/09/09/iphone-18-pro-dynamic-island-to-shrink/
- MacRumors buyer's guide (23 Sep 2026): "Smaller Dynamic Island that supports up to three simultaneous Live Activities"; iPhone Air keeps the standard one.
- Width: leaker Ice Universe claimed ~**13.5 mm vs 20.7 mm** (~35% narrower) — a pre-launch leak, **unverified**. Apple has not published a point size for the 18 Pro island in the sources found. We model the small pill as 126 × 0.65 ≈ **82 × 37 pt** **[EST]**, and the HIG's third-minimal slot.
- iOS 27 (WWDC26 "Live Activities essentials"): compact/minimal now visible in portrait and landscape; compact views are flexible in width in portrait.

## 3. Motion and timing

Apple has never published the island's exact spring constants. What is known:
- SwiftUI `Spring(response:dampingRatio:)` / `.spring(duration:bounce:)` are equivalent parametrisations (Apple docs, https://developer.apple.com/documentation/swiftui/spring). `response` ≈ perceptual duration in seconds.
- Community recreations that match frame captures:
  - CodexNotch: expand `.spring(response: 0.42, dampingFraction: 0.88)`, collapse `.spring(response: 0.30, dampingFraction: 0.96)` — https://github.com/fengdwx/codex-notch (NotchPresentationMotion.swift)
  - NotchBay guide: `.spring(response: 0.35, dampingFraction: 0.72)` for the visible overshoot-and-settle; animate width, height and corner radius together; use `.continuous` corners — https://notchbay.com/blog/how-to-build-a-dynamic-island-for-mac/
- **Atoll values [EST, tuned from the above]**:
  - Expand (compact→expanded, alert bloom): `.spring(response: 0.42, dampingFraction: 0.78)` — slight elastic overshoot ("deliberate elasticity").
  - Collapse: `.spring(response: 0.32, dampingFraction: 0.92)` — quick, almost no overshoot.
  - Compact width changes (activity swap): `.spring(response: 0.38, dampingFraction: 0.82)`.
  - Content in: blur 8→0, scale 0.85→1, opacity 0→1, delayed ~0.06 s after the shape starts; content out: blur 0→8, opacity →0 over ~0.15 s, before the shape shrinks. **[EST]** (the blur/scale-in is visible in Apple footage; durations are by eye).
  - Press-and-hold expand: 0.35–0.5 s hold **[EST]**; on press the pill scales to ~1.04 ("squish") before bloom **[EST]**.
  - Detached minimal bubble splits off with a metaball / gooey merge **[EST]**.

## 4. Built-in iPhone island activities
Music/Now Playing (artwork + waveform tinted by artwork colour), Timer/Stopwatch, phone & FaceTime calls (green, duration), Face ID (spinner → check), charging (battery % with green ring when plugged in), low battery alert, AirDrop progress, silent/ring switch (bell slashes, orange), Focus mode changes, AirPods connected (battery), Apple Pay, screen recording, navigation (Maps), hotspot, VPN, Live Activities from apps (sports, Uber, deliveries), Shazam, Voice Memos recording, alarms, camera/mic privacy indicators.

## 5. Mac clones and what people ask for

| App | Notable features |
|---|---|
| boring.notch (free, OSS) | music + visualizer, calendar, reminders, mirror (camera), charging, gestures, shelf with AirDrop, sizing per display, HUD replacement (volume/brightness/backlight). Roadmap missing: Bluetooth activity, weather, custom layouts, lock-screen widgets, extensions, notifications. https://github.com/TheBoredTeam/boring.notch |
| Alcove ($14.99) | "mirror iOS 1:1"; pill for notchless displays; now playing for any media, Lossless/Atmos badges, calendar, lock-screen widgets, HUDs (battery, connectivity, Focus, volume, brightness), swipe gestures, duo mode (music + calendar). https://www.reddit.com/r/macapps/comments/1seu50q/ |
| NotchNook | many widgets, file tray, nice animations; $25. |
| DynamicLake, MediaMate, NotchDrop, mewNotch | MediaMate = best HUDs; NotchDrop = tray only. https://www.reddit.com/r/macapps/comments/1lfyouu/ |

Top requests (boring.notch issues Sep–Nov 2026, Reddit threads above):
1. Real audio-synced waveform instead of a looping pattern.
2. AirPods / iPhone / Bluetooth device battery.
3. FaceTime / phone calls in the island.
4. Synced lyrics under the closed island.
5. Drop files on the island in compact mode (shelf), paste clipboard into shelf.
6. Notifications mirrored with auto-expand and configurable duration.
7. Weather, calendar empty-day behaviour.
8. Position control / slide down when a menu-bar hider is used; auto-hide.
9. Stability and "looks like Apple made it" over feature count.

## 6. macOS constraints
- **Now Playing on macOS 15.4+**: `mediaremoted` only answers now-playing *reads* from `com.apple.*` processes; commands still work. Workaround: run Apple's `/usr/bin/perl` with ungive/mediaremote-adapter (BSD-3), which loads a helper framework and streams JSON. Fallback: AppleScript to Music/Spotify. https://github.com/ungive/mediaremote-adapter , https://egemertbalcik.com/notes/now-playing-apps-macos-15-4/ — may break on future macOS.
- Window: borderless non-activating NSPanel, level above status bar, `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`; pass clicks through outside the shape.
