# Baya artwork

`baya-mark.svg` is the canonical colored mark: a soft ivory glass tile, a
graphite-teal weaverbird, and one gold accent. Its speech-bubble silhouette and
negative-space feather remain legible from launcher to sidebar sizes.

The `baya-foreground.svg` and `baya-monochrome.svg` files are the transparent
Android adaptive and themed layers. `baya-mark.svg` and the Flutter
`AppMarkPainter` share the same geometry.

Legacy `logo-*.svg` filenames are kept as compatibility aliases for existing
links and automation; their contents are the Baya artwork above.

`banner.svg` is the repository/social banner. Render `banner.png` and
`screenshot-app.png` with:

```powershell
magick branding\banner.svg -background none -resize 1280x640 branding\banner.png
Copy-Item branding\banner.png branding\screenshot-app.png -Force
```

Run `python app/branding/sync_android_icons.py` from the repository root to
refresh Android vectors and density fallbacks after changing the source art.
