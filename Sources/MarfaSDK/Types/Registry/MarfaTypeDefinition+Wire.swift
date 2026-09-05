import Foundation

extension MarfaTypeDefinition {
    /// Builds a definition from what `GET /types` returned.
    ///
    /// **The wire form is declared, not resolved, and the distinction decides
    /// what a caller has to do next.** `GET /types` answers with each schema
    /// as it was registered — its own fields and a `parent` id, with nothing
    /// inherited folded in — because resolving every type in a vocabulary is
    /// work a caller who wants one type should pay per type. So a definition
    /// built here carries only what its own registration declared, and
    /// ``MarfaTypeRegistry/resolved()`` is what turns a graph of them into
    /// something a validator can use.
    ///
    /// Two things *are* already resolved and are not re-derived here. A format
    /// with a matching field type — `url`, `email`, `datetime`, `date` — has
    /// been collapsed into `type` before it is sent, so there is exactly one
    /// way to read a field's shape; only the annotation-only formats `bcp47`
    /// and `iso3166` survive as formats, and the server does not enforce
    /// those. And `required` arrives per field rather than as the top-level
    /// array the vendored source schemas use.
    ///
    /// A field whose `type` this build does not recognize is **dropped**, so
    /// nothing local ever refuses a value over a rule it cannot read. That
    /// costs the field's `required` flag along with its type check, which
    /// means a newer server's required field is not enforced here — the
    /// direction that defers to the server rather than blocking a write it
    /// would have taken.
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
