import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject private var store: CollectionStore
    @State private var profiles: [String] = []
    @State private var newName = ""
    @State private var showNew = false
    @State private var renameTarget: String?
    @State private var renameName = ""
    @State private var deleteTarget: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GlassCard(interactive: false) {
                    Text("Cada perfil tem sua própria coleção, progresso, mídia e conta AnkiWeb. Trocar de perfil abre esses dados separados; criar um perfil começa uma coleção nova, sem copiar a atual.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GlassFormSection(title: "Perfil ativo") {
                    GlassOptionRow(title: "Em uso") {
                        Text(store.activeProfile)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(1)
                            .accessibilityIdentifier("profiles.activeProfile")
                    }
                }
                GlassFormSection(title: "Perfis") {
                    ForEach(profiles, id: \.self) { name in
                        Button {
                            Task { await store.switchProfile(to: name) }
                        } label: {
                            HStack {
                                Text(name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(AppTheme.primaryText)
                                Spacer()
                                if name == store.activeProfile {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppTheme.accent)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .ankiGlass(tint: .white.opacity(0.08), interactive: true, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Renomear", systemImage: "pencil") {
                                renameTarget = name
                                renameName = name
                            }
                            Button("profiles.delete", systemImage: "trash", role: .destructive) {
                                deleteTarget = name
                            }
                            .disabled(name == store.activeProfile || profiles.count < 2)
                        }
                    }
                    Button("Novo perfil…") { showNew = true }
                        .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
                }
                Text("Para excluir um perfil, primeiro troque para outro. A exclusão remove a coleção e a mídia deste aparelho.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 4)
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(AppBackground())
        .navigationTitle("Perfis")
        .onAppear { profiles = store.listProfiles() }
        .onChange(of: store.activeProfile) { _, _ in profiles = store.listProfiles() }
        .alert("Novo perfil", isPresented: $showNew) {
            TextField("Nome", text: $newName)
            Button("Criar") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                do {
                    try store.createProfile(name)
                    Task {
                        await store.switchProfile(to: name)
                        newName = ""
                        profiles = store.listProfiles()
                    }
                } catch {
                    store.lastError = error.localizedDescription
                }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Renomear perfil", isPresented: renamePresented) {
            TextField("Nome", text: $renameName)
            Button("Renomear") {
                guard let renameTarget else { return }
                Task {
                    do {
                        try await store.renameProfile(renameTarget, to: renameName)
                        profiles = store.listProfiles()
                    } catch {
                        store.lastError = error.localizedDescription
                    }
                    self.renameTarget = nil
                }
            }
            Button("Cancelar", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Excluir perfil?",
            isPresented: deletePresented,
            titleVisibility: .visible
        ) {
            Button("Excluir perfil", role: .destructive) {
                guard let deleteTarget else { return }
                do {
                    try store.deleteProfile(deleteTarget)
                    profiles = store.listProfiles()
                } catch {
                    store.lastError = error.localizedDescription
                }
                self.deleteTarget = nil
            }
            Button("Cancelar", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("A coleção e a mídia deste perfil serão removidas deste aparelho.")
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }
}
