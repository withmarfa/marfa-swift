# Shipped-store fixture

`store.sqlite` is a SwiftData store written by a real build of this package,
holding one row of every model the schema carries: an item, its metadata row,
an edge, a queued mutation, a dropped mutation, the event cursor and a pending
blob. `generated-from.txt` records the commit it was written at; regeneration
writes that file, so it cannot drift from the store beside it.

`ShippedStoreFixtureTests` opens it under whatever schema the package currently
declares and asserts every row is still there.

The fixture pins the tip of `main` at the moment it was generated, so it does
not test anything about the past. Its value is forward-looking: from here on, a
change that would strand existing stores fails in CI instead of on a device.

## What no other test can ask

`SchemaMigrationTests` seeds its "V1" store through the same compiled models it
then reads back, so the store it writes always already has the current shape and
the comparison is against itself. It proves the V1 to V2 stage fires. It cannot
see a model change shape, which is the change that costs data.

## What a failure here means

A model changed shape — a property added, removed or retyped — and stores
already on devices will not survive it. SwiftData hashes each entity
independently, so one altered model is enough.

The failure does not reach the device as a crash.
`MarfaModelContainer.make(path:cloudKitDatabase:)` answers a store it cannot
open by deleting it and building a fresh one, so what a person sees is an app
that has quietly lost its local state. Four of the seven models hold data that
exists nowhere else: the mutation queue, the bytes behind a queued blob upload,
the dropped-mutation log, and the cursor saying which events this device has
already seen.

The fix is a migration stage and a new versioned schema **that owns its own
copies of the model classes**. A new schema listing the same compiled classes
does not help — the old version then hashes to the mutated shape as well, and
the stage has nothing to migrate from. `MarfaMigrationPlan` sets out the steps
in the paragraph beginning "Adding V3 later".

Regenerate the fixture only once that migration exists and passes. Regenerating
to make a red test green is throwing away the warning.

## Regenerating

From the commit whose schema the fixture should pin:

```bash
MARFA_REGENERATE_STORE_FIXTURE=1 swift test --filter RegenerateTheShippedStoreFixture
```

That rewrites `store.sqlite`, reopens it to confirm every row reads back,
refuses to leave anything beside it, and updates `generated-from.txt`.

Say in the pull request which schema change made the regeneration necessary.
