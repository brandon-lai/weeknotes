import SwiftUI
import WeeknotesCore

/// Audience picker (PRD §11, screen 6). Last week's circles come preselected; choosing none
/// keeps the update in your archive only.
struct AudiencePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Set<UUID>
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.circles) { circle in
                        Button {
                            if selection.contains(circle.id) { selection.remove(circle.id) } else { selection.insert(circle.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(circle.name).foregroundStyle(Theme.ink)
                                    Text(memberSummary(circle)).font(.caption).foregroundStyle(Theme.secondaryInk)
                                }
                                Spacer()
                                Image(systemName: selection.contains(circle.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(circle.id) ? Theme.accent : Theme.secondaryInk)
                                    .font(.title3)
                            }
                        }
                        .accessibilityAddTraits(selection.contains(circle.id) ? .isSelected : [])
                    }
                    Button("New circle", systemImage: "plus") { creating = true }
                } footer: {
                    Text(selection.isEmpty
                         ? "No circles chosen: this update saves to your archive and nobody else sees it."
                         : "Only friends in these circles see this update. They don't see who else it went to.")
                }
            }
            .navigationTitle("Who sees this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Archive only") {
                        selection = []
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $creating) {
                CircleEditorView(circle: nil) { created in
                    if let created { selection.insert(created) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    func memberSummary(_ circle: CircleRow) -> String {
        let names = model.acceptedFriends.filter { circle.memberIDs.contains($0.id) }.map { $0.displayName.split(separator: " ").first.map(String.init) ?? $0.displayName }
        if names.isEmpty { return "No one yet" }
        if names.count <= 3 { return names.formatted(.list(type: .and)) }
        return "\(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more"
    }
}

/// Friends and circles (PRD §11, screen 7).
struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var editingCircle: CircleRow?
    @State private var creatingCircle = false
    @State private var confirmRemove: Friend?

    var body: some View {
        NavigationStack {
            List {
                if !model.incomingRequests.isEmpty {
                    Section("Friend requests") {
                        ForEach(model.incomingRequests) { friend in
                            HStack {
                                AvatarView(name: friend.displayName, size: 34)
                                Text(friend.displayName)
                                Spacer()
                                Button("Accept") { respond(friend, accept: true) }
                                    .buttonStyle(.glassProminent)
                                    .controlSize(.small)
                                Button("Decline") { respond(friend, accept: false) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        FindFriendsView()
                            .padding(.horizontal, 20)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .paperBackground()
                            .navigationTitle("Find friends")
                    } label: {
                        Label("Find friends from contacts", systemImage: "person.crop.circle.badge.plus")
                    }
                    .accessibilityIdentifier("findFriends")
                } footer: {
                    Text("Or post your week and share its link in a group chat: friends who join from it are added automatically.")
                }

                Section("Circles") {
                    ForEach(model.circles) { circle in
                        Button {
                            editingCircle = circle
                        } label: {
                            LabeledContent(circle.name, value: "\(circle.memberIDs.count)")
                                .foregroundStyle(Theme.ink)
                        }
                    }
                    Button("New circle", systemImage: "plus") { creatingCircle = true }
                        .accessibilityIdentifier("newCircle")
                }

                Section(model.acceptedFriends.isEmpty ? "Friends" : "Friends (\(model.acceptedFriends.count))") {
                    if model.acceptedFriends.isEmpty {
                        Text("No friends yet.").foregroundStyle(Theme.secondaryInk)
                    }
                    ForEach(model.acceptedFriends) { friend in
                        HStack(spacing: 12) {
                            AvatarView(name: friend.displayName, size: 34)
                            VStack(alignment: .leading) {
                                Text(friend.displayName)
                                let circles = model.circles.filter { $0.memberIDs.contains(friend.id) }.map(\.name)
                                Text(circles.isEmpty ? "Not in a circle" : circles.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(Theme.secondaryInk)
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { confirmRemove = friend }
                        }
                    }
                }

                let outgoing = model.friends.filter(\.isOutgoingRequest)
                if !outgoing.isEmpty {
                    Section("Waiting for them") {
                        ForEach(outgoing) { friend in
                            HStack {
                                Text(friend.displayName)
                                Spacer()
                                Button("Cancel") { remove(friend) }.controlSize(.small)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("People")
            .refreshable { await model.refreshSocial() }
            .task { await model.refreshSocial() }
            .sheet(item: $editingCircle) { circle in CircleEditorView(circle: circle) { _ in } }
            .sheet(isPresented: $creatingCircle) { CircleEditorView(circle: nil) { _ in } }
            .confirmationDialog(
                "Remove \(confirmRemove?.displayName ?? "")?",
                isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove friend", role: .destructive) { if let friend = confirmRemove { remove(friend) } }
            } message: {
                Text("You'll stop seeing each other's updates, and they leave your circles.")
            }
        }
    }

    private func respond(_ friend: Friend, accept: Bool) {
        Task {
            try? await model.api?.respondToRequest(from: friend.id, accept: accept)
            await model.refreshSocial()
            if accept { model.show("You and \(friend.displayName) are friends") }
        }
    }

    private func remove(_ friend: Friend) {
        Task {
            try? await model.api?.removeFriend(friend.id)
            await model.refreshSocial()
        }
    }
}

struct CircleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let circle: CircleRow?
    let onSaved: (UUID?) -> Void
    @State private var name = ""
    @State private var members: Set<UUID> = []
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("College, Family, Book club…", text: $name)
                        .accessibilityIdentifier("circleName")
                }
                Section {
                    if model.acceptedFriends.isEmpty {
                        Text("Add friends first, then put them in circles.").foregroundStyle(Theme.secondaryInk)
                    }
                    ForEach(model.acceptedFriends) { friend in
                        // A whole row to tap, like the audience picker: easier than a small switch
                        Button {
                            if members.contains(friend.id) { members.remove(friend.id) } else { members.insert(friend.id) }
                        } label: {
                            HStack {
                                AvatarView(name: friend.displayName, size: 30)
                                Text(friend.displayName).foregroundStyle(Theme.ink)
                                Spacer()
                                Image(systemName: members.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(members.contains(friend.id) ? Theme.accent : Theme.secondaryInk)
                            }
                        }
                        .accessibilityLabel(friend.displayName)
                        .accessibilityAddTraits(members.contains(friend.id) ? .isSelected : [])
                        .accessibilityIdentifier("member-\(friend.displayName)")
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text("Circles are your own labels. Members don't see the circle's name or who else is in it.")
                }
                if circle != nil {
                    Section {
                        Button("Delete circle", role: .destructive) { confirmDelete = true }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(circle == nil ? "New circle" : "Edit circle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("saveCircle")
                }
            }
            .confirmationDialog("Delete \(circle?.name ?? "")?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete circle", role: .destructive) { delete() }
            } message: {
                Text("Past updates shared only with this circle become visible to you alone.")
            }
            .onAppear {
                name = circle?.name ?? ""
                members = circle?.memberIDs ?? []
            }
        }
    }

    private func save() {
        guard let api = model.api else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                if let circle {
                    if trimmed != circle.name { try await api.renameCircle(circle.id, to: trimmed) }
                    try await api.setMembers(of: circle.id, to: members, from: circle.memberIDs)
                    onSaved(circle.id)
                } else {
                    let created = try await api.createCircle(name: trimmed, members: members)
                    onSaved(created.id)
                }
                await model.refreshSocial()
                dismiss()
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }

    private func delete() {
        guard let circle else { return }
        Task {
            try? await model.api?.deleteCircle(circle.id)
            await model.refreshSocial()
            dismiss()
        }
    }
}

/// Contact matching (M4): asks for contacts, sends hashes, lists who's here.
struct FindFriendsView: View {
    @Environment(AppModel.self) private var model
    var compact = false
    @State private var matches: [ContactMatch] = []
    @State private var searched = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !compact {
                Text("Friends who added their phone number to Weeknotes show up here if they're in your contacts. Numbers are scrambled on your phone first; nothing is uploaded or kept.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 12)
            }
            Button {
                Task { await search() }
            } label: {
                Label(searched ? "Search again" : "Check my contacts", systemImage: "person.crop.circle.badge.magnifyingglass")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .disabled(working)
            .accessibilityIdentifier("checkContacts")

            if working { ProgressView().frame(maxWidth: .infinity) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            if searched && matches.isEmpty && !working && error == nil {
                Text("Nobody from your contacts is here yet. Share your first update's link to bring them in.")
                    .font(.subheadline).foregroundStyle(Theme.secondaryInk)
            }
            ForEach(matches) { match in
                HStack(spacing: 12) {
                    AvatarView(name: match.displayName, size: 36)
                    Text(match.displayName).font(.body)
                    Spacer()
                    switch status(match) {
                    case "accepted":
                        Text("Friends").font(.caption).foregroundStyle(Theme.secondaryInk)
                    case "outgoing":
                        Text("Requested").font(.caption).foregroundStyle(Theme.secondaryInk)
                    case "incoming":
                        Button("Accept") { add(match) }.buttonStyle(.glassProminent).controlSize(.small)
                    default:
                        Button("Add") { add(match) }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier("add-\(match.displayName)")
                    }
                }
                .card(padding: 12)
            }
        }
    }

    func status(_ match: ContactMatch) -> String {
        if let friend = model.friends.first(where: { $0.id == match.id }) {
            if friend.isAccepted { return "accepted" }
            return friend.requestedByMe ? "outgoing" : "incoming"
        }
        return "none"
    }

    private func search() async {
        guard let api = model.api else { return }
        working = true
        defer { working = false }
        error = nil
        guard await ContactsMatcher.requestAccess() else {
            error = "Contacts access is off. You can allow it in Settings, or invite friends with a share link."
            return
        }
        do {
            matches = try await ContactsMatcher.findFriends(api: api)
            searched = true
        } catch {
            self.error = friendlyMessage(error)
        }
    }

    private func add(_ match: ContactMatch) {
        Task {
            do {
                let result = try await model.api?.sendFriendRequest(match.id)
                await model.refreshSocial()
                if result == "accepted" { model.show("You and \(match.displayName) are friends") }
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }
}
