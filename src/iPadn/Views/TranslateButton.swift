import NaturalLanguage
import SwiftUI
import Translation

struct TranslateButton: View {
    let text: String
    @Binding var translation: String?
    @State private var presented = false

    static var available: Bool {
        if #available(iOS 17.4, *) { return true }
        return false
    }

    static func isForeign(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(600)))
        guard let found = recognizer.dominantLanguage?.rawValue else { return false }
        let mine = AppText.locale.language.languageCode?.identifier ?? "en"
        return !found.hasPrefix(mine)
    }

    static func offered(for text: String, translation: String?) -> Bool {
        translation != nil || (available && isForeign(text))
    }

    var body: some View {
        if translation != nil {
            Button { withAnimation(.easeOut(duration: 0.2)) { translation = nil } } label: {
                Label("Show Original", systemImage: "character.bubble")
            }
        } else if #available(iOS 17.4, *) {
            Button { presented = true } label: { Label("Translate", systemImage: "translate") }
                .translationPresentation(isPresented: $presented, text: text) { translated in
                    withAnimation(.easeOut(duration: 0.2)) { translation = translated }
                }
        }
    }
}
