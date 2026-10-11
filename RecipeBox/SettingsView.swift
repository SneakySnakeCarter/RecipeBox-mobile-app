import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ParserSettingsKeys.selectedEngine)
    private var selectedEngineRaw: String = ParserEngine.claude.rawValue

    @State private var claudeKey: String = ""
    @State private var openAIKey: String = ""
    @State private var savedMessage: String?

    private var selectedEngine: ParserEngine {
        ParserEngine(rawValue: selectedEngineRaw) ?? .claude
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ParserEngine.allCases) { engine in
                        Button {
                            selectedEngineRaw = engine.rawValue
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(engine.displayName)
                                        .foregroundStyle(.primary)
                                    if engine.isAI {
                                        Text("Sends the photo to a cloud AI service")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Fast, private, works offline")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedEngine == engine {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Parsing Engine")
                } footer: {
                    Text("AI engines read recipes far more reliably than on-device OCR, especially handwriting and unusual layouts, but need your own API key and send the photo to that provider's servers. On-Device is a free offline fallback if you don't want to use an API key.")
                }

                Section {
                    SecureField("Anthropic API key", text: $claudeKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Link("Get a Claude API key ↗", destination: AnthropicRecipeProvider().apiKeyHelpURL!)
                        .font(.caption)
                } header: {
                    Text("Claude (Anthropic)")
                }

                Section {
                    SecureField("OpenAI API key", text: $openAIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Link("Get an OpenAI API key ↗", destination: OpenAIRecipeProvider().apiKeyHelpURL!)
                        .font(.caption)
                } header: {
                    Text("ChatGPT (OpenAI)")
                }

                if let savedMessage {
                    Section {
                        Text(savedMessage)
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveKeys()
                        dismiss()
                    }
                }
            }
            .onAppear {
                claudeKey = KeychainHelper.shared.read(forKey: AnthropicRecipeProvider().apiKeyStorageKey) ?? ""
                openAIKey = KeychainHelper.shared.read(forKey: OpenAIRecipeProvider().apiKeyStorageKey) ?? ""
            }
        }
    }

    private func saveKeys() {
        let anthropicKey = AnthropicRecipeProvider().apiKeyStorageKey
        let openAIStorageKey = OpenAIRecipeProvider().apiKeyStorageKey

        if claudeKey.isEmpty {
            KeychainHelper.shared.delete(forKey: anthropicKey)
        } else {
            KeychainHelper.shared.save(claudeKey, forKey: anthropicKey)
        }

        if openAIKey.isEmpty {
            KeychainHelper.shared.delete(forKey: openAIStorageKey)
        } else {
            KeychainHelper.shared.save(openAIKey, forKey: openAIStorageKey)
        }
    }
}

#Preview {
    SettingsView()
}
