# exeLauncher

A native SwiftUI macOS launcher for Windows games, built Apple Silicon first.

## Current status

- Native SwiftUI interface with Liquid Glass styling on supported macOS versions.
- Local game library and standalone `.exe` import.
- Downloader for Valve's official Windows Steam installer.
- One-click installer for the native Apple Silicon MetalSharp Wine runtime.
- MetalSharp Wine bundles Mullion (DXMT-based Direct3D 10/11/12), DXVK, VKD3D-Proton, MoltenVK, Wine Mono, Gecko, and core fonts.
- Create, list, inspect, and delete isolated Wine bottles.

Standalone executable launching is connected to per-game bottles. Graphics routes are selected automatically from Direct3D DLL references when those references are present in the executable.

## Install Dependencies

Open the Bottles tab and click **Download Dependencies**. exeLauncher retrieves the latest Apple Silicon FEX package from the official MetalSharp-Wine GitHub releases, downloads the ZIP, extracts it with macOS `ditto`, and installs the Wine app bundle under:

```
~/Library/Application Support/exeLauncher/Runtime/
```

The native arm64 runtime runs x86 and x86_64 Windows programs through FEX and does not require Rosetta. It includes the graphics components used by MetalSharp Wine:

- Mullion, a DXMT-based Metal backend for Direct3D 10, 11 and 12.
- DXVK-MacOS for Direct3D 8, 9, 10 and 11.
- VKD3D-Proton-MacOS for Direct3D 12, with its matching DXVK and custom MoltenVK runtime.
- WineMetalGL for OpenGL.

The runtime is downloaded directly from the upstream release and is not committed to this repository. exeLauncher does not silently remove macOS quarantine flags or bypass Gatekeeper.

Upstream: https://github.com/metalsharp/MetalSharp-Wine

## Bottles

Each bottle is a separate Wine prefix stored under:

```
~/Library/Application Support/exeLauncher/Bottles/
```

A bottle contains its own Windows C: drive, registry, and installed programs. When a new bottle is created, exeLauncher downloads the official Winetricks script and installs these common components into that bottle:

- Microsoft Visual C++ 2015–2022 runtime (`vcrun2022`).
- DirectX shader compiler runtime (`d3dcompiler_47`).
- Microsoft core fonts (`corefonts`).

These components are installed separately in each new bottle. exeLauncher also downloads a compatible Homebrew cabextract binary, verifies its SHA-256 checksum, and keeps it inside its own Runtime folder. It does not require Homebrew to be installed on the Mac. Graphics translation layers are supplied by the selected MetalSharp Wine runtime. exeLauncher checks the imported executable for Direct3D DLL references and selects DXVK for Direct3D 8/9, VKD3D-Proton for Direct3D 12, or Mullion by default for Direct3D 10/11.

Deleting a bottle permanently deletes everything installed inside it.

## Windows Steam

The home screen has an **Install Steam** action. exeLauncher creates a dedicated Steam bottle, downloads Valve's official Windows Steam installer, and opens it through MetalSharp Wine. Complete the setup in the Wine window. Later, use **Launch Steam** to open the existing installation.

The Steam Library page reads installed game manifests from that bottle, lists detected games, and starts a selected game through Steam using its AppID. Install or update games inside Steam, then click **Refresh** in the Steam Library page.

The installer is stored at:

```
~/Library/Application Support/exeLauncher/Installers/SteamSetup.exe
```

exeLauncher does not collect Steam passwords, Steam Guard codes, or session cookies. Steam and individual games may not work with Wine. The current scanner detects games in the default Steam library inside the dedicated bottle; additional Steam library folders are not scanned yet.

## Build

Requirements: Apple Silicon Mac with macOS 15 or later and Xcode 15 or a compatible Swift toolchain.

```sh
swift build
swift run
```

## Roadmap

- [x] Initial SwiftUI app and local game library.
- [x] Import standalone Windows `.exe` files.
- [x] Download official Windows Steam installer.
- [x] One-click MetalSharp Wine installer with bundled graphics backends.
- [x] Create and manage isolated Wine prefixes.
- [x] Install Windows Steam into a dedicated bottle and launch it.
- [x] Launch standalone executables through automatically created per-game bottles.
- [x] Basic automatic graphics route selection for Direct3D 8/9 and 12, with Mullion as the default for Direct3D 10/11.
- [x] Detect installed games in the default Steam library and launch them through Steam AppIDs.\n- [ ] Additional Steam library folders, per-game configuration and logs.

## Compatibility

Wine does not run every Windows program. Games with kernel-level anti-cheat often do not work. Graphics compatibility depends on the game, Wine build, macOS version, and translation layer.

## License

License not selected yet. Wine is a separate upstream project with its own license and notices.
