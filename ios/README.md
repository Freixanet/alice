# Alice for iOS

A native SwiftUI client for the same [Hermes](https://hermes-agent.nousresearch.com)
agent the web app talks to, built for iOS 26 and its Liquid Glass material.

It connects **straight to your Hermes**. Native code has no same-origin rule to
satisfy, so no proxy sits in the middle and the key never travels anywhere but
to the address you configure.

## Where the key lives

In the Keychain, as `WhenUnlockedThisDeviceOnly`: excluded from backups, never
synced, so restoring the phone elsewhere cannot carry it along. It is never
written to `UserDefaults`, never logged, and never rendered.

## Running it

```bash
brew install xcodegen        # once
cd ios && xcodegen generate  # writes Alice.xcodeproj from project.yml
open Alice.xcodeproj
```

The project file is generated, so it is not committed — `project.yml` is the
source of truth and merge conflicts in a `.pbxproj` never happen.

## What Liquid Glass is doing here

| Surface     | API                                                                     |
| ----------- | ----------------------------------------------------------------------- |
| Tab bar     | `TabView` on the iOS 26 SDK, floating and minimising on scroll          |
| Toolbar     | Automatic glass; related buttons share one capsule                      |
| Composer    | `GlassEffectContainer` so the field and send button blend as one system |
| Send button | `.buttonStyle(.glassProminent)` with `.glassEffectID` for the morph     |
| Transcript  | `.scrollEdgeEffectStyle(.soft)` so text stays legible under the bars    |

## Status

Chat, Connect and Settings are wired to a live Hermes. Library and Activity
list the remaining surfaces and state which capability each one needs — an
agent that does not advertise a feature says so rather than showing an empty
screen, the same rule the web client follows.
