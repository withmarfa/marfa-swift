import CoreGraphics
import Foundation
import Marfa
import MarfaIcons
import SwiftUI
import Testing

@testable import MarfaBrandIcons

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private func shippedArtwork(_ id: String) -> Bool {
    let name = id.replacing(":", with: "-")
    #if canImport(AppKit)
    return MarfaBrandIcons.bundle.image(forResource: NSImage.Name(name)) != nil
    #else
    return UIImage(named: name, in: MarfaBrandIcons.bundle, with: nil) != nil
    #endif
}

private let catalog = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/MarfaBrandIcons/SimpleIcons.xcassets")

private func pinnedList() throws -> (version: String, ids: [String])? {
    guard let checkout = ProcessInfo.processInfo.environment["MARFA_MONOREPO"] else { return nil }
    let file = URL(fileURLWithPath: checkout).appendingPathComponent(
        "packages/types/generated/icon-set-simple-icons.json")
    struct List: Decodable {
        let version: String
        let icons: [String]
    }
    let list = try JSONDecoder().decode(List.self, from: Data(contentsOf: file))
    return (list.version, list.icons.map { "simple-icons:\($0)" })
}

@Suite struct BrandArtworkTests {
    @Test func theListHasNoRepeatsAndOnlyBrandIDs() {
        #expect(Set(SimpleIconsIconSet.ids).count == SimpleIconsIconSet.ids.count)
        #expect(SimpleIconsIconSet.ids.allSatisfy { $0.hasPrefix("simple-icons:") && !$0.dropFirst(13).contains(":") })
    }

    @Test func everyPinnedIDShipsItsArtwork() {
        let lacking = SimpleIconsIconSet.ids.filter { !shippedArtwork($0) }
        #expect(lacking.isEmpty, "no artwork shipped for \(lacking.prefix(10))")
    }

    @Test func theCatalogHoldsExactlyThePinnedIDs() throws {
        let shipped = try FileManager.default.contentsOfDirectory(atPath: catalog.path)
            .filter { $0.hasSuffix(".imageset") }
            .map { "simple-icons:" + $0.dropFirst("simple-icons-".count).dropLast(".imageset".count) }
        #expect(Set(shipped) == Set(SimpleIconsIconSet.ids), "run scripts/icons.mjs")
    }

    @Test func theArtworkIsFromTheReleaseTheListNames() throws {
        let stamp = "<!-- @iconify-json/simple-icons@\(SimpleIconsIconSet.version) -->\n"
        let sets = try FileManager.default.contentsOfDirectory(atPath: catalog.path).filter {
            $0.hasSuffix(".imageset")
        }
        var stale: [String] = []
        for set in sets {
            let folder = catalog.appendingPathComponent(set)
            let svgs = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".svg") }
            for svg in svgs {
                let text = try String(contentsOf: folder.appendingPathComponent(svg), encoding: .utf8)
                if !text.hasPrefix(stamp) { stale.append(set) }
            }
        }
        #expect(
            !sets.isEmpty && stale.isEmpty, "artwork from another release: \(stale.prefix(5)); run scripts/icons.mjs")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARFA_LIVE_REQUIRED"] != nil))
    func theCheckoutIsNamedWhereItIsRequired() throws {
        #expect(try pinnedList() != nil, "MARFA_LIVE_REQUIRED is set, and MARFA_MONOREPO is not")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARFA_MONOREPO"] != nil))
    func theListIsTheOneMarfaPinsAtTheCommit() throws {
        let pinned = try #require(try pinnedList())
        #expect(MarfaBrandIcons.version == pinned.version, "run scripts/icons.mjs")
        #expect(MarfaBrandIcons.ids == pinned.ids, "run scripts/icons.mjs")
    }
}

/// Registration is process-wide and these tests never undo it, so nothing in this target asserts the absence of
/// brand artwork; `MarfaIconTests` does that without the product.
@MainActor
@Suite struct BrandRegistrationTests {
    private func pixels(_ view: some View) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: 40, height: 40))
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

    /// The average color of the pixels above `opacity`.
    ///
    /// A thin outline mark at a small size has no mostly opaque pixel, so a sweep of every mark asks for a faint one.
    private func ink(_ data: [UInt8], opacity: UInt8 = 200) -> (red: Double, green: Double, blue: Double, count: Int)? {
        var sum = (0.0, 0.0, 0.0)
        var count = 0
        for index in stride(from: 0, to: data.count, by: 4) where data[index + 3] > opacity {
            sum.0 += Double(data[index])
            sum.1 += Double(data[index + 1])
            sum.2 += Double(data[index + 2])
            count += 1
        }
        let n = Double(count)
        return count == 0 ? nil : (sum.0 / n / 255, sum.1 / n / 255, sum.2 / n / 255, count)
    }

    @Test func registeringMakesABrandIDDrawItsMark() throws {
        MarfaBrandIcons.register()
        #expect(TypeIconArtwork(id: "simple-icons:github") == .brand("simple-icons:github"))
        #expect(TypeIconArtwork(id: "simple-icons:no-such-brand") == .fallback)
        #expect(TypeIconArtwork(id: "github") == .fallback, "a bare name is not an ID")
        #expect(TypeIconArtwork(id: "lucide:bot") == .lucide("lucide:bot"), "registering leaves Lucide alone")
    }

    @Test func aBrandMarkTakesTheForegroundStyle() throws {
        MarfaBrandIcons.register()
        let color = try #require(
            ink(try pixels(TypeIcon(id: "simple-icons:github").foregroundStyle(Color(red: 1, green: 0, blue: 0)))))
        #expect(color.red > 0.9 && color.green < 0.1 && color.blue < 0.1)
    }

    @Test func aBrandMarkDiffersFromTheFallback() throws {
        MarfaBrandIcons.register()
        let drawn = try pixels(TypeIcon(id: "simple-icons:github").foregroundStyle(.black))
        let fallback = try pixels(TypeIcon(id: "simple-icons:no-such-brand").foregroundStyle(.black))
        #expect(drawn != fallback, "the mark and the fallback draw the same pixels")
        #expect(ink(drawn) != nil)
    }

    @Test func everyBrandMarkDrawsSomething() throws {
        MarfaBrandIcons.register()
        var blank: [String] = []
        for id in MarfaBrandIcons.ids {
            let drawn = try pixels(Image(typeIcon: id).resizable().frame(width: 24, height: 24).foregroundStyle(.black))
            if ink(drawn, opacity: 32) == nil { blank.append(id) }
        }
        #expect(blank.isEmpty, "drew nothing: \(blank.prefix(10)) (\(blank.count))")
    }
}
