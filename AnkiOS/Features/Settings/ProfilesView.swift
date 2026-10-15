import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject private var store: CollectionStore
    @State private var profiles: [String] = []
    @State private var newName = ""
    @State private var showNew = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GlassFormSection(title: "Perfil ativo") {
                    GlassOptionRow(title: "Em uso") {
                        Text(store.activeProfile)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
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
                                    .foregroundStyle(.white)
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
                            .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Novo perfil…") { showNew = true }
                        .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
                }
                Text("Cada perfil tem a própria coleção local, como no Anki desktop. Sem contas e sem AnkiWeb.")
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
                try? store.createProfile(newName)
                Task {
                    await store.switchProfile(to: newName.trimmingCharacters(in: .whitespacesAndNewlines))
                    newName = ""
                    profiles = store.listProfiles()
                }
            }
            Button("Cancelar", role: .cancel) {}
        }
    }
}
