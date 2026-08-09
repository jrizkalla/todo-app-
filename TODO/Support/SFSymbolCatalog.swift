import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The SF Symbols offered by the symbol picker, grouped the way Apple's own
/// browser groups them.
///
/// SF Symbols ships thousands of glyphs and the system exposes no API to
/// enumerate them, so the catalog is a bundled list rather than a query. It is
/// deliberately broad — every category a space plausibly needs — and each name
/// is checked against the running OS by `isAvailable` before it is shown, so a
/// symbol added in a later release degrades to "absent" instead of rendering as
/// an empty box.
enum SFSymbolCatalog {

    struct Category: Identifiable, Hashable {
        let id: String
        /// Section header in the picker.
        var name: String { id }
        /// Symbol used for the category chip itself.
        let symbol: String
        let names: [String]
    }

    /// Every category, in the order the picker shows them.
    ///
    /// Resolved once and cached: filtering thousands of names through
    /// `isAvailable` is cheap individually but not worth repeating on each
    /// keystroke of the search field.
    static let categories: [Category] = rawCategories.compactMap { category in
        let available = category.names.filter(isAvailable)
        guard !available.isEmpty else { return nil }
        return Category(id: category.id, symbol: category.symbol, names: available)
    }

    /// Flat list of every available symbol, deduplicated, for search.
    static let allSymbols: [String] = {
        var seen = Set<String>()
        return categories.flatMap(\.names).filter { seen.insert($0).inserted }
    }()

    /// Whether the running OS can render this symbol.
    ///
    /// The picker must never offer a name the system does not know: SwiftUI
    /// renders an unknown `Image(systemName:)` as nothing at all, which reads as
    /// a broken row rather than an unsupported glyph.
    /// `nonisolated(unsafe)` because both lookups are thread-safe reads of an
    /// immutable system asset catalog; the isolation warning comes from
    /// `NSImage` being main-actor-bound as a class, not from any shared state
    /// this touches.
    nonisolated static func isAvailable(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil
        #elseif canImport(AppKit)
        return MainActor.assumeIsolated {
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        }
        #else
        return true
        #endif
    }

    /// Symbols matching a search query, ranked so prefix matches come first.
    ///
    /// Names are matched with the separators normalized, so "arrow up" finds
    /// `arrow.up` and typing either dots or spaces works.
    static func search(_ query: String) -> [String] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return allSymbols }

        var prefixMatches: [String] = []
        var containsMatches: [String] = []

        for symbol in allSymbols {
            let haystack = normalize(symbol)
            if haystack.hasPrefix(needle) {
                prefixMatches.append(symbol)
            } else if haystack.contains(needle) {
                containsMatches.append(symbol)
            }
        }

        return prefixMatches + containsMatches
    }

    /// Lowercase the name and collapse `.` and `-` to spaces, so the search
    /// field does not require the user to know a symbol's exact punctuation.
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Catalog

    /// The bundled names, before availability filtering.
    private static let rawCategories: [Category] = [
        Category(id: "Suggested", symbol: "sparkles", names: [
            "square.stack", "folder", "tray.full", "list.bullet", "checklist",
            "briefcase", "house", "person.2", "cart", "book",
            "heart", "airplane", "graduationcap", "wrench.and.screwdriver",
            "star", "flag", "bolt", "leaf", "target", "flame",
        ]),
        Category(id: "Objects & Tools", symbol: "hammer", names: [
            "hammer", "wrench.and.screwdriver", "screwdriver", "paintbrush",
            "paintpalette", "ruler", "scissors", "paperclip", "pin", "lightbulb",
            "key", "lock", "lock.open", "bag", "cart", "creditcard", "gift",
            "shippingbox", "archivebox", "tray", "tray.full", "folder",
            "doc", "doc.text", "note.text", "book", "books.vertical",
            "newspaper", "magazine", "bookmark", "printer", "camera", "video",
            "gamecontroller", "headphones", "guitars", "bell", "megaphone",
            "trash", "eyedropper", "level", "gauge.with.dots.needle.bottom.50percent",
            "battery.100", "powerplug", "wifi.router", "binoculars", "backpack",
        ]),
        Category(id: "People & Health", symbol: "person", names: [
            "person", "person.2", "person.3", "person.crop.circle", "figure.walk",
            "figure.run", "figure.stand", "figure.yoga", "figure.pool.swim",
            "figure.hiking", "figure.strengthtraining.traditional",
            "heart", "heart.text.square", "cross.case", "pills", "bandage",
            "stethoscope", "brain.head.profile", "lungs", "eye", "ear",
            "hand.raised", "hands.clap", "face.smiling", "bed.double",
            "dumbbell", "sportscourt", "medal", "trophy",
        ]),
        Category(id: "Home & Places", symbol: "house", names: [
            "house", "building", "building.2", "building.columns", "storefront",
            "tent", "signpost.right", "mappin", "mappin.and.ellipse", "map",
            "globe", "globe.americas", "location", "sofa", "chair", "lamp.desk",
            "washer", "refrigerator", "oven", "shower", "bathtub", "sink",
            "door.left.hand.open", "window.shade.open", "stairs", "fireplace",
            "key.horizontal", "spigot", "air.conditioner.horizontal",
        ]),
        Category(id: "Nature & Weather", symbol: "leaf", names: [
            "leaf", "tree", "camera.macro", "carrot", "fish", "bird", "ant",
            "pawprint", "tortoise", "hare", "lizard", "sun.max", "sun.haze",
            "moon", "moon.stars", "cloud", "cloud.rain", "cloud.snow",
            "cloud.bolt", "cloud.sun", "wind", "snowflake", "drop", "flame",
            "sparkles", "rainbow", "mountain.2", "water.waves", "humidity",
        ]),
        Category(id: "Travel & Transport", symbol: "airplane", names: [
            "airplane", "airplane.departure", "airplane.arrival", "car",
            "car.2", "bus", "tram", "ferry", "bicycle", "scooter", "sailboat",
            "fuelpump", "road.lanes", "suitcase", "suitcase.rolling",
            "beach.umbrella", "ticket", "passport", "globe.desk",
        ]),
        Category(id: "Food & Drink", symbol: "fork.knife", names: [
            "fork.knife", "cup.and.saucer", "mug", "wineglass", "birthday.cake",
            "carrot", "takeoutbag.and.cup.and.straw", "popcorn", "waterbottle",
            "frying.pan", "cooktop", "refrigerator",
        ]),
        Category(id: "Work & Money", symbol: "briefcase", names: [
            "briefcase", "case", "latch.2.case", "person.badge.clock",
            "calendar", "calendar.badge.clock", "clock", "alarm", "timer",
            "stopwatch", "hourglass", "chart.bar", "chart.pie",
            "chart.line.uptrend.xyaxis", "chart.xyaxis.line", "dollarsign.circle",
            "eurosign.circle", "banknote", "creditcard", "wallet.bifold",
            "percent", "signature", "doc.on.clipboard", "text.document",
        ]),
        Category(id: "Communication", symbol: "message", names: [
            "message", "bubble.left", "bubble.left.and.bubble.right", "phone",
            "phone.badge.waveform", "video", "envelope", "envelope.open",
            "paperplane", "tray.and.arrow.down", "tray.and.arrow.up", "at",
            "mic", "speaker.wave.2", "antenna.radiowaves.left.and.right",
            "quote.bubble", "ellipsis.bubble", "exclamationmark.bubble",
        ]),
        Category(id: "Devices", symbol: "laptopcomputer", names: [
            "laptopcomputer", "desktopcomputer", "display", "iphone", "ipad",
            "applewatch", "airpods", "homepod", "appletv", "keyboard",
            "computermouse", "server.rack", "externaldrive", "internaldrive",
            "sdcard", "cpu", "memorychip", "network", "wifi", "cable.connector",
        ]),
        Category(id: "Education", symbol: "graduationcap", names: [
            "graduationcap", "book", "book.closed", "text.book.closed",
            "pencil", "pencil.and.ruler", "highlighter", "backpack",
            "studentdesk", "function", "sum", "x.squareroot", "compass.drawing",
            "atom", "testtube.2", "microscope", "globe.europe.africa",
        ]),
        Category(id: "Media & Art", symbol: "paintpalette", names: [
            "paintpalette", "paintbrush.pointed", "photo", "photo.stack",
            "camera", "film", "movieclapper", "music.note", "music.mic",
            "pianokeys", "guitars", "metronome", "waveform", "play.circle",
            "theatermasks", "ticket", "text.quote",
        ]),
        Category(id: "Shapes & Symbols", symbol: "circle", names: [
            "circle", "circle.fill", "square", "square.fill", "triangle",
            "diamond", "hexagon", "pentagon", "octagon", "seal", "shield",
            "star", "star.fill", "heart.fill", "flag", "flag.checkered",
            "bookmark.fill", "tag", "number", "asterisk", "checkmark.circle",
            "xmark.circle", "questionmark.circle", "exclamationmark.triangle",
            "info.circle", "plus.circle", "minus.circle", "infinity",
        ]),
        Category(id: "Arrows", symbol: "arrow.right", names: [
            "arrow.up", "arrow.down", "arrow.left", "arrow.right",
            "arrow.up.right", "arrow.turn.up.right", "arrow.triangle.2.circlepath",
            "arrow.clockwise", "arrow.counterclockwise", "arrow.uturn.left",
            "arrowshape.right", "chevron.right", "chevron.up.chevron.down",
            "arrow.up.arrow.down", "arrow.left.arrow.right", "shuffle", "repeat",
        ]),
    ]
}
