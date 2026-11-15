# Host Return opens the Host App by its bundle ID

After a Deep-Link Fallback start, VCDR does a Host Return: when the Recording Run is Capturing, VCDR brings the Host App to the front by its bundle ID. iOS then resumes the Host App on the screen the user left, because an open by bundle ID is not a navigation. VCDR learns the bundle ID from the private `_UIRemoteKeyboards.currentState.sourceBundleIdentifier` and opens the app with the private `LSApplicationWorkspace openApplicationWithBundleID:`. VCDR is a personal app that is not on the App Store, so private API is acceptable here.

## Context

Wispr Flow does a Host Return. On iPadOS 27.2 its keyboard puts the Host App's bundle ID in its link, and about 1 second later the app asks lsd to open that bundle ID with no URL. Muxify came back on its terminal screen, with no touch in between. Wispr's return also fails sometimes, so it is a best effort, not a guarantee.

## Decision

- VCDR watches `sourceBundleIdentifier` from launch, because the value is there only for a short time. A host seen more than 5 seconds before the record link is not this link's host.
- VCDR leaves only when the run is Capturing, because an audio start can fail in the background. If there is no host, or the run is still Arming at the 2.5-second deadline, the user stays in VCDR with recording running and the swipe-back hint.
- VCDR checks each private step with `responds(to:)` before it calls it. If a step is missing, there is no Host Return.
- The keyboard and the record URL do not change.
- A Diagnostics switch turns Host Return off, so the recording page can be seen.

## Considered Options

- **Open a URL from a catalog of Host Apps.** The return worked, but `muxify://` made expo-router go to Muxify's home screen. A URL is a navigation, so it resumes only apps whose URL does nothing, and each app needs a catalog entry.
- **Follow the system "◀ App" back link** with `UIApplication._systemNavigationAction`. The action was always nil while the link was on screen.
- **Name the host in the keyboard.** KeyboardKit's path (`_UIKeyboardArbiterClient.automaticSharedArbiterClient`) is missing in the extension on iPadOS 27.2, and KeyboardKit's `resolveHostApplicationBundleId` returns nil. The keyboard knows only the host's process ID (`_hostProcessIdentifier`), and RunningBoard refuses to name a process for the keyboard (`Client not entitled`).

## Consequences

- Host Return works for every Host App, with no list of apps.
- The app learns the host about 0.8 seconds after launch, so the user is back about 1 second after the tap, the same time as Wispr Flow.
- iOS shows no "◀ VCDR" link in the Host App after the return.
- Measured on iPadOS 27.2 with Muxify. Not measured on iOS 26.x.
