import SwiftUI
import Foundation
import UIKit

// MARK: - Data Models

enum MessageSegment: Identifiable {
    case text(String)
    case playAction(trackId: String)
    var id: String {
        switch self {
        case .text(let t): return "text-\(t.hashValue)"
        case .playAction(let id): return "play-\(id)"
        }
    }
}

struct VeloraChatMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    var text: String
    
    var segments: [MessageSegment] {
        var result: [MessageSegment] = []
        let pattern = "\\[PLAY:\\s*([^]]+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(text)]
        }
        
        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        
        var currentIndex = 0
        for match in matches {
            if match.range.location > currentIndex {
                let textPart = nsString.substring(with: NSRange(location: currentIndex, length: match.range.location - currentIndex))
                if !textPart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.text(textPart.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            let trackId = nsString.substring(with: match.range(at: 1))
            result.append(.playAction(trackId: trackId.trimmingCharacters(in: .whitespacesAndNewlines)))
            currentIndex = match.range.location + match.range.length
        }
        
        if currentIndex < nsString.length {
            let remainder = nsString.substring(from: currentIndex)
            if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || matches.isEmpty {
                // Only keep raw spaces if there are no matches at all, otherwise trim
                let finalStr = matches.isEmpty ? remainder : remainder.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalStr.isEmpty {
                    result.append(.text(finalStr))
                }
            }
        }
        return result
    }
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
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(VeloraChatMessage(isUser: true, text: trimmed))
        inputText = ""
        isStreaming = true
        messages.append(VeloraChatMessage(isUser: false, text: ""))
        let index = messages.count - 1

        Task { @MainActor in
            await stream(prompt: trimmed, context: context, at: index)
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

        let history = messages.prefix(upTo: index).map {
            ["role": $0.isUser ? "user" : "assistant", "content": $0.text]
        }
        var body: [String: Any] = ["messages": Array(history)]
        if let ctx = context { body["context"] = ctx }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
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

// MARK: - TrackChipView

struct TrackChipView: View {
    let trackId: String
    @EnvironmentObject var playback: PlaybackManager
    @EnvironmentObject var client: NavidromeClient
    
    private var track: Track? {
        client.allSongs.first(where: { $0.id == trackId })
    }
    
    var body: some View {
        if let track = track {
            Button {
                playback.loadAndPlay(track: track)
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: track.coverArtUrl) { phase in
                        switch phase {
                        case .empty:
                            Rectangle().fill(Color.gray.opacity(0.3))
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        case .failure:
                            Rectangle().fill(Color.gray.opacity(0.3))
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(track.artist ?? "Unknown Artist")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(PlainButtonStyle())
        } else {
            Text("[Track Not Found]")
                .font(.system(size: 14))
                .foregroundColor(.red)
        }
    }
}

// MARK: - View

struct VeloraChatView: View {
    @StateObject private var vm = VeloraChatViewModel()
    @EnvironmentObject var playback: PlaybackManager
    @EnvironmentObject var client: NavidromeClient
    @AppStorage("velora_theme_preference") private var isDarkMode: Bool = true
    @State private var scrollID: UUID? = nil

    private var bg: Color { isDarkMode ? Color.black : Color(hex: "#f0f0f0") }
    private var fg: Color { isDarkMode ? .white : .black }
    private var bubble: Color { isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06) }

    var body: some View {
        ZStack {
            // Solid background for performance
            bg.ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer().frame(height: 100)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(vm.messages, id: \.id) { msg in
                                HStack(alignment: .bottom, spacing: 0) {
                                    if msg.isUser { Spacer(minLength: 40) }
                                    
                                    VStack(alignment: msg.isUser ? .trailing : .leading, spacing: 8) {
                                        ForEach(msg.segments) { segment in
                                            switch segment {
                                            case .text(let text):
                                                Text(text.isEmpty && !msg.isUser ? "▍" : text)
                                                    .font(.system(size: 16))
                                                    .foregroundColor(fg)
                                                    .padding(.horizontal, 16)
                                                    .padding(.vertical, 12)
                                                    .background(msg.isUser ? Color.accentColor : bubble)
                                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                            case .playAction(let trackId):
                                                TrackChipView(trackId: trackId)
                                                    .frame(maxWidth: 250)
                                            }
                                        }
                                    }
                                    
                                    if !msg.isUser { Spacer(minLength: 40) }
                                }
                                .id(msg.id)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                    .contentShape(Rectangle()) // Fix for the tap gesture intercept
                    // .scrollDismissesKeyboard(.interactively)
                    .onTapGesture {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .onChange(of: vm.messages.count) { _, _ in
                        guard let last = vm.messages.last else { return }
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }

                inputBar
            }
            .background(Color.clear)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if vm.inputText.isEmpty {
                    Text("Ask Velora...")
                        .font(.system(size: 16))
                        .foregroundColor(fg.opacity(0.5))
                        .padding(.top, 14)
                        .padding(.leading, 18)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $vm.inputText)
                    .font(.system(size: 16))
                    .foregroundColor(fg)
                    .frame(minHeight: 44, maxHeight: 120)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.clear)
                    .onChange(of: vm.inputText) { newValue in
                        if newValue.hasSuffix("\n") {
                            vm.inputText.removeLast()
                            let ctx = playback.currentTrack.map { "Currently playing: \($0.title)" }
                            vm.send(context: ctx)
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                    }
            }
            .background(bubble)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onAppear { UITextView.appearance().backgroundColor = .clear }
            .onDisappear { UITextView.appearance().backgroundColor = nil }

            Button {
                let ctx = playback.currentTrack.map { "Currently playing: \($0.title)" }
                vm.send(context: ctx)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(
                        vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? fg.opacity(0.3) : .accentColor
                    )
            }
            .disabled(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(bg)
    }
}
