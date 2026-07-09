import SwiftUI

struct LogsView: View {
    @ObservedObject var logger = AppLogger.shared
    @Environment(\.presentationMode) var presentationMode
    @State private var showingShareSheet = false
    @State private var copiedFeedback = false

    private var allLogsAsText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return logger.logs.reversed().map { entry in
            let ts = formatter.string(from: entry.timestamp)
            let prefix: String
            switch entry.level {
            case .debug:   prefix = "[DEBUG]"
            case .info:    prefix = "[INFO] "
            case .warning: prefix = "[WARN] "
            case .error:   prefix = "[ERROR]"
            }
            return "\(ts) \(prefix) \(entry.message)"
        }.joined(separator: "\n")
    }

    var body: some View {
        NavigationView {
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(logger.logs.reversed()) { entry in
                            HStack(alignment: .top) {
                                Text(entry.timestamp, style: .time)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.gray)
                                    .frame(width: 65, alignment: .leading)

                                // textSelection(.enabled) makes each line tap-to-copy on iOS
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(entry.level.color)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal)
                            .id(entry.id)
                        }
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("App Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        // Copy All button
                        Button {
                            UIPasteboard.general.string = allLogsAsText
                            withAnimation { copiedFeedback = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { copiedFeedback = false }
                            }
                        } label: {
                            Label(
                                copiedFeedback ? "Copied!" : "Copy All",
                                systemImage: copiedFeedback ? "checkmark" : "doc.on.doc"
                            )
                            .foregroundColor(copiedFeedback ? .green : .accentColor)
                        }

                        // Share / Export button
                        Button {
                            showingShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }

                        Button("Clear") {
                            logger.logs.removeAll()
                        }
                        .foregroundColor(.red)
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(items: [allLogsAsText])
            }
        }
    }
}

// UIKit share sheet wrapper
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}
