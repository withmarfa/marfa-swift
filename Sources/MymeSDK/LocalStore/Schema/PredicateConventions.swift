// MARK: - Predicate-safety conventions
//
// SwiftData predicates support only a subset of Swift; some operations
// compile cleanly then crash at runtime. The SDK enforces the safe subset
// across every reactive query and every actor-side fetch.
//
// Rules, byte-for-byte:
//
// 1. Never use `prop.isEmpty == false`. The form compiles cleanly and
//    crashes at runtime. In practice `!prop.isEmpty` also misbehaves
//    on String columns under current SwiftData (silently returns true
//    for every row). Use the captured-value short-circuit form with an
//    explicit `prop != ""` test instead — see PredicateSafetyTests
//    for the canonical shape.
//
// 2. No regular expressions in predicates — `String.contains(/regex/)`
//    compiles and crashes at runtime.
//
// 3. No computed properties in predicates — only stored columns. Computed
//    accessors like `MymeItemModel.state` (wrapping `stateRaw`) compile
//    inside a predicate then fail at runtime when the predicate engine
//    tries to lower them to SQL.
//
// 4. No predicates inside Codable struct fields. `propertiesData`,
//    `tagsData`, and `extensionsData` are opaque to the predicate engine.
//    Fetch then filter in Swift if you need to reach inside.
//
// 5. Use `starts(with:)`, never `hasSuffix(_:)` (unsupported).
//
// 6. For case-insensitive contains, use `localizedStandardContains(_:)`,
//    not `lowercased().contains(_:)` (the latter is unsupported).
//
// 7. Codable enum equality: predicate against the persisted rawValue
//    string, e.g. `$0.stateRaw == "active"` — NOT `$0.state == .active`.
//    The latter compiles but lowers fragilely under CloudKit and may
//    fail at runtime once iCloud mirroring is enabled.
//
// 8. Compose predicates with captured values + boolean short-circuits;
//    do NOT attempt to combine `Predicate<T>` instances at runtime.
//    SwiftData has no public composition API today. The canonical pattern:
//
//        let typeFilter: String = filters?.type ?? ""
//        let hasTypeFilter = !typeFilter.isEmpty
//        let descriptor = FetchDescriptor<MymeItemModel>(
//            predicate: #Predicate { item in
//                !hasTypeFilter || item.type == typeFilter
//            }
//        )
//
//    The captured booleans short-circuit at the predicate engine; constant-
//    true branches optimise away.
//
// Every reactive query file carries a `// MARK: - Predicate safety`
// comment pointing back here. Every predicate is exercised in
// `Tests/MymeSDKTests/PredicateSafetyTests.swift` so a regression that
// re-introduces a footgun fails the build loudly.
