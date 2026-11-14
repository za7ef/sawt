import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var models: ModelManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Catalog.voices) { v in
                        Button {
                            settings.voiceID = v.id
                            models.prepareVoice()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(v.title).foregroundStyle(.primary)
                                    Text(v.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if settings.voiceID == v.id {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                    Button {
                        Speaker.shared.speak("هلا والله! أنا صوت، أسمعك وأرد عليك على طول. وش ودك نسولف فيه اليوم؟")
                    } label: {
                        Label("جرّب الصوت", systemImage: "play.circle")
                    }
                } header: {
                    Text("الصوت")
                } footer: {
                    Text("الأصوات العربية مدمجة في التطبيق. الجمل الإنجليزية تُقرأ بصوت آبل.")
                }

                Section("سرعة الكلام") {
                    Slider(value: $settings.speechRate, in: 0.7...1.4, step: 0.05) {
                        Text("السرعة")
                    } minimumValueLabel: { Text("أبطأ") } maximumValueLabel: { Text("أسرع") }
                }

                Section {
                    Slider(value: $settings.patience, in: 0...1) {
                        Text("الصبر")
                    } minimumValueLabel: { Text("سريع") } maximumValueLabel: { Text("صبور") }
                } header: {
                    Text("متى يرد عليك")
                } footer: {
                    Text("سريع: يرد أول ما توقف. صبور: يعطيك وقت تفكر بين الكلام. يتطبق من المكالمة الجاية.")
                }

                Section("لغة السمع") {
                    Picker("اللغة", selection: $settings.language) {
                        Text("تلقائي").tag("auto")
                        Text("عربي").tag("ar")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextEditor(text: $settings.persona).frame(minHeight: 160)
                    Button("رجّع الافتراضي") { settings.persona = AppSettings.defaultPersona }
                } header: {
                    Text("شخصية المساعد")
                }

                Section {
                    LabeledContent("الإصدار", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    LabeledContent("كل شي على الجهاز", value: "بدون سيرفر")
                }
            }
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
    }
}
