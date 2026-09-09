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

## Shape

Chat is the app. A tab bar would put peers at the bottom of a screen that is
really one thing, so everyday navigation and conversation history live behind a
drawer that slides in from the left. The drawer intentionally stays short:
Bots, Activity, Routines, Projects and Library. Configuration lives in Settings,
with technical administration progressively disclosed under Advanced.

## What Liquid Glass is doing here

| Surface                 | API                                                                     |
| ----------------------- | ----------------------------------------------------------------------- |
| Composer                | `GlassEffectContainer` so the field and send button read as one surface |
| Send button             | `.buttonStyle(.glassProminent)` with `.glassEffectID` for the morph     |
| Toolbar, drawer buttons | Automatic glass on the iOS 26 SDK                                       |
| Transcript              | `.scrollEdgeEffectStyle(.soft)` so text stays legible under the bars    |

## Status

| Screen                    | State                                                   |
| ------------------------- | ------------------------------------------------------- |
| Chat                      | Streaming replies, tool calls, Markdown, model picker   |
| Connect                   | Pairing-first connection; manual details under Advanced |
| Settings                  | General, connection, agent options, Advanced            |
| Skills                    | List, search, filter, enable/disable against Hermes     |
| Tools, Plugins, MCP       | Preserved under Settings → Advanced                     |
| Projects, Library, Memory | User-facing work and curated memory                     |
| Activity, Sessions, Usage | Current attention plus history and usage                |

Skills, Tools and Add-ons share one screen: they differ in where the rows come
from and whether a row can be switched, not in how they read.
