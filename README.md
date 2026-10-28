# Nextpad++ for macOS — personal fork

This repository is based on [Nextpad++ for macOS](https://github.com/nextpad-plus-plus/nextpad-plus-plus-macos), which builds on [Notepad++](https://notepad-plus-plus.org/). It is maintained independently to improve the editor for personal use. It is not an official release of either upstream project.

## Changes in this fork

- The document map shows a miniature view of the current file, a viewport indicator, and search match markers on its right edge. Click the map or a marker to navigate; drag the viewport or scroll over the map to move through the file.
- For dense searches, the map stores up to 19,999 precise text highlights and summarizes matches across the file in a bounded marker track.
- Large-file opening uses the existing Scintilla large-text mode and memory-mapped reads where applicable. The map's ordinary text search scans in bounded ranges to reduce long UI pauses.

Development handoff notes are kept in [changelog/](changelog/).

## Build locally

On macOS with CMake and Apple command-line build tools installed:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel 3
open build/Nextpad++.app
```

The build uses C++ and Objective-C++ sources in `src/`, with vendored Scintilla and Lexilla components. This fork does not provide an independently signed or notarized release.

## License and attribution

This fork retains upstream authorship and license notices. Its modifications and any redistribution are subject to [LICENSE](LICENSE) and the applicable licenses of bundled third-party components. Personal use is the purpose of these changes, not a restriction on the rights granted by those licenses.

- [Nextpad++ for macOS](https://github.com/nextpad-plus-plus/nextpad-plus-plus-macos) — upstream macOS project, developed by Andrey Letov.