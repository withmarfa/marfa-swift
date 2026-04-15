import Testing
import Foundation
@testable import MymeSDK

@Suite("Domain models")
struct DomainModelTests {

    // MARK: - Helpers

    private func makeItem(
        type: String,
        properties: [String: JSONValue] = [:]
    ) -> Item {
        Item(
            createdAt: "2026-01-01T00:00:00Z",
            id: "test-id",
            library: false,
            origin: .user,
            properties: properties,
            schemaVersion: 1,
            source: "sdk-test",
            state: .active,
            timestamp: "2026-01-01T00:00:00Z",
            type: type,
            updatedAt: "2026-01-02T00:00:00Z",
            version: 3
        )
    }

    // MARK: - MymeItem protocol default accessors

    @Test("Protocol default accessors reflect backing item")
    func protocolDefaultAccessors() {
        let item = makeItem(type: "core.note", properties: ["body": .string("Hello")])
        let note = CoreNote(from: item)!
        #expect(note.id == "test-id")
        #expect(note.type == "core.note")
        #expect(note.state == .active)
        #expect(note.isActive)
        #expect(!note.isTrashed)
        #expect(!note.isArchived)
        #expect(note.createdAt == "2026-01-01T00:00:00Z")
        #expect(note.updatedAt == "2026-01-02T00:00:00Z")
        #expect(note.version == 3)
        #expect(note.source == "sdk-test")
        #expect(note.library == false)
        #expect(note.origin == .user)
    }

    // MARK: - CoreNote

    @Suite("CoreNote")
    struct CoreNoteTests {

        @Test("typeIdentifier is core.note") func typeIdentifier() {
            #expect(CoreNote.typeIdentifier == "core.note")
        }

        @Test("init? succeeds when body is present") func initSuccess() {
            let item = makeItem(type: "core.note", properties: [
                "body": .string("My note text"),
                "title": .string("My Title"),
                "language": .string("en"),
                "notes": .string("annotation"),
            ])
            let note = CoreNote(from: item)
            #expect(note != nil)
            #expect(note?.body == "My note text")
            #expect(note?.title == "My Title")
            #expect(note?.language == "en")
            #expect(note?.notes == "annotation")
        }

        @Test("init? fails on type mismatch") func initTypeMismatch() {
            let item = makeItem(type: "core.task", properties: ["body": .string("x")])
            #expect(CoreNote(from: item) == nil)
        }

        @Test("init? fails when required body is missing") func initMissingBody() {
            let item = makeItem(type: "core.note", properties: ["title": .string("No body")])
            #expect(CoreNote(from: item) == nil)
        }

        @Test("Optional fields are nil when absent") func optionalFieldsNil() {
            let item = makeItem(type: "core.note", properties: ["body": .string("x")])
            let note = CoreNote(from: item)!
            #expect(note.title == nil)
            #expect(note.language == nil)
            #expect(note.notes == nil)
        }

        @Test("toProperties round-trips all set fields") func toPropertiesRoundTrip() {
            let item = makeItem(type: "core.note", properties: [
                "body": .string("Hello"),
                "title": .string("Greetings"),
            ])
            let note = CoreNote(from: item)!
            let props = note.toProperties()
            #expect(props["body"] == .string("Hello"))
            #expect(props["title"] == .string("Greetings"))
        }

        @Test("toProperties omits nil optional fields") func toPropertiesOmitsNil() {
            let item = makeItem(type: "core.note", properties: ["body": .string("x")])
            let note = CoreNote(from: item)!
            let props = note.toProperties()
            #expect(props["title"] == nil)
            #expect(props["language"] == nil)
            #expect(props["notes"] == nil)
        }

        private func makeItem(type: String = "core.note", properties: [String: JSONValue]) -> Item {
            Item(
                createdAt: "2026-01-01T00:00:00Z", id: "id",
                library: false, origin: .user, properties: properties,
                schemaVersion: 1, source: "test", state: .active,
                timestamp: "2026-01-01T00:00:00Z", type: type,
                updatedAt: "2026-01-01T00:00:00Z", version: 1
            )
        }
    }

    // MARK: - CoreTask

    @Suite("CoreTask")
    struct CoreTaskTests {

        @Test("Required title, all optional fields") func fields() {
            let item = makeItem(type: "core.task", properties: [
                "title": .string("Buy milk"),
                "priority": .string("high"),
                "status": .string("pending"),
                "due_at": .string("2026-12-31T23:59:59Z"),
            ])
            let task = CoreTask(from: item)!
            #expect(task.title == "Buy milk")
            #expect(task.priority == "high")
            #expect(task.status == "pending")
            #expect(task.dueAt == "2026-12-31T23:59:59Z")
            #expect(task.body == nil)
            #expect(task.completedAt == nil)
        }

        @Test("init? fails when title missing") func initMissingTitle() {
            let item = makeItem(type: "core.task", properties: ["body": .string("desc")])
            #expect(CoreTask(from: item) == nil)
        }

        @Test("toProperties includes title and set optionals") func toProperties() {
            let item = makeItem(type: "core.task", properties: [
                "title": .string("Do thing"),
                "priority": .string("low"),
            ])
            let task = CoreTask(from: item)!
            let props = task.toProperties()
            #expect(props["title"] == .string("Do thing"))
            #expect(props["priority"] == .string("low"))
            #expect(props["due_at"] == nil)
        }

        private func makeItem(type: String = "core.task", properties: [String: JSONValue]) -> Item {
            Item(
                createdAt: "2026-01-01T00:00:00Z", id: "id",
                library: false, origin: .user, properties: properties,
                schemaVersion: 1, source: "test", state: .active,
                timestamp: "2026-01-01T00:00:00Z", type: type,
                updatedAt: "2026-01-01T00:00:00Z", version: 1
            )
        }
    }

    // MARK: - CoreBookmark (no required fields)

    @Suite("CoreBookmark")
    struct CoreBookmarkTests {

        @Test("init? succeeds with empty properties") func initEmpty() {
            let item = makeItem(type: "core.bookmark", properties: [:])
            #expect(CoreBookmark(from: item) != nil)
        }

        @Test("All fields optional") func allOptional() {
            let item = makeItem(type: "core.bookmark", properties: [
                "url": .string("https://example.com"),
                "title": .string("Example"),
                "source_url": .string("https://news.example.com"),
                "source_title": .string("News"),
            ])
            let bm = CoreBookmark(from: item)!
            #expect(bm.url == "https://example.com")
            #expect(bm.title == "Example")
            #expect(bm.sourceUrl == "https://news.example.com")
            #expect(bm.sourceTitle == "News")
            #expect(bm.body == nil)
            #expect(bm.author == nil)
        }

        @Test("toProperties omits all nil fields") func toPropertiesAllNil() {
            let item = makeItem(type: "core.bookmark", properties: [:])
            let bm = CoreBookmark(from: item)!
            #expect(bm.toProperties().isEmpty)
        }

        private func makeItem(type: String = "core.bookmark", properties: [String: JSONValue]) -> Item {
            Item(
                createdAt: "2026-01-01T00:00:00Z", id: "id",
                library: false, origin: .user, properties: properties,
                schemaVersion: 1, source: "test", state: .active,
                timestamp: "2026-01-01T00:00:00Z", type: type,
                updatedAt: "2026-01-01T00:00:00Z", version: 1
            )
        }
    }

    // MARK: - CoreMediaArticle (two required fields from parent + child)

    @Suite("CoreMediaArticle")
    struct CoreMediaArticleTests {

        @Test("Requires both body and title") func requiresBothFields() {
            // Missing body
            #expect(CoreMediaArticle(from: makeItem(properties: ["title": .string("T")])) == nil)
            // Missing title
            #expect(CoreMediaArticle(from: makeItem(properties: ["body": .string("B")])) == nil)
            // Both present
            #expect(CoreMediaArticle(from: makeItem(properties: [
                "body": .string("B"), "title": .string("T")
            ])) != nil)
        }

        @Test("Exposes inherited media fields") func inheritedFields() {
            let item = makeItem(properties: [
                "body": .string("Article text"),
                "title": .string("Article Title"),
                "publisher": .string("The Times"),
                "word_count": .int(500),
                "section": .string("Tech"),
            ])
            let article = CoreMediaArticle(from: item)!
            #expect(article.body == "Article text")
            #expect(article.title == "Article Title")
            #expect(article.publisher == "The Times")
            #expect(article.wordCount == 500)
            #expect(article.section == "Tech")
        }

        private func makeItem(properties: [String: JSONValue]) -> Item {
            Item(
                createdAt: "2026-01-01T00:00:00Z", id: "id",
                library: false, origin: .user, properties: properties,
                schemaVersion: 1, source: "test", state: .active,
                timestamp: "2026-01-01T00:00:00Z", type: "core.media.article",
                updatedAt: "2026-01-01T00:00:00Z", version: 1
            )
        }
    }

    // MARK: - CoreFileImage (multiple required fields, integer types)

    @Suite("CoreFileImage")
    struct CoreFileImageTests {

        @Test("Requires blob_ref, height, mime_type, width") func requiresAllFour() {
            let full: [String: JSONValue] = [
                "blob_ref": .string("sha256:abc"),
                "mime_type": .string("image/jpeg"),
                "width": .int(1920),
                "height": .int(1080),
            ]
            #expect(CoreFileImage(from: makeItem(properties: full)) != nil)
            // Missing height
            var partial = full; partial.removeValue(forKey: "height")
            #expect(CoreFileImage(from: makeItem(properties: partial)) == nil)
            // Missing width
            partial = full; partial.removeValue(forKey: "width")
            #expect(CoreFileImage(from: makeItem(properties: partial)) == nil)
        }

        @Test("Typed integer and double accessors") func typedAccessors() {
            let item = makeItem(properties: [
                "blob_ref": .string("sha256:abc"),
                "mime_type": .string("image/jpeg"),
                "width": .int(800),
                "height": .int(600),
                "latitude": .double(51.5),
                "longitude": .double(-0.1),
                "altitude": .double(10.5),
            ])
            let img = CoreFileImage(from: item)!
            #expect(img.width == 800)
            #expect(img.height == 600)
            #expect(img.latitude == 51.5)
            #expect(img.longitude == -0.1)
            #expect(img.altitude == 10.5)
        }

        @Test("toProperties encodes int fields correctly") func toProperties() {
            let item = makeItem(properties: [
                "blob_ref": .string("sha256:abc"),
                "mime_type": .string("image/jpeg"),
                "width": .int(1920),
                "height": .int(1080),
            ])
            let img = CoreFileImage(from: item)!
            let props = img.toProperties()
            #expect(props["width"] == .int(1920))
            #expect(props["height"] == .int(1080))
            #expect(props["blob_ref"] == .string("sha256:abc"))
            #expect(props["mime_type"] == .string("image/jpeg"))
        }

        private func makeItem(properties: [String: JSONValue]) -> Item {
            Item(
                createdAt: "2026-01-01T00:00:00Z", id: "id",
                library: false, origin: .user, properties: properties,
                schemaVersion: 1, source: "test", state: .active,
                timestamp: "2026-01-01T00:00:00Z", type: "core.file.image",
                updatedAt: "2026-01-01T00:00:00Z", version: 1
            )
        }
    }

    // MARK: - CoreEntityPerson (deep inheritance)

    @Suite("CoreEntityPerson")
    struct CoreEntityPersonTests {

        @Test("Exposes both entity fields and person-specific fields") func inheritedFields() {
            let item = makeItem(properties: [
                "name": .string("Ada Lovelace"),
                "given_name": .string("Ada"),
                "family_name": .string("Lovelace"),
                "email": .string("ada@example.com"),
                "job_title": .string("Mathematician"),
                "organization": .string("Analytical Society"),
            ])
            let person = CoreEntityPerson(from: item)!
            // Entity fields
            #expect(person.name == "Ada Lovelace")
            #expect(person.email == "ada@example.com")
            // Person fields
            #expect(person.givenName == "Ada")
            #expect(person.familyName == "Lovelace")
            #expect(person.jobTitle == "Mathematician")
            #expect(person.organization == "Analytical Society")
        }

        @Test("init? fails when name missing (inherited required)") func initMissingName() {
            let item = makeItem(properties: ["given_name": .string("Ada")])
            #expect(CoreEntityPerson(from: item) == nil)
        }

        private func makeItem(properties: [String: JSONValue]) -> Item {
            Item(
                createdAt: "2026-01-01T00:00:00Z", id: "id",
                library: false, origin: .user, properties: properties,
                schemaVersion: 1, source: "test", state: .active,
                timestamp: "2026-01-01T00:00:00Z", type: "core.entity.person",
                updatedAt: "2026-01-01T00:00:00Z", version: 1
            )
        }
    }

    // MARK: - CoreHighlight (enum fields as String)

    @Test("CoreHighlight: enum fields surface as String")
    func highlightEnumFields() {
        let item = makeItem(type: "core.highlight", properties: [
            "text": .string("The important passage"),
            "color": .string("yellow"),
            "locator_type": .string("cfi"),
            "start_location": .string("/4/2/1:0"),
            "end_location": .string("/4/2/1:42"),
            "note": .string("My thought"),
        ])
        let h = CoreHighlight(from: item)!
        #expect(h.text == "The important passage")
        #expect(h.color == "yellow")
        #expect(h.locatorType == "cfi")
        #expect(h.startLocation == "/4/2/1:0")
        #expect(h.endLocation == "/4/2/1:42")
        #expect(h.note == "My thought")
    }

    // MARK: - CoreEvent (Double fields)

    @Test("CoreEvent: Double fields for coordinates and duration")
    func eventDoubleFields() {
        let item = makeItem(type: "core.event", properties: [
            "title": .string("WWDC"),
            "latitude": .double(37.33),
            "longitude": .double(-122.03),
            "duration": .double(3600.0),
        ])
        let event = CoreEvent(from: item)!
        #expect(event.latitude == 37.33)
        #expect(event.longitude == -122.03)
        #expect(event.duration == 3600.0)
    }

    // MARK: - typeIdentifier coverage

    @Test("All 21 generated types have correct typeIdentifier")
    func typeIdentifiers() {
        #expect(CoreBookmark.typeIdentifier == "core.bookmark")
        #expect(CoreEntity.typeIdentifier == "core.entity")
        #expect(CoreEntityPerson.typeIdentifier == "core.entity.person")
        #expect(CoreEntityPlace.typeIdentifier == "core.entity.place")
        #expect(CoreEvent.typeIdentifier == "core.event")
        #expect(CoreFile.typeIdentifier == "core.file")
        #expect(CoreFileAudio.typeIdentifier == "core.file.audio")
        #expect(CoreFileImage.typeIdentifier == "core.file.image")
        #expect(CoreFileVideo.typeIdentifier == "core.file.video")
        #expect(CoreHighlight.typeIdentifier == "core.highlight")
        #expect(CoreMedia.typeIdentifier == "core.media")
        #expect(CoreMediaAlbum.typeIdentifier == "core.media.album")
        #expect(CoreMediaArticle.typeIdentifier == "core.media.article")
        #expect(CoreMediaBook.typeIdentifier == "core.media.book")
        #expect(CoreMediaFilm.typeIdentifier == "core.media.film")
        #expect(CoreMediaPodcast.typeIdentifier == "core.media.podcast")
        #expect(CoreMediaSeries.typeIdentifier == "core.media.series")
        #expect(CoreMediaSong.typeIdentifier == "core.media.song")
        #expect(CoreMediaTvEpisode.typeIdentifier == "core.media.tv_episode")
        #expect(CoreNote.typeIdentifier == "core.note")
        #expect(CoreTask.typeIdentifier == "core.task")
    }

    private func makeItem(type: String, properties: [String: JSONValue]) -> Item {
        Item(
            createdAt: "2026-01-01T00:00:00Z", id: "test-id",
            library: false, origin: .user, properties: properties,
            schemaVersion: 1, source: "test", state: .active,
            timestamp: "2026-01-01T00:00:00Z", type: type,
            updatedAt: "2026-01-01T00:00:00Z", version: 1
        )
    }
}
