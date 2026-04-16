import SwiftUI
import AVFoundation

struct ContentView: View {

    @StateObject private var stts = STTS()

    private var micIcon: String {
        guard stts.is_active else { return "mic.slash" }
        return stts.is_speech_detected ? "waveform" : "mic.fill"
    }

    private var micColor: Color {
        guard stts.is_active else { return .gray }
        return stts.is_speech_detected ? .red : .orange
    }

    var body: some View {
        VStack(spacing: 20.0) {
            Image(systemName: micIcon)
                .imageScale(.large)
                .foregroundStyle(micColor)
            transcriptView
            controlsView
            toggleButton
        }
        .padding()
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10.0) {
                    ForEach(stts.transcript_log, id: \.self) { line in
                        Text(line)
                            .padding(8.0)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8.0)
                    }
                }
                .padding()
            }
            .onChange(of: stts.transcript_log) { _, new in
                if let last = new.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .border(Color.secondary.opacity(0.2), width: 1.0)
    }

    private var controlsView: some View {
        let rateMin = Double(AVSpeechUtteranceMinimumSpeechRate)
        let rateMax = Double(AVSpeechUtteranceMaximumSpeechRate)
        return VStack(spacing: 15.0) {
            Picker("Voice Gender", selection: $stts.selected_gender) {
                Text("Any").tag(0)
                Text("Male").tag(1)
                Text("Female").tag(2)
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Speed")
                Slider(value: $stts.speech_rate, in: rateMin...rateMax)
            }
            HStack {
                Text("Pitch")
                Slider(value: $stts.speech_pitch, in: 0.5...2.0)
            }
        }
        .padding(.horizontal)
    }

    private var toggleButton: some View {
        Button {
            if stts.is_running {
                stts.stop_dialog_session()
            } else {
                stts.start_dialog_session()
            }
        } label: {
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                Text(stts.is_running ? "Stop Dialog" : "Start Dialog")
            }
            .padding()
            .background(stts.is_running ? Color.red : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12.0)
        }
    }
}
