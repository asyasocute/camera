import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Read access to the photo library for the stock-camera style gallery and the shutter-row thumbnail.
@MainActor
final class GalleryStore: ObservableObject {
    @Published private(set) var assets = PHFetchResult<PHAsset>()
    @Published private(set) var latestThumbnail: UIImage?
    private var thumbnailTask: Task<Void, Never>?

    /// Read live: access can change in Settings while the app runs.
    var canRead: Bool { Self.readable(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }

    /// Asked on first use rather than at launch.
    func requestAccess() async -> Bool {
        Self.readable(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    func refresh() {
        guard canRead else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // The in-app viewer is for recent shots; the whole library lives in Photos.
        options.fetchLimit = 300
        assets = PHAsset.fetchAssets(with: .image, options: options)
        guard let latest = assets.firstObject?.localIdentifier else {
            latestThumbnail = nil
            return
        }
        thumbnailTask?.cancel()
        thumbnailTask = Task {
            let image = await Self.image(id: latest, targetSize: CGSize(width: 156, height: 156))
            // A slower request for an older photo must not overwrite the newest thumbnail.
            guard !Task.isCancelled, assets.firstObject?.localIdentifier == latest else { return }
            latestThumbnail = image
        }
    }

    /// Takes an identifier rather than a PHAsset so nothing non-Sendable crosses actors.
    nonisolated static func image(id: String, targetSize: CGSize) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                cont.resume(returning: image)
            }
        }
    }

    /// Full resolution capped at 12 MP: the app's own shots stay pixel-exact,
    /// while 48 MP stock photos don't cost ~200 MB of memory each.
    static func fullSize(of asset: PHAsset) -> CGSize {
        let width = Double(asset.pixelWidth), height = Double(asset.pixelHeight)
        guard width > 0, height > 0 else { return CGSize(width: 3024, height: 4032) }
        let scale = min(1, 4032 / max(width, height))
        return CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
    }

    /// Stored files of the asset, e.g. "DNG + HEIC" for a RAW pair.
    static func fileTypes(of asset: PHAsset) -> String {
        PHAssetResource.assetResources(for: asset)
            .filter { $0.type == .photo || $0.type == .alternatePhoto }
            .map { UTType($0.uniformTypeIdentifier)?.preferredFilenameExtension?.uppercased() ?? "?" }
            .joined(separator: " + ")
    }

    private nonisolated static func readable(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }
}

/// Swipeable recent photos, newest first, opened from the shutter-row thumbnail.
struct GalleryView: View {
    @ObservedObject var store: GalleryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if store.assets.count == 0 {
                UnavailableView("No photos", systemImage: "photo.on.rectangle")
            } else {
                TabView(selection: $selection) {
                    ForEach(0..<store.assets.count, id: \.self) { index in
                        AssetPage(asset: store.assets.object(at: index)).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
            HStack {
                if let info { InfoCapsule(text: info) }
                Spacer()
                CloseButton { dismiss() }
            }
            .padding(.horizontal, 16)
        }
        .statusBarHidden()
    }

    private var info: String? {
        guard selection < store.assets.count else { return nil }
        let asset = store.assets.object(at: selection)
        let date = asset.creationDate?.formatted(date: .abbreviated, time: .shortened)
        return [date, GalleryStore.fileTypes(of: asset)].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct AssetPage: View {
    let asset: PHAsset
    @Environment(\.displayScale) private var displayScale
    @State private var preview: UIImage?
    @State private var full: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZoomableImage(image: full ?? preview, logicalSize: GalleryStore.fullSize(of: asset), fullResolution: full != nil)
                .task(id: asset.localIdentifier) {
                    let screen = CGSize(width: geo.size.width * displayScale, height: geo.size.height * displayScale)
                    preview = await GalleryStore.image(id: asset.localIdentifier, targetSize: screen)
                    // Full resolution only once the page settles, so fast swiping doesn't decode every photo.
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    full = await GalleryStore.image(id: asset.localIdentifier, targetSize: GalleryStore.fullSize(of: asset))
                }
                .onDisappear { full = nil }
        }
    }
}

struct InfoCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced).weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.6), in: Capsule())
    }
}

struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.6), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
