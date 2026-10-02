import Marfa
import SwiftUI

struct NotesView: View {
    @Bindable var model: Model
    @State private var newTitle = ""
    @State private var linking: Item?
    @State private var attaching: Item?

    var body: some View {
        NavigationStack {
            List {
                Section("Notes") {
                    HStack {
                        TextField("New note", text: $newTitle)
                        Button("Add") {
                            let title = newTitle
                            newTitle = ""
                            Task { await model.create(title: title) }
                        }
                        .disabled(newTitle.isEmpty)
                    }
                    ForEach(model.notes) { note in
                        NoteRow(model: model, note: note, linking: $linking)
                            .contextMenu {
                                Button(note.tags.contains("favorite") ? "Unfavorite" : "Favorite") {
                                    Task { await model.toggleFavorite(note) }
                                }
                                Button("Link from here") { linking = note }
                                if let source = linking, source.id != note.id {
                                    Button("Link \(source.title ?? source.id) to this") {
                                        linking = nil
                                        Task { await model.link(source, to: note) }
                                    }
                                }
                                Button("Attach a file") { attaching = note }
                                Button("Delete", role: .destructive) { Task { await model.delete(note) } }
                            }
                    }
                }
                Section("Queue") {
                    ForEach(model.queued, id: \.id) { write in
                        HStack {
                            Text(String(describing: write.kind))
                            Spacer()
                            Text(describe(write.verdict)).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            .searchable(text: $model.query)
            .navigationTitle("Notes")
            .toolbar {
                Button("Drain") { Task { await model.drain() } }
            }
            .safeAreaInset(edge: .bottom) {
                Text(model.message).font(.caption).foregroundStyle(.secondary).padding(4)
            }
            .fileImporter(
                isPresented: Binding(get: { attaching != nil }, set: { if !$0 { attaching = nil } }),
                allowedContentTypes: [.item]
            ) { result in
                guard let note = attaching, case .success(let file) = result else { return }
                attaching = nil
                Task {
                    let reachable = file.startAccessingSecurityScopedResource()
                    await model.attach(file, to: note)
                    if reachable { file.stopAccessingSecurityScopedResource() }
                }
            }
        }
    }
}

struct NoteRow: View {
    let model: Model
    let note: Item
    @Binding var linking: Item?
    @State private var editing = false
    @State private var title = ""

    var body: some View {
        HStack {
            if editing {
                TextField("Title", text: $title).onSubmit {
                    editing = false
                    Task { await model.rename(note, to: title) }
                }
            } else {
                Text(note.title ?? "(untitled)").onTapGesture {
                    title = note.title ?? ""
                    editing = true
                }
            }
            Spacer()
            if note.tags.contains("favorite") { Image(systemName: "star.fill") }
            Text("v\(note.version)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

func describe(_ verdict: Verdict?) -> String {
    switch verdict {
    case nil: "unanswered"
    case .accepted: "accepted"
    case .merged(let fields): "merged \(fields.joined(separator: ", "))"
    case .conflicted(let sibling, _): "conflicted, sibling \(sibling)"
    case .refused(let reason): "refused: \(reason)"
    case .blocked(let reason): "blocked: \(reason)"
    case .dead: "dead"
    }
}
