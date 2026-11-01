# Baya artwork

`baya-mark.svg` is the portable colored tile. The most recent direction uses a
soft ivory-to-white surface, a filled graphite-teal weaverbird and a single
gold beak. Its speech-bubble silhouette and negative-space feather use fewer
details than the earlier sketch, so the mark stays legible at launcher,
sidebar and welcome-screen sizes. The Flutter `AppMarkPainter` renders the same
composition and gradient.

Run `python app/branding/sync_android_icons.py` from the repository root to
export the Android vectors and transparent `baya-foreground.svg` /
`baya-monochrome.svg` layers. Android applies its own mask to the full-bleed
gradient background. Foreground artwork remains scaled into the central safe
circle. The matching density PNGs are fallback renders of these SVGs.

This is original vector artwork adapted to Android. It takes inspiration from
Apple's layered icon direction without using Apple's Icon Composer runtime,
platform effects or assets. The monochrome version relies on Android's tint.

Reference: https://developer.apple.com/design/human-interface-guidelines/app-icons
