# Atoll — spec (v1)

Atoll is a software Dynamic Island for any Mac display (built for a Mac mini on a notchless external monitor). Native Swift, SwiftPM only, menu bar app with no Dock icon. Read plans/RESEARCH.md first: every size and timing comes from there.

## Non-negotiables
- Looks and moves like Apple made it. Pure black (#000) island, `.continuous` corners, SF Pro (system font) with heavy weights for numbers, SF Symbols for glyphs (Icon Factory pack https://factory.primitive8.cc/icons, repo max-pantom/icon-factory, only if a custom glyph is ever needed — none expected in v1).
- Motion only through `IslandMotion` in Core/Contracts.swift (springs). Width, height and corner radius animate together in ONE spring. Content blurs/scales in after the shape starts, and blurs out before it shrinks.
- Minimal UI. No gradients on the island itself, no borders, no drop shadow except a very soft one in expanded state (optional, black 30%, radius 20).
- Swift 5 language mode, macOS 14+. No Xcode project. No third-party Swift packages.
- Never crash when a permission is denied or a private API is missing: degrade quietly.

## Architecture
```
Sources/Atoll/
  Core/Contracts.swift        (shared; orchestrator-owned — edit only if both sides agree, note it in your summary)
  App/                        builder A
    AtollApp.swift            @main, NSApplicationDelegate, .accessory policy, status item menu
    StatusItem.swift          menu: Settings…, Pause island, Quit
  Island/                     builder A
    IslandPanel.swift         NSPanel subclass: borderless, nonactivating, level .statusBar+1 (or .mainMenu+3), collectionBehavior [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle], transparent, hasShadow=false, canBecomeKey only when expanded with controls
    IslandWindowController.swift  positions panel top-centre of chosen screen (AtollSettings.displayID / offsetX / offsetY / scale), reacts to screen changes (NSApplication.didChangeScreenParametersNotification) and settings changes; panel frame fixed at the max expanded size, mouse passes through outside the island shape (ignoresMouseEvents toggled by hit-testing via a global/local mouse monitor or tracking area).
    IslandModel.swift         state machine: presentation (idle/compact/minimal/expanded), hovering, pressed, chosen activity; picks from ActivityCenter.shared.active; handles bloom; hover delay; click vs hover trigger; long-press (IslandMotion.longPress) also expands; click on compact = expand, click outside / mouse exit = collapse after 0.25 s grace.
    IslandView.swift          root SwiftUI view: island shape + content slots + detached minimal bubbles
    IslandShape.swift         continuous rounded rect / capsule with animatable width, height, radius. Detached bubbles merge/split with a gooey metaball look (Canvas + alphaThreshold blur, or just matched springs if it looks cleaner).
    IslandMetrics.swift       sizes from RESEARCH.md: idle pill 126×37.33 (classic) or 82×37.33 (small, estimate); height 37.33; compact = pill width + 2×activity.compactSideWidth+padding; minimal bubble 36.67; expanded width 371 default (408 at scale≥1.1), height activity.expandedHeight + insets; expanded radius 44; all multiplied by settings.scale.
    Haptics.swift             NSHapticFeedbackManager.defaultPerformer.perform(.alignment/.levelChange) when settings.haptics (only Force Touch trackpads; no-op otherwise)
  Activities/                 builder B
    NowPlaying/NowPlayingActivity.swift  compact: artwork (rounded 6) leading, live waveform trailing tinted with artwork average colour; expanded: artwork 56–64 pt (radius 12), title/artist, app badge, scrubber with elapsed/remaining, prev/play-pause/next, (AirPlay-style output glyph decorative); minimal: artwork bubble.
    NowPlaying/MediaSource.swift  protocol + three implementations tried in order:
        1. AdapterSource: runs `/usr/bin/perl <Resources>/MediaRemoteAdapter/mediaremote-adapter.pl <framework path> stream` via Process, parses newline JSON (keys: title, artist, album, duration, elapsedTime, playing, artworkData base64, bundleIdentifier, timestamp; handle diff updates); commands via `... send <id>` (0 play,1 pause,2 toggle,4 next,5 previous) and `seek <µs>`. Only if the bundle contains the adapter.
        2. MediaRemoteSource: dlopen /System/Library/PrivateFrameworks/MediaRemote.framework, MRMediaRemoteGetNowPlayingInfo / RegisterForNowPlayingNotifications / SendCommand via dlsym (works on macOS ≤15.3; commands still work later).
        3. AppleScriptSource: polls Music and Spotify every 1 s via NSAppleScript only if those apps are running.
    NowPlaying/Waveform.swift   5–6 rounded bars animated with TimelineView; amplitude driven by a smooth noise when playing, flat when paused (real audio tap is out of scope v1; say so in code comment).
    NowPlaying/ArtworkColor.swift average/vibrant colour from NSImage.
    HUD/HUDActivity.swift       volume + brightness HUD: observe system volume via CoreAudio property listener (kAudioHardwareServiceDeviceProperty_VirtualMainVolume / kAudioDevicePropertyVolumeScalar on default output) and mute; brightness via DisplayServices private (dlsym DisplayServicesGetBrightness) polling on key events if available. On change: activate for 1.6 s, priority 100, compact = glyph leading (speaker.wave.N / sun.max) + thin capsule level bar trailing (wider sideWidth ~64). Only when settings.replaceSystemHUD. Note: hiding the real OSD is not possible without private hacks; Atoll shows alongside it (state this in README).
    Battery/BatteryActivity.swift IOKit IOPSNotificationCreateRunLoopSource: on plug-in/unplug -> bloom-style compact for 3 s: leading "Charging" text or bolt, trailing percent + battery glyph, green (#34C759) when charging; low battery (≤20%) alert in red. Mac mini has no battery: handle gracefully (inactive, UPS ok).
    Timer/TimerActivity.swift   start from menu/expanded presets (1, 5, 10, 25 min, custom); compact: orange timer glyph leading, countdown trailing `.monospacedDigit()` with `.contentTransition(.numericText(countsDown: true))`; expanded: big countdown, pause/resume, cancel (orange #FF9F0A circle buttons like iOS); finish -> bloom + system sound.
    Calendar/CalendarActivity.swift EventKit (requestFullAccessToEvents on 14+), next event within 60 min -> compact (calendar colour dot + "in 12m"); expanded: title, time, location, Join button if a meet/zoom/teams URL is in notes/url. Low priority 10.
    Shelf/ShelfActivity.swift  drop target: dragging files over the island expands it to a shelf; dropped files are kept as references (not copied) in a horizontal tray with QuickLook-ish icons (NSWorkspace icon), drag out to move, AirDrop button (NSSharingService(named: .sendViaAirDrop)), clear. Shell side: builder A makes the panel accept drags (registerForDraggedTypes on a hosting view / .onDrop) and calls ShelfActivity via ActivityCenter id "shelf" — coordinate by having ShelfActivity expose a static `shared` with `func accept(urls:)` and `var isDragTarget: Bool` that A sets.
    Registry.swift             `@MainActor enum Activities { static func registerAll() }` registers all activities into ActivityCenter.shared. A calls this at launch.
  Settings/                   builder B
    SettingsWindow.swift      NSWindow + SwiftUI hosting, opened by `SettingsWindow.show()` (A calls from menu). Tabs: General (display picker from NSScreen.screens with names, style Classic/Small, size slider 0.8–1.6, X/Y offset sliders with live preview, hover vs click, hover delay, launch at login via SMAppService.mainApp), Activities (toggles per activity id: nowPlaying, timer, battery, calendar, shelf, hud), Appearance (pure black vs glass, reduce motion, hide idle pill, haptics), About (version, GitHub link, credits incl. mediaremote-adapter BSD-3). Use native Form/.formStyle(.grouped).
    LaunchAtLogin.swift
```

## Behaviour table
| Situation | Island |
|---|---|
| Nothing active | idle pill (or hidden if hideIdlePill; still hover-revealable) |
| One activity | compact leading/trailing |
| 2–3 activities | top one compact, others as detached minimal bubbles to the right (iPhone 18 Pro style allows 3) |
| Hover (trigger=hover) after hoverDelay / click / long-press | expanded for top activity; if idle, expand shows a small "Nothing playing" + timer presets card |
| bloom(id) | expanded for that activity, collapse after the time unless hovered |
| Drag files over | expanded shelf |
| Mouse leaves | collapse after 0.25 s |
| Video/music in any app (Safari, YouTube, Spotify, Music, VLC…) | now playing via MediaRemote adapter |

## Build split
- Builder A (shell): App/, Island/. Must compile against Contracts.swift and call `Activities.registerAll()`, `SettingsWindow.show()`, `ShelfActivity.shared`.
- Builder B (features): Activities/, Settings/. Must provide exactly those symbols.
- Neither builder commits; the orchestrator commits and runs CI.
- The box is Linux with no Swift toolchain: write code carefully for Swift 5.10 / Xcode 16 on macOS 15 SDK, macOS 14 deployment target. Guard newer APIs with `if #available`. CI (macos-15) is the compiler.
