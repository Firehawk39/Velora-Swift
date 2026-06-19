import SwiftUI
import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let isUser: Bool
    var text: String
}

@MainActor
final class VeloraChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isTyping: Bool = false
    
    private var engineBaseUrl: URL? {
        guard let serverStr = UserDefaults.standard.string(forKey: "velora_server_url"),
              var components = URLComponents(string: serverStr) else {
            return URL(string: "http://localhost:8000/api/v1")
        }
        components.port = 8000
        components.path = "/api/v1"
        return components.url
    }
    
    func sendMessage(context: String? = nil) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        messages.append(ChatMessage(isUser: true, text: text))
        inputText = ""
        isTyping = true
        
        // Append an empty AI message that we will stream into
        let aiMessageIndex = messages.count
        messages.append(ChatMessage(isUser: false, text: ""))
        
        Task {
            await streamResponse(for: text, at: aiMessageIndex, context: context)
        }
    }
    
    private func streamResponse(for query: String, at index: Int, context: String?) async {
        guard let baseUrl = engineBaseUrl else {
            messages[index].text = "Error: Could not locate AI Engine."
            isTyping = false
            return
        }
        
        let endpoint = baseUrl.appendingPathComponent("chat/message")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any?] = [
            "message": query,
            "context": context
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        do {
            let (result, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                await MainActor.run {
                    self.messages[index].text = "Error: Server returned an error."
                    self.isTyping = false
                }
                return
            }
            
            for try await line in result.lines {
                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = line.dropFirst(6)
                if jsonStr == "[DONE]" { break }
                
                if let data = jsonStr.data(using: .utf8),
                   let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data) {
                    await MainActor.run {
                        self.messages[index].text += chunk.content
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.messages[index].text = "Network Error: \(error.localizedDescription)"
            }
        }
        
        await MainActor.run {
            self.isTyping = false
        }
    }
    
    private struct ChatChunk: Codable {
        let content: String
    }
}

struct VeloraChatView: View {
    @StateObject private var viewModel = VeloraChatViewModel()
    @EnvironmentObject var playback: PlaybackManager
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Spacer to avoid overlapping with AppHeader
            Spacer().frame(height: 100)
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(viewModel.messages) { message in
                            ChatBubble(message: message, isDarkMode: isDarkMode)
                                .id(message.id)
                        }
                        if viewModel.isTyping {
                            TypingIndicator(isDarkMode: isDarkMode)
                                .id("typing")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
                .onChange(of: viewModel.messages) { _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.isTyping) { _ in
                    scrollToBottom(proxy: proxy)
                }
            }
            
            inputArea
        }
        .background(
            (isDarkMode ? Color(hex: "#121212") : Color(hex: "#fafafa")).ignoresSafeArea()
        )
    }
    
    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Ask Velora...", text: $viewModel.inputText, axis: .vertical)
                .font(.custom("Stardom", size: 16))
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
                .cornerRadius(20)
                .foregroundColor(isDarkMode ? .white : .black)
            
            Button(action: {
                // Pass current track title as context
                let ctx = playback.currentTrack?.title ?? ""
                viewModel.sendMessage(context: "Currently listening to: \(ctx)")
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : (isDarkMode ? .white : .black))
            }
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(isDarkMode ? Color(hex: "#121212") : Color.white)
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation {
            if viewModel.isTyping {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let last = viewModel.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let isDarkMode: Bool
    
    var body: some View {
        HStack {
            if message.isUser { Spacer() }
            
            Text(message.text)
                .font(.custom("Stardom", size: 16))
                .foregroundColor(message.isUser ? .white : (isDarkMode ? .white : .black))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    Group {
                        if message.isUser {
                            (isDarkMode ? Color.white.opacity(0.2) : Color.black.opacity(0.8))
                        } else {
                            (isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
                        }
                    }
                )
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05), lineWidth: message.isUser ? 0 : 1)
                )
            
            if !message.isUser { Spacer() }
        }
    }
}

struct TypingIndicator: View {
    let isDarkMode: Bool
    @State private var phase = 0.0
    
    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(isDarkMode ? Color.white.opacity(0.5) : Color.black.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .offset(y: phase == Double(i) ? -4 : 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
            .cornerRadius(20)
            
            Spacer()
        }
        .onAppear {
            withAnimation(Animation.linear(duration: 0.6).repeatForever(autoreverses: false)) {
                phase = 3.0
            }
        }
    }
}

struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style = .systemMaterial
    func makeUIView(context: Context) -> UIVisualEffectView {
        return UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}
