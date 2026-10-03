# iLoop pre-submission review

**Repository reviewed:** `bshewan32/Loopo` (`main`)

**Review scope:** routing reliability, navigation behavior, handlebar UX, location/audio behavior, App Store readiness, branding, landing page, and release risks.

## Executive verdict

iLoop is a credible and distinctive v1 beta: the product idea is clear, the route-generation approach is materially better than the original waypoint prototype, and the two-mode ride screen is the right interaction model for a phone mounted on handlebars.

I would **not submit the current build to the App Store yet** without completing the release blockers below. The most important ones are:

1. **Rotate/revoke the GraphHopper API key and move routing behind a server-side proxy.** The current key is embedded in the shipped iOS source/binary, so anyone can extract and spend the quota.
2. **Test the archive on a real Mac/Xcode toolchain.** This sandbox has no `xcodebuild`, so a Swift archive could not be compiled here.
3. **Run a device test matrix** for backgrounding, lock screen, silent mode, Bluetooth, poor GPS, tunnel/urban canyon, off-route recovery, and loop completion.
4. **Confirm the existing App Store bundle identifier before changing it.** The visible app name is now iLoop, but internal Xcode target/project names still say Loopo; that is safe to leave temporarily, while changing the bundle ID could break the existing TestFlight/App Store identity.

## Changes made in this review

- Changed the visible route-planner header to **iLoop**.
- Renamed the SwiftUI `@main` app type to `iLoopApp`.
- Added `CFBundleDisplayName = iLoop` to Debug and Release build settings.
- Updated the location permission copy from Loopo to iLoop.
- Lowered the project deployment target from iOS 26.2 to iOS 17.0, which is appropriate for the SwiftUI Map APIs used and avoids unnecessarily excluding older supported iPhones.
- Fixed the off-route state logic: previously the same 100 m threshold controlled both “joined the loop” and “off route,” making the off-route condition unreachable after joining. iLoop now joins within 100 m and reports off-route beyond an 80 m corridor while remaining in the joined-loop state.
- Moved speech queue state and `AVSpeechSynthesizer` calls onto the main thread to remove a likely source of intermittent audio cues.
- Renamed the internal geometry queue label from `com.loopo...` to `com.iloop...`.

## What is already good

### Product

- **Strong positioning:** “pick a distance and ride” is easy to understand and differentiates from destination-first navigation.
- **Start-anywhere behavior:** the NDB-style approach mode is a meaningful advantage over apps that force a rider to begin at a route start point.
- **Handlebar-first UI:** separating a giant instruction screen from a low-clutter map screen is the right decision. It respects the reality that riders glance rather than read.
- **GraphHopper round-trip routing:** a dedicated cycling profile and round-trip algorithm are a better foundation than arbitrary waypoint construction.
- **Local navigation state:** parsing instructions locally and using a spatial index is the right direction for responsiveness and long routes.
- **Route choices:** returning multiple seeded loops gives the rider agency and makes the app feel less deterministic.

### Landing page

- Clear TestFlight CTA and accurate iLoop positioning.
- Good explanation of Start Anywhere, NDB bearing, and turn-by-turn navigation.
- Production build is healthy: `pnpm check` and `pnpm build` both pass.

## High-risk findings

### 1. API key exposure — release blocker

`RouteGenerationService.swift` contains a literal GraphHopper key and sends it directly from the app. iOS applications cannot keep a third-party API key secret. A malicious user can extract it, consume the 500-request daily allowance, or cause unexpected charges if the account changes.

**Required fix:** revoke/rotate the current key, put GraphHopper behind a small server endpoint, rate-limit per device/user, validate distance bounds server-side, and keep the new provider key only in server secrets. The app should call your endpoint rather than GraphHopper directly.

### 2. No Xcode build verification in this environment — release blocker

This sandbox is Linux and does not have Xcode or `xcodebuild`. Static review found no obvious syntax issue in the touched Swift, but only a Mac archive can validate Swift compilation, asset catalog processing, signing, entitlements, Info.plist generation, and App Store validation.

### 3. Background location entitlement/permission needs an explicit decision

The app enables `UIBackgroundModes = location`, sets `allowsBackgroundLocationUpdates = true`, and requests When In Use authorization. Decide which product behavior you want:

- If rides must continue with the screen locked/backgrounded, implement and test the full Always authorization flow and ensure the App Store privacy explanation is accurate.
- If the app only needs foreground rides, remove the background mode and `allowsBackgroundLocationUpdates` to reduce privacy friction and review risk.

Do not claim background tracking in the permission copy unless it has been tested end-to-end.

### 4. Reverse-direction navigation is not yet mathematically safe

The current implementation reverses the GraphHopper instruction array when it detects reverse travel. Reversing an array alone does not reverse each instruction’s turn sign, point index, street semantics, or maneuver distance. It may appear to work on simple loops but can produce wrong turns on complex routes.

**Recommended fix:** either generate a second route direction explicitly, or build a true reversed instruction transform: reverse coordinate indices, swap left/right/U-turn semantics, recompute distances from the reversed geometry, and validate against the rider’s current segment before announcing a turn.

## Medium-risk findings

### 5. Direction detection averages compass degrees linearly

Averaging 359° and 1° produces 180°, which can incorrectly classify travel direction near north. Use a circular mean or accumulate unit vectors. Also require a minimum speed and horizontal accuracy before locking direction; stationary GPS course values are not reliable.

### 6. Off-route thresholds should be hysteretic

The 100 m join / 80 m off-route fix makes the state reachable, but GPS noise can still cause warning flicker around the threshold. Use separate enter/exit thresholds and perhaps a short time or sample requirement, e.g. off-route after 2–3 consecutive fixes over 90 m and back-on-route after 2–3 fixes under 60 m.

### 7. No automatic route recalculation

The app currently warns and resynchronizes, but a rider who chooses to continue on a different road can remain without useful navigation. For v1, clearly label this as “return to route.” For the next version, add a debounced recalculation request after sustained off-route travel, with an obvious cancel option and a route quota guard.

### 8. Spatial grid has an edge-case fallback cost

The grid correctly accelerates normal lookups, but a location outside the neighbouring 0.01° cells falls back to scanning every segment. That is safe but can become expensive on a very long loop. Consider expanding the search ring progressively or indexing with a route bounding box/R-tree rather than immediately scanning the complete polyline.

### 9. Polyline decoding is not defensive enough

The decoder indexes the encoded string inside repeat loops without validating bounds. A truncated or malformed API response could crash the route-generation task. Validate each varint, reject malformed input, and return a user-friendly generation error.

### 10. Route terrain scoring is only a ranking heuristic

All terrain options currently use the `bike` profile and rank the three returned routes by climb per kilometre. That is acceptable if clearly described as a preference, not a guarantee. The UI should say “prefer flatter/hillier” rather than imply a route will meet the band exactly.

### 11. Route generation cost and quota

Each tap requests three GraphHopper routes and the service retries with delays. With a 500-request daily allowance, a small beta group can exhaust the quota quickly. Add request throttling, prevent duplicate taps, cache by coarse origin/distance/options, and expose a provider error state distinct from generic connectivity failure.

## UX improvements that would make iLoop more appealing to cyclists

### Before App Store launch

- Add a **route quality summary** on each card: distance, elevation gain, estimated ride time, and a short “mostly paved / mixed / unknown” label if the provider data supports it.
- Show an **elevation profile** before starting a ride. Climbers care about this as much as total distance.
- Let riders **preview the loop in an overview map** before selecting it, with a clear clockwise/counter-clockwise indicator.
- Add a visible **GPS accuracy / waiting-for-location state** before generating a route instead of using a raw authorization code in the error message.
- Add a **large pause/resume control**. Riders often stop at lights, cafés, or punctures; a stop-only flow makes the ride history less accurate.
- Provide a **mute / cues-only / full voice** control and an audio test in settings. Include a note that music/podcast volume and Bluetooth routing affect cue audibility.
- Keep the stop action small, but add a clear confirmation and ensure a ride can be discarded without saving if a rider started accidentally.
- Improve accessibility: Dynamic Type support where it does not compromise glanceability, VoiceOver labels for icon-only map controls, and sufficient contrast in the orange off-route state.

### Strong next features

1. **Automatic off-route recalculation**, with a minimum distance/time threshold.
2. **Elevation profile and surface/road-quality metadata.**
3. **Saved route templates** such as “weekday 30 km,” “flat,” and “hilly.”
4. **Shareable route links or GPX export.** Cyclists expect to move routes between apps and bike computers.
5. **Ride history metrics** beyond duration and distance: elevation, average speed, moving time, and route replay.
6. **Apple Watch / CarPlay-style glance surface** only after core navigation reliability is strong.

## App Store checklist

- [ ] Rotate/revoke the exposed GraphHopper key and move routing behind a server proxy.
- [ ] Confirm the production bundle identifier matches the existing TestFlight app before archiving.
- [ ] Archive on Mac/Xcode and validate the generated Info.plist, app icons, signing, and entitlements.
- [ ] Verify the app name is iLoop in the Home Screen, Settings, TestFlight, and App Store metadata.
- [ ] Check Privacy Nutrition Label disclosures for precise location, diagnostics, and any analytics.
- [ ] Add a privacy policy URL and support URL to App Store Connect and the landing page.
- [ ] Test permission denial, restricted location, no GPS, offline mode, API failure, and API quota exhaustion.
- [ ] Test screen lock/backgrounding, audio interruptions, Bluetooth headphones, silent mode, incoming calls, and navigation after resuming.
- [ ] Test low accuracy, stale location, GPS jumps, reverse travel, crossing the start/finish area early, and sustained off-route travel.
- [ ] Test at least one short loop and one long loop on real roads, not only a simulator.
- [ ] Confirm the landing-page TestFlight CTA still opens the current public invite and that screenshots match the shipped build.

## Final recommendation

**Ship to a larger TestFlight cohort first, not directly to the App Store.** The concept and UI are strong enough to recruit riders, but routing safety, audio continuity, background behavior, and the exposed API credential need to be resolved before a public release. After those blockers are closed and a real-device matrix passes, iLoop is a credible niche cycling product with a clear reason to exist alongside general-purpose navigation apps.
