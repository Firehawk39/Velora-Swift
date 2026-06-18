import SwiftUI
import UIKit

// 3-step wizard matching the web app exactly:
// Step 1: Server URL  →  Step 2: Username + Password  →  (Optional) Step 3: Display name
enum SettingsStep { case server, login, client }

@MainActor
struct SettingsView: View {
    @Binding var showSettings: Bool
    @EnvironmentObject var client: NavidromeClient
    @Environment(\.colorScheme) var colorScheme

    var isDark: Bool { colorScheme == .dark }

    @State private var step: SettingsStep = .server
    @State private var serverAddress: String = UserDefaults.standard.string(forKey: "velora_server_url") ?? "http://"
    @State private var username: String     = UserDefaults.standard.string(forKey: "velora_username") ?? ""
    @State private var password: String     = ""
    @State private var showPassword: Bool   = false
    @State private var status: ConnStatus  = .idle
    @State private var cacheCleared: Bool   = false
    @State private var cacheSize: String    = "Calculating..."
    @State private var downloadingAll: Bool = false
    @State private var showLogs: Bool       = false

    enum ConnStatus { case idle, connecting, connected, error }

    // Accent colour — exactly matches web's #a8c7fa
    let accentBg   = Color(hex: "#a8c7fa")
    let accentFg   = Color(hex: "#0b1b32")
    let borderCol  = Color(hex: "#374151")
    let labelCol   = Color(hex: "#60a5fa")

    var body: some View {
        ZStack {
            (isDark ? Color.black : Color(hex: "#f0f0f0"))
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                // ── Logo ──────────────────────────────────────────
                Text("Velora.")
                    .font(.custom("Stardom", size: ScreenTier.isSE ? 56 : 72).weight(.bold))
                    .kerning(-2.5)
                    .foregroundColor(isDark ? .white : .black)
                    .padding(.top, ScreenTier.isSE ? 30 : 60)
                    .padding(.bottom, ScreenTier.isSE ? 32 : 48)

                // ── Step content ──────────────────────────────────
                switch step {
                case .server: serverStep
                case .login:  loginStep
                case .client: EmptyView()
                }

                Spacer()
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            let clientRef = client
            DispatchQueue.global(qos: .background).async {
                let size = clientRef.getMediaCacheSize()
                DispatchQueue.main.async {
                    self.cacheSize = size
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // STEP 1 — Server URL
    // ─────────────────────────────────────────────────────────────
    private var serverStep: some View {
        VStack(spacing: 0) {
            // Floating-label field
            FloatingLabelField(
                label: "Server Endpoint URL",
                placeholder: "http://your-server-ip:4533",
                text: $serverAddress,
                isDark: isDark,
                borderCol: borderCol,
                labelCol: labelCol,
                contentType: .URL
            )

            // Next button
            Button(action: { if isValidUrl(serverAddress) { withAnimation { step = .login } } }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right")
                    Text("Next")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(isValidUrl(serverAddress) ? accentBg : accentBg.opacity(0.5))
                .foregroundColor(accentFg)
                .cornerRadius(100)
            }
            .disabled(!isValidUrl(serverAddress))
            .padding(.top, 28)

            // Settings shortcut (matches web)
            Button(action: { withAnimation { step = .client } }) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").font(.system(size: 18))
                    Text("Settings").font(.system(size: 18, weight: .medium))
                }
                .foregroundColor(Color(hex: "#9ca3af"))
            }
            .padding(.top, 28)
        }
        .padding(.horizontal, 24)
        .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)).combined(with: .opacity))
    }

    // ─────────────────────────────────────────────────────────────
    // STEP 2 — Credentials
    // ─────────────────────────────────────────────────────────────
    private var loginStep: some View {
        VStack(spacing: 0) {
            // Server badge (matches the web pill showing the URL)
            Text(serverAddress)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#9ca3af"))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 100).stroke(Color.white.opacity(0.1), lineWidth: 1))
                .cornerRadius(100)
                .padding(.bottom, 20)

            FloatingLabelField(
                label: "Username",
                placeholder: "username",
                text: $username,
                isDark: isDark,
                borderCol: borderCol,
                labelCol: labelCol,
                contentType: .username
            )

            FloatingLabelField(
                label: "Password",
                placeholder: "password",
                text: $password,
                isDark: isDark,
                borderCol: borderCol,
                labelCol: labelCol,
                isSecure: !showPassword,
                contentType: .password,
                trailingIcon: showPassword ? "eye.slash" : "eye",
                onTrailingTap: { showPassword.toggle() },
                onSubmit: handleConnect
            )
            .padding(.top, 20)

            if status == .error {
                Text("Connection Failed. Check credentials.")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.5)
                    .foregroundColor(Color(hex: "#f87171"))
                    .padding(.top, 10)
                    .textCase(.uppercase)
            }

            // Login button
            Button(action: handleConnect) {
                HStack(spacing: 8) {
                    if status == .connecting {
                        LoadingCircle(size: 20, strokeWidth: 2, accentColor: accentFg)
                    } else {
                        Image(systemName: "arrow.right")
                    }
                    Text(status == .connecting ? "Connecting..." : "Login")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(status == .connecting || username.isEmpty || password.isEmpty
                    ? accentBg.opacity(0.5) : accentBg)
                .foregroundColor(accentFg)
                .cornerRadius(100)
            }
            .disabled(status == .connecting || username.isEmpty || password.isEmpty)
            .padding(.top, 28)

            // Back button
            Button(action: { withAnimation { step = .server } }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left").font(.system(size: 13))
                    Text("Back").font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(Color(hex: "#9ca3af"))
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)).combined(with: .opacity))
    }


    // ─────────────────────────────────────────────────────────────
    // Logic
    // ─────────────────────────────────────────────────────────────
    private func isValidUrl(_ s: String) -> Bool {
        guard let url = URL(string: s), let scheme = url.scheme else { return false }
        return scheme.hasPrefix("http") && url.host != nil
    }

    private func handleConnect() {
        guard !username.isEmpty, !password.isEmpty else { return }
        
        // Explicitly dismiss keyboard to trigger iOS Password AutoFill save prompt
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        status = .connecting

        // 1. Configure the client temporarily to test
        client.configure(url: serverAddress, user: username, pass: password)
        
        // 2. Perform actual verification with server
        client.ping { success, errorMessage in
            DispatchQueue.main.async {
                if success {
                    status = .connected
                    
                    // 3. Persist configuration only on success
                    UserDefaults.standard.set(serverAddress, forKey: "velora_server_url")
                    UserDefaults.standard.set(username, forKey: "velora_username")
                    
                    // 4. Securely save password in Keychain
                    if let passData = password.data(using: .utf8) {
                        KeychainHelper.shared.save(passData, service: "velora-password", account: username)
                    }
                    
                    // 5. Save comprehensive settings to Keychain for AutoLogin
                    var bundle = VeloraCredentialsBundle(serverUrl: self.serverAddress, onlineServerUrl: "", username: self.username, connectionMode: 0)
                    if let existingData = KeychainHelper.shared.read(service: "velora-credentials", account: "default"),
                       let existing = try? JSONDecoder().decode(VeloraCredentialsBundle.self, from: existingData) {
                        bundle.onlineServerUrl = existing.onlineServerUrl
                        bundle.connectionMode = existing.connectionMode
                    }
                    if let bundleData = try? JSONEncoder().encode(bundle) {
                        KeychainHelper.shared.save(bundleData, service: "velora-credentials", account: "default")
                    }
                    
                    // 5. Trigger initial data sync
                    client.fetchEverything()
                    
                    // 6. Dismiss after short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        showSettings = false
                    }
                } else {
                    status = .error
                    print("Login failed: \(errorMessage ?? "Unknown error")")
                }
            }
        }
    }
}

// MARK: - Floating Label Field  (matches web's border-label inputs)

struct FloatingLabelField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let isDark: Bool
    let borderCol: Color
    let labelCol: Color
    var isSecure: Bool = false
    var contentType: UITextContentType? = nil
    var trailingIcon: String? = nil
    var onTrailingTap: (() -> Void)? = nil
    var onSubmit: (() -> Void)? = nil

    @State private var isFocused = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Floating label
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isFocused ? labelCol : labelCol.opacity(0.8))
                .padding(.horizontal, 8)
                .background(isDark ? Color.black : Color(hex: "#f0f0f0"))
                .offset(x: 16, y: -10)
                .zIndex(1)

            // Input
            HStack {
                if isSecure {
                    SecureField(placeholder, text: $text)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { onSubmit?() }
                } else {
                    TextField(placeholder, text: $text)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textContentType(contentType)
                        .submitLabel(.next)
                }

                if let icon = trailingIcon {
                    Button(action: { onTrailingTap?() }) {
                        Image(systemName: icon)
                            .foregroundColor(Color(hex: "#6b7280"))
                            .font(.system(size: 16))
                    }
                }
            }
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(isDark ? .white : Color(hex: "#111827"))
            .padding(.horizontal, 20)
            .frame(height: 64)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isFocused ? labelCol : borderCol, lineWidth: 1.5)
            )
            .background(Color.clear)
            .cornerRadius(16)
            .onTapGesture { isFocused = true }
        }
        .padding(.top, 8)  // space for floating label
    }
}

// MARK: - Actual Settings View (Logged In)
struct AppSettingsView: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var client: NavidromeClient
    @EnvironmentObject var sync: SyncManager
    @AppStorage("velora_server_url") private var serverUrl: String = ""
    @AppStorage("velora_online_server_url") private var onlineServerUrl: String = ""
    @AppStorage("velora_username") private var username: String = ""
    @AppStorage("velora_connection_mode") private var connectionMode: Int = 0
    @State private var cacheCleared = false
    @State private var cacheSize: String = "Calculating..."
    @AppStorage("velora_download_concurrency") private var downloadConcurrency: Int = 5
    @AppStorage("velora_crossfade_enabled") private var isCrossfadeEnabled: Bool = false
    @AppStorage("velora_crossfade_duration") private var crossfadeDuration: Double = 5.0
    @State private var showLogs: Bool = false
    // Constants matching web app
    let accentBg   = Color(hex: "#a8c7fa")
    let accentFg   = Color(hex: "#0b1b32")
    let borderCol  = Color(hex: "#374151")
    let labelCol   = Color(hex: "#60a5fa")

    var isDark: Bool { colorScheme == .dark }
    
    private func syncSettingsToKeychain() {
        let bundle = VeloraCredentialsBundle(serverUrl: serverUrl, onlineServerUrl: onlineServerUrl, username: username, connectionMode: connectionMode)
        if let data = try? JSONEncoder().encode(bundle) {
            KeychainHelper.shared.save(data, service: "velora-credentials", account: "default")
        }
    }

    var body: some View {
        ZStack {
            (isDark ? Color.black : Color(hex: "#fafafa"))
                .edgesIgnoringSafeArea(.all)
            
            ScrollView {
                VStack(spacing: 48) {
                    // Header
                    VStack(spacing: 8) {
                        Text("Settings")
                            .font(.custom("Stardom", size: ScreenTier.isSE ? 40 : 48))
                            .fontWeight(.bold)
                            .foregroundColor(isDark ? .white : .black)
                        
                        Text("Manage your account and app preferences")
                            .font(.system(size: 16))
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 140)
                    .frame(maxWidth: .infinity, alignment: .center)
                    
                    VStack(spacing: 32) {
                        // Account Section
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Account")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(labelCol)
                                .textCase(.uppercase)
                                .padding(.leading, 4)
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Connection Mode")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(isDark ? .white : .black)
                                
                                Picker("Connection Mode", selection: $connectionMode) {
                                    Text("Local").tag(0)
                                    Text("Online").tag(1)
                                    Text("Offline").tag(2)
                                }
                                .pickerStyle(SegmentedPickerStyle())
                                .onChange(of: connectionMode) { newValue in
                                    syncSettingsToKeychain()
                                    NetworkMonitor.shared.evaluateConnectionState()
                                    if newValue != 2 {
                                        reconnectWithCurrentMode()
                                    }
                                }
                                
                                Text(connectionMode == 0 ? "Using local server URL" : (connectionMode == 1 ? "Using remote server (zrok.io)" : "Forcing offline mode (No network requests)"))
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                            }
                            .padding()
                            .background(isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.03))
                            .cornerRadius(16)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderCol.opacity(0.3), lineWidth: 1))
                            
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Local Server").font(.system(size: 12, weight: .medium)).foregroundColor(.gray)
                                    Text(serverUrl).font(.system(size: 14)).foregroundColor(isDark ? .white.opacity(0.6) : .black.opacity(0.6))
                                }
                                
                                Divider().opacity(0.1)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Online Server").font(.system(size: 12, weight: .medium)).foregroundColor(.gray)
                                    TextField("https://your-online-server.com", text: $onlineServerUrl, onCommit: {
                                        syncSettingsToKeychain()
                                        if connectionMode == 1 { reconnectWithCurrentMode() }
                                    })
                                    .font(.system(size: 14))
                                    .foregroundColor(isDark ? .white.opacity(0.8) : .black.opacity(0.8))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                }
                                
                                Divider().opacity(0.1)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("User").font(.system(size: 12, weight: .medium)).foregroundColor(.gray)
                                    Text(username).font(.system(size: 14)).foregroundColor(isDark ? .white.opacity(0.6) : .black.opacity(0.6))
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.03))
                            .cornerRadius(16)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderCol.opacity(0.3), lineWidth: 1))
                        }
                        
                        
                        // App Data Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("App Data")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(labelCol)
                                .textCase(.uppercase)
                                .padding(.leading, 4)
                            
                            Button(action: {
                                if sync.isSyncingMetadata {
                                    sync.stopMetadataSync()
                                } else {
                                    sync.startMetadataSync()
                                }
                            }) {
                                HStack {
                                    Image(systemName: "info.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(sync.isSyncingMetadata ? .blue : labelCol)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sync.isSyncingMetadata ? "Syncing Info..." : "Download Library Metadata")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(isDark ? .white : .black)
                                        Text((sync.isSyncingMetadata || sync.metadataStatus.lowercased().contains("complete")) ? sync.metadataStatus : "Artist bios, portraits, and album details")
                                            .font(.system(size: 12))
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                    
                                    if sync.isSyncingMetadata {
                                        HStack(spacing: 8) {
                                            if !sync.metadataEta.isEmpty {
                                                Text(sync.metadataEta)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(.gray)
                                            }
                                            CircularProgressView(progress: sync.metadataProgress, size: 24, strokeWidth: 3, accentColor: .blue)
                                        }
                                    } else if sync.metadataStatus.lowercased().contains("complete") {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.green)
                                    } else {
                                        Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(.gray)
                                    }
                                }
                                .padding()
                                .background(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                                .cornerRadius(16)
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderCol.opacity(0.3), lineWidth: 1))
                            }
                            .simultaneousGesture(LongPressGesture().onEnded { _ in
                                client.clearMetadataCache()
                                sync.metadataStatus = "Metadata Cleared!"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sync.metadataStatus = "" }
                            })

                            // Lyrics Sync Button
                            Button(action: {
                                if sync.isSyncingLyrics {
                                    sync.stopLyricsSync()
                                } else {
                                    sync.startLyricsSync()
                                }
                            }) {
                                HStack {
                                    Image(systemName: "text.quote")
                                        .font(.system(size: 20))
                                        .foregroundColor(sync.isSyncingLyrics ? .purple : labelCol)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sync.isSyncingLyrics ? "Downloading Lyrics..." : "Download All Lyrics")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(isDark ? .white : .black)
                                        Text((sync.isSyncingLyrics || sync.lyricsStatus.lowercased().contains("complete")) ? sync.lyricsStatus : "Cache time-synced lyrics for offline use")
                                            .font(.system(size: 12))
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                    
                                    if sync.isSyncingLyrics {
                                        HStack(spacing: 8) {
                                            if !sync.lyricsEta.isEmpty {
                                                Text(sync.lyricsEta)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(.gray)
                                            }
                                            CircularProgressView(progress: sync.lyricsProgress, size: 24, strokeWidth: 3, accentColor: .purple)
                                        }
                                    } else if sync.lyricsStatus.lowercased().contains("complete") {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.green)
                                    } else {
                                        Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(.gray)
                                    }
                                }
                                .padding()
                                .background(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                                .cornerRadius(16)
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderCol.opacity(0.3), lineWidth: 1))
                            }
                            .simultaneousGesture(LongPressGesture().onEnded { _ in
                                client.clearLyricsCache()
                                sync.lyricsStatus = "Lyrics Cleared!"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sync.lyricsStatus = "" }
                            })

                            // Media Sync Button
                            Button(action: {
                                if sync.isSyncingMedia {
                                    sync.stopMediaSync()
                                } else {
                                    sync.startMediaSync()
                                }
                            }) {
                                HStack {
                                    Image(systemName: "icloud.and.arrow.down.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(sync.isSyncingMedia ? .red : labelCol)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sync.isSyncingMedia ? "Downloading..." : "Download All Music")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(isDark ? .white : .black)
                                        Text((sync.isSyncingMedia || sync.mediaStatus.lowercased().contains("complete") || sync.mediaStatus.lowercased().contains("offline") || sync.mediaStatus.lowercased().contains("all")) ? sync.mediaStatus : "Save all tracks for offline listening")
                                            .font(.system(size: 12))
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                    
                                    if sync.isSyncingMedia {
                                        HStack(spacing: 8) {
                                            if !sync.mediaEta.isEmpty {
                                                Text(sync.mediaEta)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(.gray)
                                            }
                                            CircularProgressView(progress: sync.mediaProgress, size: 24, strokeWidth: 3, accentColor: .red)
                                        }
                                    } else if sync.mediaStatus.lowercased().contains("offline") || sync.mediaStatus.lowercased().contains("complete") || sync.mediaStatus.lowercased().contains("all") {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.green)
                                    } else {
                                        Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(.gray)
                                    }
                                }
                                .padding()
                                .background(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                                .cornerRadius(16)
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderCol.opacity(0.3), lineWidth: 1))
                            }
                            .simultaneousGesture(LongPressGesture().onEnded { _ in
                                client.clearMediaCache()
                                sync.mediaStatus = "Music Cleared!"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sync.mediaStatus = "" }
                            })
                            
                            Button(action: {
                                client.clearCache()
                                cacheCleared = true
                                self.cacheSize = "0 MB"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    cacheCleared = false
                                }
                            }) {
                                HStack {
                                    Image(systemName: "trash.fill")
                                        .foregroundColor(.red)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Clear All App Data")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(isDark ? .white : .black)
                                        Text("Removes all downloaded tracks, images, and metadata")
                                            .font(.system(size: 12))
                                            .foregroundColor(.gray)
                                    }
                                    Spacer()
                                    if cacheCleared {
                                        Text("Cleared").font(.system(size: 14, weight: .bold)).foregroundColor(.green)
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    } else {
                                        Text(cacheSize).font(.system(size: 14)).foregroundColor(.gray)
                                    }
                                }
                                .padding()
                                .background(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                                .cornerRadius(16)
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderCol.opacity(0.3), lineWidth: 1))
                            }
                        }
                        
                        // Audio Engine
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Audio Engine")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(labelCol)
                                .textCase(.uppercase)
                                .padding(.leading, 4)
                            
                            VStack(spacing: 0) {
                                Toggle(isOn: $isCrossfadeEnabled) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Gapless Crossfade")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(isDark ? .white : .black)
                                        Text("Smoothly transition between tracks")
                                            .font(.system(size: 12))
                                            .foregroundColor(.gray)
                                    }
                                }
                                .tint(accentBg)
                                .padding()
                                
                                if isCrossfadeEnabled {
                                    Divider().background(borderCol.opacity(0.3)).padding(.horizontal)
                                    
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            Text("Crossfade Duration")
                                                .font(.system(size: 14))
                                                .foregroundColor(isDark ? .white.opacity(0.8) : .black.opacity(0.8))
                                            Spacer()
                                            Text("\(Int(crossfadeDuration))s")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(accentBg)
                                        }
                                        Slider(value: $crossfadeDuration, in: 2...12, step: 1)
                                            .accentColor(accentBg)
                                    }
                                    .padding()
                                }
                            }
                            .background(isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.03))
                            .cornerRadius(16)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderCol.opacity(0.3), lineWidth: 1))
                        }
                        
                        // Download Concurrency
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Download Concurrency")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(labelCol)
                                Spacer()
                                Text("\(downloadConcurrency) tracks")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(isDark ? .white : .black)
                            }
                            Slider(value: Binding(
                                get: { Double(downloadConcurrency) },
                                set: { downloadConcurrency = Int($0) }
                            ), in: 1...15, step: 1)
                            .accentColor(accentBg)
                            
                            Text("Higher values speed up downloads but may slow down your server or drain battery.")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        .padding()
                        .background(isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.03))
                        .cornerRadius(16)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderCol.opacity(0.3), lineWidth: 1))

                        // Danger Zone
                        VStack(alignment: .leading, spacing: 20) {
                            Button(action: {
                                showLogs = true
                            }) {
                                HStack {
                                    Image(systemName: "doc.text.magnifyingglass")
                                    Text("App Logs")
                                        .fontWeight(.semibold)
                                    Spacer()
                                }
                                .padding()
                                .frame(maxWidth: .infinity)
                                .frame(height: 60)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(16)
                            }
                            
                            Button(action: {
                                client.logout()
                            }) {
                                HStack {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                    Text("Log Out")
                                        .fontWeight(.semibold)
                                    Spacer()
                                }
                                .padding()
                                .frame(maxWidth: .infinity)
                                .frame(height: 60)
                                .background(Color.red.opacity(0.1))
                                .foregroundColor(.red)
                                .cornerRadius(16)
                            }
                        }
                    }
                    .frame(maxWidth: 480)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onAppear {
                let clientRef = client
                DispatchQueue.global(qos: .background).async {
                    let size = clientRef.getMediaCacheSize()
                    DispatchQueue.main.async {
                        self.cacheSize = size
                    }
                }
            }
        }
        .sheet(isPresented: $showLogs) {
            LogsView()
        }
    }
    
    private func reconnectWithCurrentMode() {
        guard !username.isEmpty else { return }
        let localUrl = serverUrl
        let finalUrl = (connectionMode == 1) ? onlineServerUrl : localUrl
        
        if let passData = KeychainHelper.shared.read(service: "velora-password", account: username),
           let savedPass = String(data: passData, encoding: .utf8) {
            client.configure(url: finalUrl, user: username, pass: savedPass)
            if connectionMode != 2 {
                client.fetchEverything()
            }
        }
    }
}

// MARK: - Storage Monitor Component
struct StorageInfoView: View {
    @ObservedObject private var integrity = IntegrityManager.shared
    @State private var storage: IntegrityManager.StorageInfo?
    let isDark: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Storage")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(hex: "#60a5fa"))
                .textCase(.uppercase)
                .padding(.leading, 4)
            
            if let info = storage {
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Available Space")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                            Text(info.availableGB)
                                .font(.system(size: ScreenTier.isSE ? 20 : 24, weight: .bold))
                                .foregroundColor(isDark ? .white : .black)
                        }
                        Spacer()
                        Image(systemName: "iphone")
                            .font(.system(size: 30))
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    
                    // Progress Bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                            let usedRatio = 1.0 - (Double(info.available) / Double(info.total))
                            Capsule()
                                .fill(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * CGFloat(usedRatio))
                        }
                    }
                    .frame(height: 8)
                    
                    HStack {
                        Text("Velora Data: \(info.usedByAppMB)")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                        Spacer()
                        let totalGB = info.total / 1_000_000_000
                        Text("\(totalGB) GB Total")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                }
                .padding()
                .background(isDark ? Color.white.opacity(0.03) : Color.white)
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.gray.opacity(0.1), lineWidth: 1))
            }
        }
        .onAppear {
            storage = integrity.getStorageInfo()
        }
    }
}
