# Raw

iPhone camera app that shoots a single RAW frame and develops it without noise reduction, sharpening or tone curve.

## Features

- Bayer RAW capture, one frame, no multi-frame fusion; ProRAW where Bayer RAW isn't available (front camera)
- Saves HEIC, JPEG or PNG, optionally paired with the DNG; adjustable compression quality
- Manual ISO, shutter, focus and white balance; shutter and ISO priority; exposure compensation
- Auto exposure limited to 1/24 s; longer manual shutters apply to the photo while the viewfinder stays at a short shutter
- Flash: off, auto, on; the camera sets exposure and white balance for flash shots
- Back lenses the device has, front camera
- Viewer for recent photos with zoom to single pixels
- Optional location in photo metadata
- Volume buttons as shutter (iOS 17.2+)
- English and Russian

## Requirements

- iOS 16 or later
- Xcode 26 to build: open `Camera.xcodeproj` and set your team under Signing & Capabilities
