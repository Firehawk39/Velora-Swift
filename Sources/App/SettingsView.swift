import SwiftUI

// 3-step wizard matching the web app exactly:
// Step 1: Server URL  →  Step 2: Username + Password  →  (Optional) Step 3: Display name
enum SettingsStep { case server, login }

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
    @State private var isCheckingServer: Bool = false
    @State private var serverError: String? = nil
    @State private var loginErrorMessage: String? = nil

    @State private var statusTimer: Timer? = nil
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
                Task { @MainActor in
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
            Button(action: checkServerEndpoint) {
                HStack(spacing: 8) {
                    if isCheckingServer {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: accentFg))
                        Text("Checking...")
                            .fontWeight(.semibold)
                    } else {
                        Image(systemName: "arrow.right")
                        Text("Next")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(isValidUrl(serverAddress) && !isCheckingServer ? accentBg : accentBg.opacity(0.5))
                .foregroundColor(accentFg)
                .cornerRadius(100)
            }
            .disabled(!isValidUrl(serverAddress) || isCheckingServer)
            .padding(.top, 28)
            
            if let err = serverError {
                Text(err)
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.5)
                    .foregroundColor(Color(hex: "#f87171"))
                    .padding(.top, 10)
                    .textCase(.uppercase)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)).combined(with: .opacity))
    }
    
    private func checkServerEndpoint() {
        guard isValidUrl(serverAddress) else { return }
        let cleanUrl = serverAddress.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: cleanUrl + "/rest/ping.view?u=dummy&p=dummy&v=1.16.1&c=velora&f=json") else {
            serverError = "Invalid URL format."
            return
        }
        
        withAnimation {
            isCheckingServer = true
            serverError = nil
        }
        
        Task {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 8.0
                let (data, _) = try await URLSession.shared.data(for: req)
                
                let responseString = String(data: data, encoding: .utf8) ?? ""
                if responseString.contains("subsonic-response") {
                    withAnimation {
                        isCheckingServer = false
                        step = .login
                    }
                } else {
                    withAnimation {
                        isCheckingServer = false
                        serverError = "URL is reachable, but it does not appear to be a valid Subsonic/Navidrome server."
                    }
                }
            } catch {
                withAnimation {
                    isCheckingServer = false
                    serverError = "Failed to reach server: \(error.localizedDescription)"
                }
            }
        }
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
                Text(loginErrorMessage ?? "Connection Failed. Check credentials.")
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
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty, !password.isEmpty else { return }
        
        // Explicitly dismiss keyboard to trigger iOS Password AutoFill save prompt
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        status = .connecting

        // 1. Configure the client temporarily to test
        client.configure(url: serverAddress, user: cleanUsername, pass: password)
        
        // 2. Perform actual verification with server
        client.ping { success, errorMessage in
            Task { @MainActor in
                if success {
                    status = .connected
                    
                    // 3. Persist configuration only on success
                    UserDefaults.standard.set(serverAddress, forKey: "velora_server_url")
                    UserDefaults.standard.set(cleanUsername, forKey: "velora_username")
                    
                    // 4. Securely save password in Keychain
                    if let passData = password.data(using: .utf8) {
                        KeychainHelper.shared.save(passData, service: "velora-password", account: cleanUsername)
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
                    loginErrorMessage = errorMessage
                    AppLogger.shared.log("Login failed: \(errorMessage ?? "Unknown error")", level: .error)
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
    @State private var showLogs: Bool = false
    @State private var showLogoutConfirmation: Bool = false
    // Hold-to-delete state
    @State private var holdProgress: CGFloat = 0.0
    @State private var isHolding: Bool = false
    @State private var holdTimer: Timer? = nil
    
    @State private var statusTimer: Timer? = nil

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
                                        Text((sync.isSyncingMetadata || sync.metadataStatus.lowercased().contains("complete") || sync.metadataStatus.lowercased().contains("already") || sync.metadataStatus.lowercased().contains("all")) ? sync.metadataStatus : "Artist bios, portraits, and album details")
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
                                    } else if sync.metadataStatus.lowercased().contains("complete") || sync.metadataStatus.lowercased().contains("already") || sync.metadataStatus.lowercased().contains("all") {
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
                                        Text((sync.isSyncingLyrics || sync.lyricsStatus.lowercased().contains("complete") || sync.lyricsStatus.lowercased().contains("already") || sync.lyricsStatus.lowercased().contains("all")) ? sync.lyricsStatus : "Cache time-synced lyrics for offline use")
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
                                    } else if sync.lyricsStatus.lowercased().contains("complete") || sync.lyricsStatus.lowercased().contains("already") || sync.lyricsStatus.lowercased().contains("all") {
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
                                        Text((sync.isSyncingMedia || sync.mediaStatus.lowercased().contains("complete") || sync.mediaStatus.lowercased().contains("already") || sync.mediaStatus.lowercased().contains("offline") || sync.mediaStatus.lowercased().contains("all")) ? sync.mediaStatus : "Save all tracks for offline listening")
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
                                    } else if sync.mediaStatus.lowercased().contains("complete") || sync.mediaStatus.lowercased().contains("already") || sync.mediaStatus.lowercased().contains("offline") || sync.mediaStatus.lowercased().contains("all") {
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
                            
                            // Repair Sync Issues Button
                            Button(action: {
                                if sync.isRepairing {
                                    sync.stopRepairSync()
                                } else {
                                    sync.startRepairSync()
                                }
                            }) {
                                HStack {
                                    Image(systemName: "wrench.and.screwdriver.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(sync.isRepairing ? .orange : labelCol)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sync.isRepairing ? "Repairing..." : "Repair Sync Issues")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(isDark ? .white : .black)
                                        Text((sync.isRepairing || sync.repairStatus.lowercased().contains("complete") || sync.repairStatus.lowercased().contains("healthy")) ? sync.repairStatus : "Scan and fix missing or corrupted artwork and lyrics")
                                            .font(.system(size: 12))
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                    
                                    if sync.isRepairing {
                                        HStack(spacing: 8) {
                                            CircularProgressView(progress: sync.repairProgress, size: 24, strokeWidth: 3, accentColor: .orange)
                                        }
                                    } else if sync.repairStatus.lowercased().contains("complete") || sync.repairStatus.lowercased().contains("healthy") {
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
                            

                            // Hold-to-delete button
                            HoldToDeleteButton(
                                label: "Clear All App Data",
                                subtitle: "Removes all downloaded tracks, images, and metadata",
                                isDark: isDark,
                                borderCol: borderCol,
                                cacheSize: cacheSize,
                                cacheCleared: cacheCleared
                            ) {
                                client.clearCache()
                                playback.downloadedTrackIds.removeAll()
                                cacheCleared = true
                                self.cacheSize = "0 MB"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    cacheCleared = false
                                }
                            }
                        }

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
                                showLogoutConfirmation = true
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
                            .alert("Sign Out", isPresented: $showLogoutConfirmation) {
                                Button("Cancel", role: .cancel) {}
                                Button("Sign Out", role: .destructive) {
                                    client.logout()
                                }
                            } message: {
                                Text("Are you sure you want to sign out? Your downloaded data will be preserved but you'll need to log in again.")
                            }
                        }
                    }
                    .frame(maxWidth: 480)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .refreshable {
                let size = client.getMediaCacheSize()
                await MainActor.run {
                    self.cacheSize = size
                }
            }
            .onAppear {
                let clientRef = client
                DispatchQueue.global(qos: .background).async {
                    let size = clientRef.getMediaCacheSize()
                    Task { @MainActor in
                        self.cacheSize = size
                    }
                }
            }
            .onDisappear {
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

// MARK: - Custom Swipeable Row
struct SwipeableSyncRow<Content: View>: View {
    let deleteText: String
    let action: () -> Void
    let content: Content
    
    @State private var offset: CGFloat = 0
    @State private var isSwiped: Bool = false
    
    init(deleteText: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.deleteText = deleteText
        self.action = action
        self.content = content()
    }
    
    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete Background Layer
            HStack {
                Spacer()
                Button(action: {
                    withAnimation(.spring()) {
                        offset = 0
                        isSwiped = false
                    }
                    action()
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 16))
                        Text(deleteText)
                            .font(.system(size: 10, weight: .bold))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.white)
                    .frame(width: 80)
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
                    .cornerRadius(16)
                }
            }
            
            // Foreground Content Layer
            content
                .background(Color.clear)
                .offset(x: offset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if value.translation.width < 0 {
                                // Swiping left
                                offset = isSwiped ? value.translation.width - 80 : value.translation.width
                                // Cap the swipe to -80
                                if offset < -100 { offset = -100 }
                            } else if isSwiped && value.translation.width > 0 {
                                // Swiping right from open state
                                offset = value.translation.width - 80
                                if offset > 0 { offset = 0 }
                            }
                        }
                        .onEnded { value in
                            withAnimation(.spring()) {
                                if value.translation.width < -40 {
                                    offset = -80
                                    isSwiped = true
                                } else {
                                    offset = 0
                                    isSwiped = false
                                }
                            }
                        }
                )
        }
    }
}

// MARK: - Hold To Delete Button
/// Requires a 2-second press-and-hold before firing.
/// A red fill expands symmetrically from the center outward while held.
/// Releasing before completion snaps back with a spring animation.
struct HoldToDeleteButton: View {
    let label: String
    let subtitle: String
    let isDark: Bool
    let borderCol: Color
    let cacheSize: String
    let cacheCleared: Bool
    let action: () -> Void

    private let holdDuration: Double = 2.0

    @State private var progress: CGFloat = 0.0
    @State private var isHolding: Bool = false
    @State private var holdTimer: Timer? = nil
    @State private var holdStart: Date? = nil
    @State private var didFire: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .center) {
                // Base background
                RoundedRectangle(cornerRadius: 16)
                    .fill(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))

                // Red fill — grows from center outward (left + right simultaneously)
                if progress > 0 {
                    Rectangle()
                        .fill(Color.red.opacity(0.22 + 0.18 * progress))
                        .frame(width: geo.size.width * progress)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                // Border — sharpens to red as hold progresses
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        progress > 0
                            ? Color.red.opacity(0.3 + 0.7 * progress)
                            : borderCol.opacity(0.3),
                        lineWidth: progress > 0 ? 1.5 : 1
                    )

                // Content row
                HStack {
                    Image(systemName: cacheCleared ? "checkmark.circle.fill" : "trash.fill")
                        .foregroundColor(cacheCleared ? .green : .red)
                        .scaleEffect(1.0 + 0.12 * progress)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(
                                cacheCleared ? .green :
                                (progress > 0 ? .red : (isDark ? .white : .black))
                            )
                        Text(
                            progress > 0
                            ? "Release to cancel — \(String(format: "%.0f", ceil(holdDuration - progress * holdDuration)))s"
                            : subtitle
                        )
                        .font(.system(size: 12))
                        .foregroundColor(progress > 0 ? Color.red.opacity(0.85) : .gray)
                    }
                    Spacer()
                    if cacheCleared {
                        Text("Cleared")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.green)
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    } else {
                        Text(cacheSize)
                            .font(.system(size: 14))
                            .foregroundColor(progress > 0 ? .red : .gray)
                    }
                }
                .padding()
            }
        }
        .frame(height: 68)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isHolding, !didFire else { return }
                    isHolding = true
                    holdStart = Date()
                    // Drive progress at 60fps via a repeating timer
                    holdTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
                        Task { @MainActor in
                            guard let start = holdStart else { return }
                            let elapsed = Date().timeIntervalSince(start)
                            let p = CGFloat(min(elapsed / holdDuration, 1.0))
                            withAnimation(.linear(duration: 1.0 / 60.0)) {
                                progress = p
                            }
                            if p >= 1.0 {
                                cancelHold()
                                didFire = true
                                action()
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 400_000_000)
                                    withAnimation(.easeOut(duration: 0.4)) { progress = 0.0 }
                                    didFire = false
                                }
                            }
                        }
                    }
                }
                .onEnded { _ in
                    if !didFire { cancelHold() }
                }
        )
        // Haptic pulse at 1s and 2s; strong at fire
        .onChange(of: Int(progress * holdDuration)) { second in
            if second == 1 || second == 2 {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } else if second >= Int(holdDuration) {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdStart = nil
        isHolding = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
            progress = 0.0
        }
    }
}
