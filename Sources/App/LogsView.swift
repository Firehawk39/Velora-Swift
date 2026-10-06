import SwiftUI
import UIKit

// MARK: - Selectable Log Line (UITextView bridge)
// Each log line is backed by a non-editable UITextView so iOS gives us:
//   • Long-press  → blinking cursor + magnifier glass
//   • Drag handles → custom text range selection
//   • System menu  → Copy / Select All (native, no extra code needed)
private struct SelectableLogLine: UIViewRepresentable {
    let text: String
    let textColor: UIColor
    let font: UIFont

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false          // Read-only — keyboard never appears
        tv.isSelectable = true         // Enables cursor + selection handles
        tv.isScrollEnabled = false     // Parent ScrollView owns vertical scrolling
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let newText = NSAttributedString(string: text, attributes: attrs)
        // Avoid unnecessary re-renders that reset the active selection
        if tv.attributedText != newText {
            tv.attributedText = newText
        }
    }

    /// Tell SwiftUI the exact height this text view needs so the parent
    /// LazyVStack never clips or over-allocates space for a line.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? (UIScreen.main.bounds.width - 24)
        let size = tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }
}

// MARK: - LogsView

struct LogsView: View {
    @ObservedObject var logger = AppLogger.shared
    @Environment(\.presentationMode) var presentationMode

    @State private var showingShareSheet = false
    @State private var copiedFeedback = false
    @State private var copiedLineId: UUID? = nil

    private let monoFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    // MARK: Helpers

    private func formattedLine(_ entry: AppLogger.LogEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let ts = formatter.string(from: entry.timestamp)
        let prefix: String
        switch entry.level {
        case .debug:   prefix = "[DEBUG]"
        case .info:    prefix = "[INFO] "
        case .warning: prefix = "[WARN] "
        case .error:   prefix = "[ERROR]"
        }
        return "\(ts) \(prefix) \(entry.message)"
    }

    private var allLogsAsText: String {
        logger.logs.reversed().map { formattedLine($0) }.joined(separator: "\n")
    }

    // MARK: Body

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(logger.logs.reversed()) { entry in
                        let lineText = formattedLine(entry)

                        SelectableLogLine(
                            text: lineText,
                            textColor: UIColor(entry.level.color),
                            font: monoFont
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = lineText
                                withAnimation(.easeOut(duration: 0.2)) { copiedLineId = entry.id }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation { if copiedLineId == entry.id { copiedLineId = nil } }
                                }
                            } label: {
                                Label("Copy Line", systemImage: "doc.on.doc")
                            }

                            Button {
                                UIPasteboard.general.string = entry.message
                                withAnimation(.easeOut(duration: 0.2)) { copiedLineId = entry.id }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation { if copiedLineId == entry.id { copiedLineId = nil } }
                                }
                            } label: {
                                Label("Copy Message Only", systemImage: "text.alignleft")
                            }

                            Divider()

                            Button {
                                UIPasteboard.general.string = allLogsAsText
                                withAnimation { copiedFeedback = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation { copiedFeedback = false }
                                }
                            } label: {
                                Label("Copy All Logs", systemImage: "doc.on.clipboard")
                            }
                        }
                        .background(
                            copiedLineId == entry.id
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .animation(.easeOut(duration: 0.3), value: copiedLineId)
                        .id(entry.id)

                        Divider().opacity(0.07)
                    }
                }
                .padding(.vertical, 6)
            }
            .navigationTitle("App Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
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

// MARK: - UIKit share sheet wrapper
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}
