import SwiftUI

struct LogsView: View {
    @ObservedObject var logger = AppLogger.shared
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(logger.logs) { entry in
                            HStack(alignment: .top) {
                                Text(entry.timestamp, style: .time)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.gray)
                                    .frame(width: 65, alignment: .leading)
                                
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(entry.level.color)
                            }
                            .padding(.horizontal)
                            .id(entry.id)
                        }
                    }
                    .padding(.vertical)
                    .onChange(of: logger.logs.count) { _ in
                        if let lastId = logger.logs.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }
            .navigationTitle("App Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button(action: {
                            let allLogs = logger.logs.map { "[\($0.timestamp)] [\($0.level)] \($0.message)" }.joined(separator: "\n")
                            UIPasteboard.general.string = allLogs
                        }) {
                            Image(systemName: "doc.on.doc")
                            Text("Copy")
                        }
                        
                        Button("Clear") {
                            logger.logs.removeAll()
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}
