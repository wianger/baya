# Bundled typography

All TTF files are unmodified upstream releases (SIL OFL 1.1; the Nerd Font
symbols under MIT, their glyph sets under their own licenses); the
notices ship in the APK and are registered with Flutter's LicenseRegistry.

| Role | Family | Upstream |
| --- | --- | --- |
| Interface | Inter 4.1 (400, 500, 600, 700) | https://github.com/rsms/inter |
| Code, commands, file paths | JetBrains Mono 2.304 | https://github.com/JetBrains/JetBrainsMono |
| Prompt and TUI icons in terminals | Symbols Nerd Font Mono 3.4.0 | https://github.com/ryanoasis/nerd-fonts |
| The Baya wordmark | Pinyon Script | https://github.com/google/fonts/tree/main/ofl/pinyonscript |

`sources.json` records each file's release archive and SHA-256. Scripts
Inter does not cover (Chinese among them) use the phone's own fonts.
