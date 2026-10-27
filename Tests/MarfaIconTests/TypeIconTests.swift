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

private func shippedArtwork(_ name: String) -> Bool {
    #if canImport(AppKit)
        TypeIconArtwork.bundle.image(forResource: NSImage.Name(TypeIconArtwork.assetName(name))) != nil
    #else
        UIImage(named: TypeIconArtwork.assetName(name), in: TypeIconArtwork.bundle, with: nil) != nil
    #endif
}

@Suite struct IconTableTests {
    @Test func everyMappedNameIsInThePinnedList() {
        let pinned = Set(LucidePinned.names)
        let strays = LucideSymbols.table.keys.filter { !pinned.contains($0) }.sorted()
        #expect(strays.isEmpty, "Lucide \(LucidePinned.version) has no icon named \(strays)")
    }

    @Test func theListHasNoRepeats() {
        #expect(Set(LucidePinned.names).count == LucidePinned.names.count)
    }

    @Test func everyMappedSymbolExistsOnThisSDK() {
        let missing = LucideSymbols.table.filter { !symbolExists($0.value) }.map(\.key).sorted()
        #expect(missing.isEmpty, "no SF Symbol on this SDK for \(missing)")
    }

    @Test func theFallbackSymbolExists() {
        #expect(symbolExists(TypeIconArtwork.fallbackSymbol))
    }

    @Test func everyPinnedNameWithoutASymbolShipsItsArtwork() {
        let lacking = LucidePinned.names.filter { LucideSymbols.table[$0] == nil && !shippedArtwork($0) }
        #expect(lacking.isEmpty, "no artwork shipped for \(lacking)")
    }

    @Test func noArtworkShipsForAMappedName() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarfaIcons/Lucide.xcassets")
        let shipped = try FileManager.default.contentsOfDirectory(atPath: catalog.path)
            .filter { $0.hasSuffix(".imageset") }
            .map { String($0.dropFirst("lucide-".count).dropLast(".imageset".count)) }
        #expect(Set(shipped) == TypeIconArtwork.drawn, "the catalog holds artwork the table covers, or lacks some; run scripts/icons.mjs")
    }

    @Test(arguments: ["bot", "ticket", "scale", "gavel", "notebook-pen", "folder-kanban", "file-code"])
    func aNameWithNoGoodSymbolIsDrawnFromLucide(name: String) {
        #expect(TypeIconArtwork(name: name) == .lucide(name))
    }

    @Test(arguments: [
        ("book-open", "book"), ("rss", "dot.radiowaves.up.forward"), ("briefcase", "briefcase"), ("globe", "globe"),
        ("sticky-note", "note.text"), ("message-square", "bubble.left"),
    ])
    func aNameWithAGoodSymbolIsDrawnAsIt(name: String, symbol: String) {
        #expect(TypeIconArtwork(name: name) == .symbol(symbol))
    }

    @Test(arguments: [nil, "", "no-such-icon", "Book-Open", "book open"])
    func aMissingOrUnknownNameFallsBack(name: String?) {
        #expect(TypeIconArtwork(name: name) == .fallback)
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
        var sum = (0.0, 0.0, 0.0), count = 0.0
        for index in stride(from: 0, to: data.count, by: 4) where data[index + 3] > 200 {
            sum.0 += Double(data[index]); sum.1 += Double(data[index + 1]); sum.2 += Double(data[index + 2])
            count += 1
        }
        return count == 0 ? nil : (sum.0 / count / 255, sum.1 / count / 255, sum.2 / count / 255)
    }

    @Test(arguments: ["gavel", "bot", "book-open", nil, "no-such-icon"] as [String?])
    func anIconDrawsSomething(name: String?) throws {
        #expect(ink(try pixels(TypeIcon(name: name).foregroundStyle(.black))) != nil)
    }

    @Test func everyShippedArtworkDrawsSomething() throws {
        var blank: [String] = []
        for name in TypeIconArtwork.drawn.sorted()
        where ink(try pixels(Image(typeIcon: name).resizable().frame(width: 24, height: 24).foregroundStyle(.black))) == nil
        {
            blank.append(name)
        }
        #expect(blank.isEmpty, "drew nothing: \(blank)")
    }

    @Test(arguments: ["gavel", "book-open", "no-such-icon"])
    func anIconTakesTheForegroundStyle(name: String) throws {
        let color = try #require(ink(try pixels(TypeIcon(name: name).foregroundStyle(Color(red: 1, green: 0, blue: 0)))))
        #expect(color.red > 0.9 && color.green < 0.1 && color.blue < 0.1)
    }

    @Test(arguments: ["gavel", "book-open"])
    func anIconWithNoStyleFollowsLightAndDark(name: String) throws {
        let light = try #require(ink(try pixels(TypeIcon(name: name).foregroundStyle(.primary), scheme: .light)))
        let dark = try #require(ink(try pixels(TypeIcon(name: name).foregroundStyle(.primary), scheme: .dark)))
        #expect(light.red < 0.3, "dark ink on a light appearance")
        #expect(dark.red > 0.7, "light ink on a dark appearance")
    }
}
