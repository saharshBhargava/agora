import SwiftUI

/// The server address, editable from Home's gear. Saved to `UserDefaults` `dibs.server`.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    private var bundled: URL { ServerConfig.bundled() ?? ServerConfig.fallback }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metrics.space2) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.muted)
                    TextField("https://your-server.ngrok.app", text: $text)
                        .font(.system(size: 16))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .dibsInput()
                    Text("Use an https:// address. Plain http works only for localhost.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.muted)
                }

                if let error {
                    ErrorText(message: error)
                }

                Button("Save", action: save)
                    .buttonStyle(.dibs)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    model.resetServer()
                    dismiss()
                } label: {
                    VStack(spacing: 2) {
                        Text("Use the built-in server")
                        Text(bundled.absoluteString)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.dibs(.secondary, fontSize: 16))

                Spacer()
            }
            .padding(20)
            .dibsScreen()
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(Color.ink)
        .presentationDetents([.medium, .large])
        .onAppear { text = model.server.absoluteString }
    }

    private func save() {
        if model.saveServer(text) {
            dismiss()
        } else {
            error = "That isn't a usable server address. Use https://, or http://localhost for the simulator."
        }
    }
}

#if DEBUG
#Preview("Settings") {
    Color.paper.sheet(isPresented: .constant(true)) {
        SettingsSheet()
    }
    .environment(AppModel(defaults: UserDefaults(suiteName: "preview.settings")!))
}
#endif
