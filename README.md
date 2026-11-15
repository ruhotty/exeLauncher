# exeLauncher

A native SwiftUI macOS launcher for Windows games, built Apple Silicon first.

## Current status

- Native SwiftUI interface with Liquid Glass styling on supported macOS versions.
- Local game library and standalone `.exe` import.
- Downloader for Valve's official Windows Steam installer.
- Wine runtime selection.
- Create, list, inspect, and delete isolated Wine bottles.

Game launching and graphics translation layers are still in development.

## Wine runtime

exeLauncher does not bundle Wine in this repository. Install the Wine Staging 11.16 macOS package from the upstream release page:

https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.16

The upstream packages are distributed as `.tar.xz` archives containing a Wine app bundle. Extract the archive, move the Wine app to Applications, then select that app in exeLauncher under Bottles. The 11.16 release notes also list GStreamer.framework as a system requirement. Install it if it is not already present.

The upstream package documents macOS Catalina or newer as supported and includes shared Wine Gecko and Mono components. Check the upstream release notes for current requirements.

## Bottles

Each bottle is a separate Wine prefix stored under:

```
~/Library/Application Support/exeLauncher/Bottles/
```

A bottle contains its own Windows C: drive, registry, and installed programs. Deleting a bottle permanently deletes everything installed inside it.

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
- [x] Select an installed Wine runtime.
- [x] Create and manage isolated Wine prefixes.
- [ ] Install Windows Steam into a dedicated bottle.
- [ ] Launch standalone games through a selected bottle.
- [ ] DXMT and DXVK graphics options.
- [ ] Per-game configuration and logs.

## Compatibility

Wine does not run every Windows program. Games with kernel-level anti-cheat often do not work. Graphics compatibility depends on the game, Wine build, macOS version, and translation layer.

## License

License not selected yet. Wine is a separate upstream project with its own license and notices.
