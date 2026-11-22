# Atoll — review v1 (Opus)

I read the whole tree, but there is no compiler here, so every compile verdict below is my best judgement and CI has the final word. I found no certain compile error. The A/B contract symbols all exist and match: `Activities.registerAll()`, `SettingsWindow.show()`, `ShelfActivity.shared.accept(urls:)` / `.isDragTarget`. The two `IdleCard`s are both `private`, so they do not clash.

## BLOCKERS

1. **The idle card's timer presets do nothing.** `Island/IslandView.swift:236-240`: the shell's private `IdleCard` posts `.atollStartTimer`, but nothing observes it (`grep atollStartTimer` only finds IslandView). The idle expanded state is a core spec row, so this is a dead UI.
   Fix: use builder B's card and delete the shell copy.
   - `IslandView.swift:98`: change `IdleCard()` to `Activities.idleCard()`.
   - `IslandModel.swift:135`: change `IslandMetrics.idleCardHeight` to `Activities.idleExpandedHeight` (B's card is framed at 92, the shell reserves 84, so it would clip). Or set `IslandMetrics.idleCardHeight = 92`.
   - Delete `private struct IdleCard` (`IslandView.swift:220-257`) and the `Notification.Name.atollStartTimer` extension (`IslandView.swift:3-6`).

2. **The shelf may stop taking drops after it has opened once.** `Activities/Shelf/ShelfActivity.swift:157` puts `.onDrop` on `ShelfExpanded`. That makes the `NSHostingView` register for drag types. The hosting view covers all of `IslandDropView` (autoresizing, `IslandWindowController.swift:15-18`), so AppKit sends drags to the hosting view, not the shell's drop view. Over the compact pill there is no SwiftUI drop target, so the drag is refused and `dragEntered` never fires.
   Fix: remove the `.onDrop` and `@State targeted` from `ShelfExpanded`, and use `activity.isDragTarget` for the highlight. The shell's `IslandDropView` already handles the drop (`performDragOperation` → `accept`).

## SHOULD-FIX

1. **Scale is applied twice.** The shell applies `scaleEffect(settings.scale)` to the whole canvas (`IslandView.swift:46`), and builder B multiplies by `ActivityMetrics.scale` again:
   - `ActivityCommon.swift:57`: padding `9*s`.
   - `ActivityCommon.swift:76`: `minimalSlot` is `36.67*s`, which overflows the 36.67 bubble.
   - `NowPlayingActivity.swift:175-196`: artwork and waveform.
   - `CalendarActivity.swift:345`.
   - `HUDActivity.swift:253,263`.

   At scale 1.6, content ends up 2.56× its intended size. Fix: make `ActivityMetrics.scale` return `1` (or remove it) and use logical points everywhere.
2. **The compact inset is doubled.** The shell pads `compactInset` 10 outside each side frame (`IslandView.swift:108,112`), and `compactSlot` pads another 9 inside. Glyphs sit about 19 pt from the pill edge, so they are not concentric with the 18.7 pt radius. Fix: drop the `.padding(…, 9 * s)` in `ActivityCommon.swift:57`, or set `IslandMetrics.compactInset` to about 8 and keep B's padding at 0.
3. **Now Playing never falls back to AppleScript if the adapter yields nothing.** `MediaSource.swift:105-131`: if perl stays alive but never emits a usable line (helper broken on a future macOS, or entitlement changes), `AdapterSource` is "working" forever and `AppleScriptSource` is never tried. Fix: in `start()`, arm a 5 s watchdog. If no `type=data` line has arrived and Music or Spotify is running, call `onFailure()`. Alternatively, run `AppleScriptSource` whenever the adapter's info is nil.
4. **AppleScript runs on the main thread every second.** `MediaSource.swift:322-326,377-382`: `NSAppleScript.executeAndReturnError` is synchronous. If Music or Spotify is slow or hung, the island's springs stutter or freeze. Fix: run the scripts on one dedicated serial `DispatchQueue` (NSAppleScript is fine confined to one thread) and hop back with `Task { @MainActor … }`.
5. **The adapter process outlives the app.** Nothing stops `NowPlayingActivity.source` on quit, so perl lingers until its next write gets SIGPIPE. Fix: add `applicationWillTerminate` in `AppDelegate` that calls a `NowPlayingActivity.shared.stop()` (new; it calls `source?.stop()`). Also set `out.fileHandleForReading.readabilityHandler = nil` in `AdapterSource.stop()`.
6. **Island buttons may need two clicks.** `IslandPanel` is non-activating and not key until expanded (`IslandPanel.swift:24`). If `NSHostingView` does not accept first mouse, the first click on play/pause or a timer button only focuses the panel. Fix: use `final class IslandHostingView<V: View>: NSHostingView<V> { override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true } }` in `IslandWindowController.swift:13`.
7. **File drags from Finder might not open the island.** Hit-testing only runs from mouse monitors (`IslandWindowController.swift:115-131`). While the panel has `ignoresMouseEvents = true` it is not a drag destination. If the global monitor does not see `.leftMouseDragged` during another app's drag session, the panel never turns on. Fix: while `NSEvent.pressedMouseButtons != 0`, poll `updateMouse()` with a 30 Hz `Timer`, started on the first drag event and stopped on `.leftMouseUp`. Verify on device.
8. **No way to start a timer from the menu bar.** The spec says timers start "from menu", but `StatusItem.swift` has no timer submenu. Fix: add a "Timer" submenu (1/5/10/25 min, Cancel) that calls `TimerActivity.shared.start(minutes:)` and `.cancel()`.
9. **Some devices may give no volume readings.** `HUDActivity.swift:181,209` reads `kAudioDevicePropertyVolumeScalar` on element 1 only. Many devices expose only element 0 (`kAudioObjectPropertyElementMain`). Fix: try element 0 first, then 1.

## NITS

- **Duplicate `islandContent` names.** `AnyTransition.islandContent` is a `static var` in `ActivityCommon.swift:43` and a `private static func islandContent(reduceMotion:)` in `IslandView.swift:21`. That should compile (different full names), but rename the shell one `islandSwap(reduceMotion:)` to avoid an overload trap.
- **Fragile loop pattern.** `HUDActivity.swift:168`: `for (var addr, block) in …` is valid but fragile. Prefer `for (a, block) in deviceListeners { var addr = a; … }` and hoist the `deviceID != 0` guard out of the loop.
- **Deprecation warnings.** `NSApp.activate(ignoringOtherApps:)` (`SettingsWindow.swift:20`, `ShelfActivity.swift:66`) is deprecated on 14. Use `NSApp.activate()`, as `AtollApp.swift` already does.
- **Battery behaviour differs from the spec.** On plug-in, Battery blooms the expanded view (`BatteryActivity.swift:108`). The spec says a "bloom-style compact for 3 s". Either drop the `bloom` call (compact at priority 70 already shows), or keep it and note the deviation.
- **Dead code.** `NowPlayingActivity.expanded()` returns `Activities.idleCard()` when `info == nil`, but the activity is inactive then. Remove it.
- **Hit area bleeds onto a display above.** The panel and hit rect extend 24 pt plus 200 pt above the screen top (`IslandWindowController.swift:62,94`). With displays stacked vertically, that intercepts clicks on the bottom of the upper display. Clamp the extra hit height to 0 when another screen's frame touches `screen.frame.maxY`.
- **Now Playing view churn.** `AppleScriptSource.tick` calls `onUpdate` every second with a fresh `timestamp`, so `info` changes every tick and every observer re-renders. Only publish when the track or playing state changes, or when position drifts by more than 1.5 s.
- **Fidelity checks that pass:** pure `#000`, `.continuous` corners, 44 pt expanded radius, a single shape spring from `IslandMotion`, blur 8 → 0 / scale 0.85 → 1 content transitions with the 0.06 s delay, and `.numericText(countsDown:)` on the timer and calendar. The panel level (`.mainMenu + 3`) and collection behaviour match the spec. Expanded Now Playing is 188 pt tall (156 + 32), above Apple's 160; acceptable on a Mac.
