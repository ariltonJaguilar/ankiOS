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
                GlassFormSection(title: "Perfil ativo") {
                    GlassOptionRow(title: "Em uso") {
                        Text(store.activeProfile)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(1)
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
                            Button("Excluir…", systemImage: "trash", role: .destructive) {
                                deleteTarget = name
                            }
                            .disabled(name == store.activeProfile || profiles.count < 2)
                        }
                    }
                    Button("Novo perfil…") { showNew = true }
                        .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
                }
                Text("Cada perfil mantém sua própria coleção e suas credenciais AnkiWeb.")
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
            Text("A coleção e a mídia serão removidas deste aparelho e dos outros aparelhos na próxima sincronização com iCloud.")
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }
}
