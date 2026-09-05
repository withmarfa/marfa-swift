import Foundation

extension MarfaTypeDefinition {
    /// Builds a definition from what `GET /types` returned.
    ///
    /// **The wire form is already resolved, and that is worth knowing before
    /// reading this.** The vendored source schemas keep `required` as a
    /// top-level array and a format as a separate `format` key; the server
    /// serves neither. It flattens the parent chain, moves `required` onto
    /// each field, and collapses `url`, `email`, `datetime` and `date` from
    /// formats into types before it answers. Only `bcp47` and `iso3166`
    /// survive as formats, and the server does not enforce those either — so
    /// there is nothing to collapse here and a decoder that tried would be
    /// doing the work twice.
    ///
    /// A field whose `type` this build does not recognize is **kept and left
    /// unchecked** rather than dropped or refused. A newer server may name a
    /// type this SDK has never heard of, and refusing a write on that basis
    /// would block work over a field the server would have accepted — the one
    /// direction a local check must never take.
    init(wire: TypeSchema) {
        var fields: [String: MarfaFieldDefinition] = [:]
        for (name, raw) in wire.fields {
            guard let definition = raw.dictionaryValue else { continue }
            guard let declared = definition["type"]?.stringValue,
                  let type = MarfaFieldType(rawValue: declared)
            else { continue }

            fields[name] = MarfaFieldDefinition(
                type: type,
                enumValues: definition["enum_values"]?.arrayValue?.compactMap(\.stringValue),
                maxItems: definition["maxItems"]?.intValue,
                maxLength: definition["maxLength"]?.intValue,
                isRequired: definition["required"]?.boolValue ?? false
            )
        }

        self.init(
            id: wire.id,
            parent: wire.parent,
            fields: fields,
            titleField: wire.displayHints?.titleField,
            bodyField: wire.displayHints?.bodyField,
            schemaVersion: wire.version
        )
    }
}
