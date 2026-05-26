import Testing
@testable import MarfaCodegenCore

@Suite struct NameMapperTests {

    // MARK: - Struct names

    @Test func basicDottedIDBecomesPascalCase() throws {
        #expect(try NameMapper.structName(for: "myapp.booking") == "MyappBooking")
        #expect(try NameMapper.structName(for: "myapp.booking.reservation") == "MyappBookingReservation")
        #expect(try NameMapper.structName(for: "core.note") == "CoreNote")
    }

    @Test func snakeCaseWithinSegmentBecomesPascalCase() throws {
        #expect(try NameMapper.structName(for: "foo.bar_baz") == "FooBarBaz")
        #expect(try NameMapper.structName(for: "core.media.tv_episode") == "CoreMediaTvEpisode")
        #expect(try NameMapper.structName(for: "myapp.3d_model") == "Myapp3dModel")
    }

    @Test func leadingDigitSegmentGetsUnderscorePrefix() throws {
        #expect(try NameMapper.structName(for: "3d.model") == "_3dModel")
    }

    @Test func emptyIDThrows() {
        #expect(throws: NameMapperError.self) {
            _ = try NameMapper.structName(for: "")
        }
    }

    @Test func doubleDotIDThrows() {
        #expect(throws: NameMapperError.self) {
            _ = try NameMapper.structName(for: "myapp..booking")
        }
    }

    // MARK: - Property names

    @Test func propertyNameKeepsSimpleField() {
        #expect(NameMapper.propertyName(for: "body") == "body")
        #expect(NameMapper.propertyName(for: "title") == "title")
    }

    @Test func propertyNameCamelCasesSnakeField() {
        #expect(NameMapper.propertyName(for: "image_url") == "imageUrl")
        #expect(NameMapper.propertyName(for: "start_at") == "startAt")
        #expect(NameMapper.propertyName(for: "party_size") == "partySize")
    }

    @Test func propertyNameHandlesMultipleUnderscores() {
        #expect(NameMapper.propertyName(for: "a_b_c_d") == "aBCD")
    }

    // MARK: - Keyword escaping

    @Test func escapeAddsBackticksAroundSwiftKeywords() {
        #expect(NameMapper.escaped("init") == "`init`")
        #expect(NameMapper.escaped("class") == "`class`")
        #expect(NameMapper.escaped("self") == "`self`")
        #expect(NameMapper.escaped("func") == "`func`")
    }

    @Test func escapeLeavesNonKeywordsAlone() {
        #expect(NameMapper.escaped("title") == "title")
        #expect(NameMapper.escaped("body") == "body")
        #expect(NameMapper.escaped("description") == "description")
    }

    // MARK: - Collision detection

    @Test func collisionBetweenDotAndUnderscoreIDsThrows() {
        // Both map to "FooBarBaz" under the current rules.
        #expect(throws: NameMapperError.self) {
            _ = try NameMapper.buildNameMap(for: ["foo.bar_baz", "foo.bar.baz"])
        }
    }

    @Test func sdkReservedNameThrows() {
        // `marfa.item` → MarfaItem collides with the MarfaSDK protocol.
        #expect(throws: NameMapperError.self) {
            _ = try NameMapper.buildNameMap(for: ["marfa.item"])
        }
    }

    @Test func nonCollidingIDsBuildCleanMap() throws {
        let map = try NameMapper.buildNameMap(for: ["myapp.booking", "myapp.user"])
        #expect(map["myapp.booking"] == "MyappBooking")
        #expect(map["myapp.user"] == "MyappUser")
    }
}
