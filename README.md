# exeLauncher

A native SwiftUI macOS launcher for Windows games, built Apple Silicon first.

## Current status

- Native SwiftUI interface with Liquid Glass styling on supported macOS versions.
- Local game library and standalone `.exe` import.
- Downloader for Valve's official Windows Steam installer.
- One-click installer for Wine Staging 11.21.
- Wine Staging 11.21 package includes GStreamer.framework, Wine Gecko, and Wine Mono.
- Create, list, inspect, and delete isolated Wine bottles.

Game launching and graphics translation layers are still in development.

## Install Dependencies

Open the Bottles tab and click **Install Dependencies**. exeLauncher retrieves the Wine Staging 11.21 release metadata from the official Gcenx/macOS_Wine_builds GitHub release, downloads the macOS staging archive, extracts it, and installs the Wine app bundle under:

```
~/Library/Application Support/exeLauncher/Runtime/
```

GStreamer.framework v1.28.1 is included in this Wine release, so it does not need a separate installer. Wine Gecko and Wine Mono are also included in the package.

This Wine build uses x86_64 components. Apple Silicon Macs need Rosetta 2. exeLauncher checks for Rosetta before downloading. If it is missing, install it in Terminal:

```sh
softwareupdate --install-rosetta
```

The runtime is downloaded directly from the upstream release and is not committed to this repository. The app does not silently remove macOS quarantine flags or bypass Gatekeeper.

Upstream release: https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.21

## Bottles

Each bottle is a separate Wine prefix stored under:

```
~/Library/Application Support/exeLauncher/Bottles/
```

A bottle contains its own Windows C: drive, registry, and installed programs. When a new bottle is created, exeLauncher downloads the official Winetricks script and installs these common components into that bottle:

- Microsoft Visual C++ 2015–2022 runtime (`vcrun2022`).
- DirectX shader compiler runtime (`d3dcompiler_47`).
- Microsoft core fonts (`corefonts`).

These components are installed separately in each new bottle. Winetricks may require `cabextract` to be installed on the Mac. Graphics translation layers such as DXVK, DXMT and VKD3D-Proton are not installed automatically yet. They need compatible Wine/Vulkan configuration and must be selected as a graphics route rather than blindly mixed together.

Deleting a bottle permanently deletes everything installed inside it.

## Windows Steam

exeLauncher downloads Valve's Windows Steam installer on demand from Valve's CDN. It is stored at:

```
~/Library/Application Support/exeLauncher/Installers/SteamSetup.exe
```

Steam installation into a bottle and game launching are not connected yet. exeLauncher does not collect Steam passwords, Steam Guard codes, or session cookies.

## Build

Requirements: macOS 14 or later and Xcode 15 or a compatible Swift toolchain.

```sh
swift build
swift run
```

## Roadmap

- [x] Initial SwiftUI app and local game library.
- [x] Import standalone Windows `.exe` files.
- [x] Download official Windows Steam installer.
- [x] One-click Wine Staging and bundled dependency installer.
- [x] Create and manage isolated Wine prefixes.
- [ ] Install Windows Steam into a dedicated bottle.
- [ ] Launch standalone games through a selected bottle.
- [ ] DXMT and DXVK graphics options.
- [ ] Per-game configuration and logs.

## Compatibility

Wine does not run every Windows program. Games with kernel-level anti-cheat often do not work. Graphics compatibility depends on the game, Wine build, macOS version, and translation layer.

## License

License not selected yet. Wine is a separate upstream project with its own license and notices.
