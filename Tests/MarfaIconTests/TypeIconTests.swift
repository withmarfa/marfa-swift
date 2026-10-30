import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import MarfaIcons

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private func symbolExists(_ name: String) -> Bool {
    #if canImport(AppKit)
    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    #else
    UIImage(systemName: name) != nil
    #endif
}

private func shippedArtwork(_ id: String) -> Bool {
    #if canImport(AppKit)
    TypeIconArtwork.bundle.image(forResource: NSImage.Name(TypeIconArtwork.assetName(id))) != nil
    #else
    UIImage(named: TypeIconArtwork.assetName(id), in: TypeIconArtwork.bundle, with: nil) != nil
    #endif
}

private let sourceRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The list marfa generates for an icon set at the pinned commit, from the checkout `MARFA_MONOREPO` names.
private func pinnedList(_ prefix: String) throws -> (version: String, ids: [String])? {
    guard let checkout = ProcessInfo.processInfo.environment["MARFA_MONOREPO"] else { return nil }
    let file = URL(fileURLWithPath: checkout).appendingPathComponent("packages/types/generated/icon-set-\(prefix).json")
    struct List: Decodable {
        let version: String
        let icons: [String]
    }
    let list = try JSONDecoder().decode(List.self, from: Data(contentsOf: file))
    return (list.version, list.icons.map { "\(prefix):\($0)" })
}

/// Stands in for the brand product, which this target does not link.
private let someBrandArtwork = BrandArtwork(
    bundle: .main, ids: ["simple-icons:github", "simple-icons:apple"])

@Suite struct IconTableTests {
    @Test func everyMappedIDIsInThePinnedList() {
        let pinned = Set(LucideIconSet.ids)
        let strays = LucideSymbols.table.keys.filter { !pinned.contains($0) }.sorted()
        #expect(strays.isEmpty, "Lucide \(LucideIconSet.version) has no icon with the ID \(strays)")
    }

    @Test func everyIDIsALucideID() {
        #expect(LucideIconSet.ids.allSatisfy { $0.hasPrefix("lucide:") && !$0.dropFirst(7).contains(":") })
        #expect(LucideSymbols.table.keys.allSatisfy { $0.hasPrefix("lucide:") })
    }

    @Test func theListHasNoRepeats() {
        #expect(Set(LucideIconSet.ids).count == LucideIconSet.ids.count)
    }

    @Test func everyMappedSymbolExistsOnThisSDK() {
        let missing = LucideSymbols.table.filter { !symbolExists($0.value) }.map(\.key).sorted()
        #expect(missing.isEmpty, "no SF Symbol on this SDK for \(missing)")
    }

    @Test func theFallbackSymbolExists() {
        #expect(symbolExists(TypeIconArtwork.fallbackSymbol))
    }

    @Test func everyPinnedIDWithoutASymbolShipsItsArtwork() {
        let lacking = LucideIconSet.ids.filter { LucideSymbols.table[$0] == nil && !shippedArtwork($0) }
        #expect(lacking.isEmpty, "no artwork shipped for \(lacking)")
    }

    private var catalog: URL { sourceRoot.appendingPathComponent("Sources/MarfaIcons/Lucide.xcassets") }

    @Test func noArtworkShipsForAMappedID() throws {
        let shipped = try FileManager.default.contentsOfDirectory(atPath: catalog.path)
            .filter { $0.hasSuffix(".imageset") }
            .map { "lucide:" + $0.dropFirst("lucide-".count).dropLast(".imageset".count) }
        #expect(
            Set(shipped) == TypeIconArtwork.drawn,
            "the catalog holds artwork the table covers, or lacks some; run scripts/icons.mjs")
    }

    @Test func theArtworkIsFromTheReleaseTheListNames() throws {
        let stamp = "<!-- @iconify-json/lucide@\(LucideIconSet.version) -->\n"
        let sets = try FileManager.default.contentsOfDirectory(atPath: catalog.path).filter {
            $0.hasSuffix(".imageset")
        }
        var stale: [String] = []
        for set in sets {
            let folder = catalog.appendingPathComponent(set)
            let svgs = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".svg") }
            for svg in svgs
            where !(try String(contentsOf: folder.appendingPathComponent(svg), encoding: .utf8)).hasPrefix(stamp) {
                stale.append(set)
            }
        }
        #expect(
            !sets.isEmpty && stale.isEmpty, "artwork from another release: \(stale.prefix(5)); run scripts/icons.mjs")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARFA_LIVE_REQUIRED"] != nil))
    func theCheckoutIsNamedWhereItIsRequired() throws {
        #expect(try pinnedList("lucide") != nil, "MARFA_LIVE_REQUIRED is set, and MARFA_MONOREPO is not")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARFA_MONOREPO"] != nil))
    func theListIsTheOneMarfaPinsAtTheCommit() throws {
        let pinned = try #require(try pinnedList("lucide"))
        #expect(LucideIconSet.version == pinned.version, "run scripts/icons.mjs")
        #expect(LucideIconSet.ids == pinned.ids, "run scripts/icons.mjs")
    }

    @Test(arguments: [
        "lucide:bot", "lucide:ticket", "lucide:scale", "lucide:gavel", "lucide:notebook-pen", "lucide:folder-kanban",
        "lucide:file-code",
    ])
    func anIDWithNoGoodSymbolIsDrawnFromLucide(id: String) {
        #expect(TypeIconArtwork(id: id, brand: nil) == .lucide(id))
    }

    @Test(arguments: [
        ("lucide:book-open", "book"), ("lucide:rss", "dot.radiowaves.up.forward"), ("lucide:briefcase", "briefcase"),
        ("lucide:globe", "globe"), ("lucide:sticky-note", "note.text"), ("lucide:message-square", "bubble.left"),
    ])
    func anIDWithAGoodSymbolIsDrawnAsIt(id: String, symbol: String) {
        #expect(TypeIconArtwork(id: id, brand: nil) == .symbol(symbol))
    }

    /// The `icon` of every type in marfa's `packages/types/core` at the pin.
    @Test(arguments: [
        "lucide:bookmark", "lucide:layers", "lucide:shapes", "lucide:user", "lucide:map-pin", "lucide:calendar",
        "lucide:file-music", "lucide:file-image", "lucide:file", "lucide:file-video-camera", "lucide:globe",
        "lucide:highlighter", "lucide:disc-3", "lucide:newspaper", "lucide:book-open", "lucide:circle-play",
        "lucide:film", "lucide:library-big", "lucide:tv", "lucide:audio-lines", "lucide:message-square",
        "lucide:sticky-note", "lucide:square-check-big",
    ])
    func everyIconTheCoreTypesCarryIsDrawn(id: String) {
        #expect(TypeIconArtwork(id: id, brand: nil) != .fallback)
    }

    @Test(
        arguments: [
            nil, "", "book-open", "bot", "no-such-icon", "lucide:", "lucide:no-such-icon", "lucide:Book-Open",
            "lucide:book open", "Lucide:book-open", "lucide:lucide:bot", "no-such-set:bot", "simple-icons:no-such-icon",
            ":bot", "lucide-bot",
        ] as [String?])
    func aMissingBareOrUnknownIDFallsBack(id: String?) {
        #expect(TypeIconArtwork(id: id, brand: nil) == .fallback)
        #expect(TypeIconArtwork(id: id, brand: someBrandArtwork) == .fallback)
    }

    @Test func aBrandIDDrawsFallbackWithoutBrandArtworkAndItsMarkWith() {
        #expect(TypeIconArtwork(id: "simple-icons:github", brand: nil) == .fallback)
        #expect(TypeIconArtwork(id: "simple-icons:github", brand: someBrandArtwork) == .brand("simple-icons:github"))
        #expect(
            TypeIconArtwork(id: "simple-icons:not-supplied", brand: someBrandArtwork) == .fallback,
            "the supplied artwork decides which brand IDs it can draw")
    }

    @Test func aBareNameThatIsABrandNameDrawsFallbackEvenWithBrandArtwork() {
        #expect(TypeIconArtwork(id: "github", brand: someBrandArtwork) == .fallback)
    }
}

@MainActor
@Suite struct IconDrawingTests {
    private func pixels(_ view: some View, scheme: ColorScheme = .light) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).frame(width: 40, height: 40))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(
            CGContext(
                data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    /// The average color of the pixels that are mostly opaque.
    private func ink(_ data: [UInt8]) -> (red: Double, green: Double, blue: Double)? {
        var sum = (0.0, 0.0, 0.0)
        var count = 0.0
        for index in stride(from: 0, to: data.count, by: 4) where data[index + 3] > 200 {
            sum.0 += Double(data[index])
            sum.1 += Double(data[index + 1])
            sum.2 += Double(data[index + 2])
            count += 1
        }
        return count == 0 ? nil : (sum.0 / count / 255, sum.1 / count / 255, sum.2 / count / 255)
    }

    @Test(
        arguments: ["lucide:gavel", "lucide:bot", "lucide:book-open", nil, "lucide:no-such-icon", "book-open"]
            as [String?])
    func anIconDrawsSomething(id: String?) throws {
        #expect(ink(try pixels(TypeIcon(id: id).foregroundStyle(.black))) != nil)
    }

    @Test(arguments: ["simple-icons:github", nil] as [String?])
    func aBrandIDWithNoBrandArtworkDrawsTheFallbackSymbol(id: String?) throws {
        let artwork = TypeIconArtwork(id: id, brand: nil)
        #expect(artwork == .fallback)
        #expect(ink(try pixels(Image(artwork: artwork, brand: nil).foregroundStyle(.black))) != nil)
    }

    @Test func everyShippedArtworkDrawsSomething() throws {
        var blank: [String] = []
        for id in TypeIconArtwork.drawn.sorted()
        where ink(try pixels(Image(typeIcon: id).resizable().frame(width: 24, height: 24).foregroundStyle(.black)))
            == nil
        {
            blank.append(id)
        }
        #expect(blank.isEmpty, "drew nothing: \(blank)")
    }

    @Test(arguments: ["lucide:gavel", "lucide:book-open", "lucide:no-such-icon", "book-open"])
    func anIconTakesTheForegroundStyle(id: String) throws {
        let color = try #require(
            ink(try pixels(TypeIcon(id: id).foregroundStyle(Color(red: 1, green: 0, blue: 0)))))
        #expect(color.red > 0.9 && color.green < 0.1 && color.blue < 0.1)
    }

    @Test(arguments: ["lucide:gavel", "lucide:book-open"])
    func anIconWithNoStyleFollowsLightAndDark(id: String) throws {
        let light = try #require(ink(try pixels(TypeIcon(id: id).foregroundStyle(.primary), scheme: .light)))
        let dark = try #require(ink(try pixels(TypeIcon(id: id).foregroundStyle(.primary), scheme: .dark)))
        #expect(light.red < 0.3, "dark ink on a light appearance")
        #expect(dark.red > 0.7, "light ink on a dark appearance")
    }
}
