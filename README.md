<p align="center">
  <img src="docs/social-preview-v3.png" alt="Archivator: a radial archive tool for the macOS menu bar" width="100%">
</p>

<p align="center">
  Hold <b>⌥ Option</b> while dragging files to compress or extract them.<br>
  Lives in your menu bar. The result is saved next to the original.
</p>

<p align="center">
  <a href="https://github.com/davidpraznik/Archivator/releases/latest"><img src="https://img.shields.io/github/v/release/davidpraznik/Archivator?color=FC5159&label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14.6%2B-FC5159" alt="macOS 14.6+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/licence-MIT-FC5159" alt="MIT licence"></a>
</p>

## Formats

| Action | Formats |
| --- | --- |
| Compress | ZIP, 7Z, TAR.GZ |
| Extract | ZIP, 7Z, TAR, TGZ, GZ, BZ2, XZ, RAR |

Several files can be dropped at once. If a name is already taken, a number is added (`Project 2.zip`). Existing files are never overwritten.

## Usage

1. Start Archivator. It lives in the menu bar.
2. Drag one or more files or folders from Finder.
3. While dragging, hold **⌥ Option**. The wheel opens at the cursor.
4. Drop on a segment.

If everything you drag is an archive, the wheel offers **Extract here** (into a new folder next to the archive) and **Extract to…** (you choose the folder). Otherwise it offers the three compression formats.

Dropping on the centre or between segments does nothing.

Press **Esc** to cancel a running job. The trigger key can be changed to **⌃ Control** or **⌃⌥ Control + Option** in Settings (**⇧ Shift** and **⌘ Command** are used by [Konverter](https://github.com/davidpraznik/Konverter)).

## Security

Extraction uses the system `tar` (libarchive) without the option that preserves absolute paths. Entries with `..` in the path are refused, absolute paths are made relative, and writing through symbolic links that point outside the target folder is refused. If an archive contains such an entry, extraction stops and the partly extracted folder is removed.

## Requirements

- macOS 14.6 or later (tested on macOS 27 only)
- Xcode to build from source

## Opening a downloaded build

Builds from GitHub are not notarized, so macOS blocks the app on first launch. To open it:

1. Try to open Archivator once and close the warning.
2. Open **System Settings > Privacy & Security** and scroll to the bottom.
3. Click **Open Anyway** next to the message about Archivator, then confirm.

This is needed only once.

## Build

1. Clone the repository and open `Archivator.xcodeproj`.
2. Run.

The app does not use the App Sandbox. Detecting a file drag needs no special permissions.

## Works with Konverter

Konverter uses **⇧ Shift** and **⌘ Command** while dragging. Archivator uses **⌥ Option** by default (changeable in Settings) and never reacts to Shift or Command, so both can run at the same time.

## Third-party components

- [Inter](https://rsms.me/inter/) (SIL Open Font License 1.1), interface typeface. The licence is included as `Inter-LICENSE.txt`.

## Licence

MIT, see [LICENSE](LICENSE). © 2026 David Praznik.
