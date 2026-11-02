# Bundled typography

All TTF files are unmodified upstream static releases under SIL OFL 1.1.
The corresponding copyright and license notices are shipped in the APK and
registered with Flutter's LicenseRegistry. These are open approximations of
the Claude-like typographic hierarchy, not Anthropic's proprietary fonts.

| Role | Family | Upstream |
| --- | --- | --- |
| App wordmark | Pinyon Script | https://github.com/google/fonts/tree/main/ofl/pinyonscript |
| Code, commands, file paths | Geist Mono | https://github.com/vercel/geist-font |

`sources.json` pins each original URL to its commit and records SHA-256.
No subsetting, conversion or name-table edits were made. Include the matching
OFL notice when redistributing the font files. Interface text uses the system font; Chinese text uses the phone's
installed CJK font; Chinese fonts are not bundled in the APK. Font size
preferences continue to apply. No runtime font download is needed.
