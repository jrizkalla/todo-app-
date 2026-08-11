import SwiftUI
import os

/// The image behind the AI summary.
///
/// Backgrounds are drawn rather than shipped as assets: a handful of gradient
/// meshes weigh nothing in the bundle, scale to any device, and adapt to light
/// and dark without needing two copies of each. A photo the user picks is the
/// one case that needs real pixels, and that is stored in the app group.
enum SummaryBackground: String, CaseIterable, Identifiable, Codable {
    case dawn
    case dusk
    case meadow
    case tide
    case slate
    /// The user's own photo, read from the app group. Falls back to `dawn`
    /// while no photo has been chosen.
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dawn: "Dawn"
        case .dusk: "Dusk"
        case .meadow: "Meadow"
        case .tide: "Tide"
        case .slate: "Slate"
        case .custom: "My Photo"
        }
    }

    /// The built-in choices, in the order Settings offers them.
    static var builtIn: [SummaryBackground] {
        allCases.filter { $0 != .custom }
    }

    /// Colors of the gradient, from top-leading to bottom-trailing.
    ///
    /// Deliberately mid-toned and desaturated: glass cards sit on top of these,
    /// and a background that swings between very light and very dark defeats
    /// the single set of text colors layered over it.
    var colors: [Color] {
        switch self {
        case .dawn:
            [Color(hex: "#F5A97F"), Color(hex: "#C86FA0"), Color(hex: "#6C5CE7")]
        case .dusk:
            [Color(hex: "#2C3E7B"), Color(hex: "#6B4B8A"), Color(hex: "#C86F7A")]
        case .meadow:
            [Color(hex: "#3E8E6E"), Color(hex: "#7BB86B"), Color(hex: "#2F6E5A")]
        case .tide:
            [Color(hex: "#2E7D9A"), Color(hex: "#4FB3C4"), Color(hex: "#2A5A8C")]
        case .slate, .custom:
            [Color(hex: "#4A5568"), Color(hex: "#6B7280"), Color(hex: "#374151")]
        }
    }
}

/// Where a user-supplied background photo lives.
///
/// The app group rather than the app's own container, so the file is reachable
/// from the widget extension too if a future widget wants the same backdrop.
enum SummaryBackgroundStore {
    static var imageURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppSchema.appGroupIdentifier)?
            .appendingPathComponent("summary-background.jpg")
    }

    /// Longest edge kept when saving a picked photo.
    ///
    /// A modern camera roll image is far larger than any screen this is drawn
    /// on, and it is blurred and dimmed on top of that. Downsampling once at
    /// save time keeps every later read cheap rather than decoding several
    /// megabytes on each redraw.
    private static let maximumEdge: CGFloat = 2048

    /// Save picked image data, replacing whatever was there.
    @discardableResult
    static func save(_ data: Data) -> Bool {
        guard let url = imageURL else { return false }
        do {
            try (downsampled(data) ?? data).write(to: url, options: .atomic)
            cached = nil
            return true
        } catch {
            AppLog.ui.error("Could not save summary background: \(error.localizedDescription)")
            return false
        }
    }

    /// Shrink to `maximumEdge` and re-encode as JPEG, or nil to store as-is.
    private static func downsampled(_ data: Data) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }

        let longest = max(image.size.width, image.size.height)
        guard longest > maximumEdge else { return image.jpegData(compressionQuality: 0.9) }

        let scale = maximumEdge / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.9)
        #else
        return nil
        #endif
    }

    /// The last read, held so redraws do not re-read and re-decode the file.
    ///
    /// `nonisolated(unsafe)` because access is confined to the main actor in
    /// practice — this is only ever touched from view rendering and the picker.
    nonisolated(unsafe) private static var cached: Data?

    static func load() -> Data? {
        if let cached { return cached }
        guard let url = imageURL, let data = try? Data(contentsOf: url) else { return nil }
        cached = data
        return data
    }

    /// The decoded image for some data, held across redraws.
    ///
    /// Decoding is the expensive half — the background is rebuilt on every
    /// change to the summary around it, and decoding a multi-megapixel photo
    /// each time is what made the screen stutter.
    nonisolated(unsafe) private static var decoded: (key: Int, image: Image)?

    static func image(from data: Data) -> Image? {
        let key = data.hashValue
        if let decoded, decoded.key == key { return decoded.image }

        #if canImport(UIKit)
        guard let image = UIImage(data: data).map({ Image(uiImage: $0) }) else { return nil }
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data).map({ Image(nsImage: $0) }) else { return nil }
        #else
        return nil
        #endif

        decoded = (key, image)
        return image
    }

    static var hasImage: Bool {
        guard let url = imageURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func clear() {
        guard let url = imageURL else { return }
        try? FileManager.default.removeItem(at: url)
        cached = nil
    }
}

/// The backdrop itself: a photo when the user has chosen one, otherwise the
/// selected gradient.
///
/// Always dimmed and blurred a little. Its job is to give the glass something
/// to refract, not to be looked at directly — a sharp photo behind translucent
/// cards makes the text on them unreadable no matter how the card is tinted.
struct SummaryBackgroundView: View {
    let background: SummaryBackground

    /// Reloaded when the user picks a new photo.
    var customImageData: Data?

    /// Off for the small swatches in Settings, which are laid out in a form and
    /// must stay inside their own frame.
    var fillsScreen: Bool = true

    var body: some View {
        ZStack {
            if background == .custom, let image = customImage {
                // The image is an *overlay on a flexible shape*, not a view in
                // the stack. A `resizable().scaledToFill()` image still reports
                // the photo's own aspect ratio as its ideal size, so putting it
                // in the stack directly lets a large photo size the container —
                // which stretched the whole screen to the picture's dimensions.
                // Attached this way it fills whatever it is given and nothing
                // more, and the clip keeps the overflow off screen.
                Color.clear
                    .overlay {
                        image
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 6)
                    }
                    .clipped()
            } else {
                LinearGradient(
                    colors: background.colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                // A second, offset radial wash keeps the gradient from reading
                // as a flat two-stop ramp.
                .overlay {
                    RadialGradient(
                        colors: [.white.opacity(0.28), .clear],
                        center: .init(x: 0.15, y: 0.1),
                        startRadius: 0,
                        endRadius: 420
                    )
                }
            }

            // Darkens the whole field so white text and light glass read at any
            // brightness, and deepens toward the bottom where the cards are.
            LinearGradient(
                colors: [.black.opacity(0.28), .black.opacity(0.45)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // Clipped so a `scaledToFill` photo cannot paint outside the frame it
        // was given — which is what the Settings swatches rely on.
        .clipped()
        .ignoresSafeArea(edges: fillsScreen ? .all : [])
    }

    private var customImage: Image? {
        guard let data = customImageData ?? SummaryBackgroundStore.load() else { return nil }
        return SummaryBackgroundStore.image(from: data)
    }
}

#if DEBUG
#Preview("Backgrounds") {
    ScrollView {
        VStack(spacing: 0) {
            ForEach(SummaryBackground.builtIn) { background in
                SummaryBackgroundView(background: background)
                    .frame(height: 140)
                    .overlay(alignment: .bottomLeading) {
                        Text(background.title)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(8)
                    }
            }
        }
    }
}
#endif
