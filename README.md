# DailyWalls

A lightweight, native macOS menu bar app that automatically downloads and sets your daily **Bing** or **Windows Spotlight** wallpaper — sourced directly from official Microsoft endpoints. No third-party dependencies.

Fork of [Xiaohan-Tian/DailyWalls](https://github.com/Xiaohan-Tian/DailyWalls) with Spotlight v4 (4K), picker/favorites, cache pruning, and install helpers.

![Menu Bar Icon](Sources/DailyWalls/Resources/AppIcon.png)

---

## Features

- Daily wallpapers from **Bing** (up to 4K UHD) or **Windows Spotlight** (v4 up to 4K, v3 fallback)
- **Pick Spotlight Image…** — preview up to four images, reroll, favorite, or apply one
- **Favorites** copied to `~/Pictures/ms-wallpapers/saved/`
- Original Microsoft/Bing filenames plus JSON metadata sidecars in cache folders
- Auto cache prune — unpicked preview downloads are removed; favorites and active wallpapers are kept
- Per-feed memory — switching Bing ↔ Spotlight restores each feed's last wallpaper without a new fetch
- Re-apply on wake/unlock and when switching Mission Control Spaces (event-driven, no polling)
- Pause daily auto-change, choose image from file, manual re-apply
- Locale-aware Bing/Spotlight requests

---

## Menu Bar

| Option | Description |
|---|---|
| **Bing** / **Spotlight** | Select feed; restores that feed's last wallpaper |
| **Pick Spotlight Image…** | Four-up picker with reroll and ★ save |
| **Re-apply Wallpaper** | Push the current image to all displays/Spaces again |
| **Choose Image from File…** | Use any local image |
| **★ Favorite Current Wallpaper** | Copy current image to `saved/` |
| **Pause Daily Auto-Change** | Skip automatic daily fetches |
| **Exit** | Quit |

---

## Quick scripts

| Script | Purpose |
|---|---|
| `./build.sh` | Build `DailyWalls.app` in-repo |
| `./install.sh` | Build release + install to `/Applications` |
| `./uninstall.sh` | Quit and remove installed app (`--purge-data` optional) |
| `./update.sh` | Uninstall + reinstall (keeps wallpapers/logs) |

---

## Prerequisites

macOS 13+, Xcode Command Line Tools 15+, Swift 5.9+.

```bash
xcode-select --install
swift --version
```

---

## Install from source

```bash
git clone https://github.com/ZhengHk/DailyWalls.git
cd DailyWalls
./install.sh
```

First launch: if Gatekeeper blocks the ad-hoc signed app, right-click → **Open** once, or:

```bash
xattr -dr com.apple.quarantine /Applications/DailyWalls.app
```

---

## File locations

| Path | Contents |
|---|---|
| `~/Pictures/ms-wallpapers/bing/` | Active/cached Bing image(s) |
| `~/Pictures/ms-wallpapers/spotlight/` | Active/cached Spotlight image(s) |
| `~/Pictures/ms-wallpapers/saved/` | Favorites (★) |
| `~/.dailywalls/` | Daily logs |

Images use CDN/Bing filenames (e.g. `OHR.*_UHD.jpg`, Spotlight `*_3840x2160.jpg`) with matching `.json` metadata.

---

## Data sources

| Source | Endpoint | Resolution |
|---|---|---|
| **Bing** | `HPImageArchive.aspx` | Up to 3840×2160 (`_UHD.jpg`) |
| **Spotlight** | `fd.api.iris.microsoft.com/v4/...` (fallback v3 `arc.msn.com`) | Up to 4K when v4 succeeds |

Spotlight API notes: see [spotlightv4apidoc.md](spotlightv4apidoc.md) (credits [Spotlight-Downloader](https://github.com/ORelio/Spotlight-Downloader)).

---

## Acknowledgments

- Original app: [Xiaohan-Tian/DailyWalls](https://github.com/Xiaohan-Tian/DailyWalls) (MIT)
- Windows Spotlight v4 API documentation lineage: [ORelio/Spotlight-Downloader](https://github.com/ORelio/Spotlight-Downloader)

---

## License

MIT — see [LICENSE](LICENSE). You must retain the copyright notices in `LICENSE` when redistributing.