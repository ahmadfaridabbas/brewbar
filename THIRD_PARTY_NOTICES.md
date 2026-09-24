# Third-party notices

BrewBar is an independent utility that drives **Homebrew**, the macOS package manager (https://brew.sh). BrewBar is not affiliated with, sponsored by, or endorsed by the Homebrew project or its maintainers. "Homebrew" and related names are the property of their respective owners.

BrewBar does not bundle, redistribute, or modify Homebrew. It invokes the `brew` binary that is already installed on the user's system, using fixed command-line arguments and without shell interpolation. All package operations are performed by the user's own Homebrew installation under Homebrew's normal behavior and policies.

The application is built only from the Swift source in `src/` using Apple's SwiftUI and AppKit frameworks. Interface artwork (app icon, menu-bar glyph) and the website images were generated locally from this project's own drawing code. No remote fonts, stock photographs, upstream marketing screenshots, or generated third-party artwork are bundled.

Distributed builds are locally (ad-hoc) signed and are not Apple-notarized.
