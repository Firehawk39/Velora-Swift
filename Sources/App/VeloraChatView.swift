import SwiftUI
import Foundation

// MARK: - Data Models

struct VeloraChatMessage: Identifiable, Equatable {
    let id = UUID()
    let isUser: Bool
    var text: String
}

// MARK: - ViewModel

@MainActor
final class VeloraChatViewModel: ObservableObject {
    @Published var messages: [VeloraChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false

    private var engineBaseUrl: URL? {
        guard let serverStr = UserDefaults.standard.string(forKey: "velora_server_url"),
              var components = URLComponents(string: serverStr) else {
            return URL(string: "http://localhost:8000/api/v1")
        }
        components.port = 8000
        components.path = "/api/v1"
        return components.url
    }

    func send(context: String?) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(VeloraChatMessage(isUser: true, text: text))
        inputText = ""
        isStreaming = true

        let replyIndex = messages.count
        messages.append(VeloraChatMessage(isUser: false, text: ""))

        Task {
            await stream(prompt: text, context: context, at: replyIndex)
        }
    }

    private func stream(prompt: String, context: String?, at index: Int) async {
        guard let base = engineBaseUrl else {
            messages[index].text = "Could not reach Velora AI Engine."
            isStreaming = false
            return
        }

        var request = URLRequest(url: base.appendingPathComponent("chat/message"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body: [String: Any] = ["message": prompt]
        if let ctx = context { body["context"] = ctx }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                messages[index].text = "Server error. Is Velora running?"
                isStreaming = false
                return
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }
                if let data = payload.data(using: .utf8),
                   let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) {
                    messages[index].text += chunk.content
                }
            }
        } catch {
            messages[index].text = "Connection error: \(error.localizedDescription)"
        }
        isStreaming = false
    }

    private struct StreamChunk: Decodable { let content: String }
}

// MARK: - View

struct VeloraChatView: View {
    @StateObject private var vm = VeloraChatViewModel()
    @EnvironmentObject var playback: PlaybackManager
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true

    private var bg: Color { isDarkMode ? Color(hex: "#121212") : Color(hex: "#fafafa") }
    private var fg: Color { isDarkMode ? .white : .black }
    private var bubble: Color { isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 100)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(vm.messages) { msg in
                            HStack {
                                if msg.isUser { Spacer(minLength: 60) }
                                Text(msg.text.isEmpty && !msg.isUser ? "▍" : msg.text)
                                    .font(.custom("Stardom", size: 16))
                                    .foregroundColor(fg)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(bubble)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .frame(maxWidth: .infinity, alignment: msg.isUser ? .trailing : .leading)
                                if !msg.isUser { Spacer(minLength: 60) }
                            }
                            .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
                .onChange(of: vm.messages.count) { _ in
                    if let last = vm.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            inputBar
        }
        .background(bg.ignoresSafeArea())
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if vm.inputText.isEmpty {
                    Text("Ask Velora...")
                        .font(.custom("Stardom", size: 16))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                TextEditor(text: $vm.inputText)
                    .font(.custom("Stardom", size: 16))
                    .foregroundColor(fg)
                    .frame(minHeight: 44, maxHeight: 120)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .scrollContentBackground(.hidden)
            }
            .background(bubble)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button {
                let ctx = playback.currentTrack.map { "Currently playing: \($0.title)" }
                vm.send(context: ctx)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : fg)
            }
            .disabled(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(bg)
    }
}
