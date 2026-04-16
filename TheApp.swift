import SwiftUI
import Speech

@main struct TheApp: SwiftUI.App {

    init() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    var body: some Scene { WindowGroup { ContentView() } }
}
