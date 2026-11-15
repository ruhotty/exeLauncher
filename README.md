# exeLauncher

A native macOS launcher for Windows games. The project is being built for Apple Silicon first.

## Current status

The first development build contains:

- A SwiftUI macOS app shell.
- A local game library saved as JSON in Application Support.
- Importing standalone Windows executable files into the launcher.
- A downloader for Valve's official Windows Steam installer.

Game launching is not implemented yet. The next milestone is integrating a managed Wine runtime and per-game Wine prefixes.

## Windows Steam

exeLauncher is designed to use the **Windows version of Steam inside Wine**, not the macOS Steam client.

The app downloads Valve's current `SteamSetup.exe` on demand from Valve's Steam CDN and stores it under:

```
~/Library/Application Support/exeLauncher/Installers/SteamSetup.exe
```

The installer is deliberately not committed to this Git repository. This keeps the repository small and means users download the current installer directly from Valve.

Official Steam download page: https://store.steampowered.com/about/

The Windows Steam client will be installed into its own Wine prefix when Wine integration is implemented. Steam authentication will be handled by Steam itself. exeLauncher will not collect or store Steam passwords, Steam Guard codes, or session cookies.

## Build on macOS

Requirements:

- macOS 14 or later.
- Xcode 15 or later, or a compatible Swift toolchain.

Open the repository folder in Xcode, or build from Terminal:

```sh
swift build
swift run
```

## Roadmap

- [x] Initial SwiftUI app and library.
- [x] Import standalone Windows `.exe` files.
- [x] Download the official Windows Steam installer.
- [ ] Wine runtime manager.
- [ ] Create and manage isolated Wine prefixes.
- [ ] Install Windows Steam into a dedicated prefix.
- [ ] Launch Steam and standalone games through Wine.
- [ ] DXVK and D3DMetal compatibility options.
- [ ] Per-game configuration and logs.

## Important

Importing an `.exe` file does not make it runnable by itself. A compatible Windows runtime is required. Some games, especially games using kernel-level anti-cheat, may not work in Wine.

## License

License not selected yet.
