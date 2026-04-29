import SwiftUI

// 3-step wizard matching the web app exactly:
// Step 1: Server URL  →  Step 2: Username + Password  →  (Optional) Step 3: Display name
enum SettingsStep { case server, login, client }

struct SettingsView: View {
    @Binding var showSettings: Bool
    @EnvironmentObject var client: NavidromeClient
    @Environment(\.colorScheme) var colorScheme

    var isDark: Bool { colorScheme == .dark }

    @State private var step: SettingsStep = .server
    @State private var serverAddress: String = UserDefaults.standard.string(forKey: "velora_server_url") ?? "http://"
    @State private var username: String     = UserDefaults.standard.string(forKey: "velora_username") ?? ""
    @State private var password: String     = ""
    @State private var displayName: String  = UserDefaults.standard.string(forKey: "velora_display_name") ?? ""
    @State private var showPassword: Bool   = false
    @State private var status: ConnStatus  = .idle
    @State private var cacheCleared: Bool   = false
    @State private var cacheSize: String    = "Calculating..."
    @State private var downloadingAll: Bool = false

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
                case .client: clientStep
                }

                Spacer()
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            DispatchQueue.global(qos: .background).async {
                let size = client.getMediaCacheSize()
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
                placeholder: "http://192.168.1.6:4533",
                text: $serverAddress,
                isDark: isDark,
                borderCol: borderCol,
                labelCol: labelCol
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
                placeholder: "admin",
                text: $username,
                isDark: isDark,
                borderCol: borderCol,
                labelCol: labelCol
            )

            FloatingLabelField(
                label: "Password",
                placeholder: "password",
                text: $password,
                isDark: isDark,
                borderCol: borderCol,
                labelCol: labelCol,
                isSecure: !showPassword,
                trailingIcon: showPassword ? "eye.slash" : "eye",
                onTrailingTap: { showPassword.toggle() }
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
                        ProgressView().tint(accentFg)
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
    // STEP 3 — Personalization
    // ─────────────────────────────────────────────────────────────
    private var clientStep: some View {
        VStack(spacing: 0) {
            FloatingLabelField(
                label: "Greeting Name",
                placeholder: "e.g. Tony Stark",
                text: $displayName,
                isDark: isDark,
                borderCol: borderCol,
                labelCol: labelCol
            )

            Text("This changes how the system greets you on the home screen.")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#6b7280"))
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            Button(action: {
                UserDefaults.standard.set(displayName, forKey: "velora_display_name")
                withAnimation { step = .server }
            }) {
                Text("Done")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(accentBg)
                    .foregroundColor(accentFg)
                    .cornerRadius(100)
            }
            .padding(.top, 28)
        }
        .padding(.horizontal, 24)
        .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .move(edge: .bottom)).combined(with: .opacity))
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
    var trailingIcon: String? = nil
    var onTrailingTap: (() -> Void)? = nil

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
                } else {
                    TextField(placeholder, text: $text)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textContentType(.URL)
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
    @AppStorage("velora_server_url") private var serverUrl: String = ""
    @AppStorage("velora_username") private var username: String = ""
    @AppStorage("velora_display_name") private var displayName: String = ""
    @AppStorage("velora_is_online_mode") private var isOnlineMode: Bool = false
    @State private var cacheCleared = false
    @State private var cacheSize: String = "Calculating..."
    @State private var downloadingAll = false
    
    // Constants matching web app
    let accentBg   = Color(hex: "#a8c7fa")
    let accentFg   = Color(hex: "#0b1b32")
    let borderCol  = Color(hex: "#374151")
    let labelCol   = Color(hex: "#60a5fa")

    var isDark: Bool { colorScheme == .dark }

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
                        // Profile Section
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Account")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(labelCol)
                                .textCase(.uppercase)
                                .padding(.leading, 4)
                            
                            FloatingLabelField(
                                label: "Display Name",
                                placeholder: "Enter your name",
                                text: $displayName,
                                isDark: isDark,
                                borderCol: borderCol,
                                labelCol: labelCol
                            )
                            
                            Toggle(isOn: Binding(
                                get: { isOnlineMode },
                                set: { newValue in
                                    isOnlineMode = newValue
                                    reconnectWithCurrentMode()
                                }
                            )) {
                                VStack(alignment: .leading) {
                                    Text("Online Mode")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(isDark ? .white : .black)
                                    Text(isOnlineMode ? "Using remote server (zrok.io)" : "Using local server")
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(accentBg)
                            .padding()
                            .background(isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.03))
                            .cornerRadius(16)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderCol.opacity(0.3), lineWidth: 1))
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Server").font(.system(size: 12, weight: .medium)).foregroundColor(.gray)
                                Text(isOnlineMode ? "https://sopranosnavi.share.zrok.io" : serverUrl).font(.system(size: 14)).foregroundColor(isDark ? .white.opacity(0.6) : .black.opacity(0.6))
                                
                                Text("User").font(.system(size: 12, weight: .medium)).foregroundColor(.gray).padding(.top, 8)
                                Text(username).font(.system(size: 14)).foregroundColor(isDark ? .white.opacity(0.6) : .black.opacity(0.6))
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.03))
                            .cornerRadius(16)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderCol.opacity(0.3), lineWidth: 1))
                        }
                        
                        // Storage Section
                        VStack(alignment: .leading, spacing: 20) {
                            Text("App Data")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(labelCol)
                                .textCase(.uppercase)
                                .padding(.leading, 4)
                            
                            Button(action: {
                                downloadingAll = true
                                Task {
                                    // 1. Fetch Artist Media & Metadata
                                    for artist in client.artists {
                                        // Image fetchers (they have their own internal caching)
                                        FanartManager.shared.fetchBackdrop(for: artist.name, mbid: nil)
                                        FanartManager.shared.fetchArtistPortrait(for: artist.name, mbid: nil) { _ in }
                                        
                                        // Metadata fetch (MBID is preferred)
                                        MusicBrainzManager.shared.fetchAboutArtist(artistName: artist.name, mbid: nil)
                                        
                                        // Respect MusicBrainz 1 req/sec limit + avoid hitting Fanart too hard
                                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                                    }
                                    
                                    // 2. Fetch Album Metadata (Top 20 albums to avoid massive delay, or all if small)
                                    let albumsToFetch = client.albums.prefix(50) 
                                    for album in albumsToFetch {
                                        MusicBrainzManager.shared.fetchAboutAlbum(albumName: album.name, artistName: album.artist ?? "Unknown Artist", mbid: nil)
                                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                                    }

                                    DispatchQueue.main.async { 
                                        downloadingAll = false 
                                        // Update cache size after download
                                        DispatchQueue.global(qos: .background).async {
                                            let size = client.getMediaCacheSize()
                                            DispatchQueue.main.async { self.cacheSize = size }
                                        }
                                    }
                                }
                            }) {
                                HStack {
                                    Image(systemName: "icloud.and.arrow.down.fill")
                                    Text(downloadingAll ? "Downloading..." : "Download All Media & Metadata")
                                    Spacer()
                                    if downloadingAll {
                                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .gray))
                                    } else {
                                        Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(.gray)
                                    }
                                }
                                .padding()
                                .frame(height: 60)
                                .background(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                                .cornerRadius(16)
                                .foregroundColor(isDark ? .white : .black)
                            }
                            .disabled(downloadingAll)
                            
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
                                    Text("Clear Media Cache")
                                    Spacer()
                                    if cacheCleared {
                                        Text("Cleared").font(.system(size: 14, weight: .bold)).foregroundColor(.green)
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    } else {
                                        Text(cacheSize).font(.system(size: 14)).foregroundColor(.gray)
                                    }
                                }
                                .padding()
                                .frame(height: 60)
                                .background(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                                .cornerRadius(16)
                                .foregroundColor(isDark ? .white : .black)
                            }
                        }
                        
                        // Danger Zone
                        VStack(alignment: .leading, spacing: 20) {
                            Button(action: {
                                // Clear credentials and state
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
                DispatchQueue.global(qos: .background).async {
                    let size = client.getMediaCacheSize()
                    DispatchQueue.main.async {
                        self.cacheSize = size
                    }
                }
            }
        }
    }

    private func reconnectWithCurrentMode() {
        let localUrl = serverUrl.isEmpty ? "http://192.168.1.13:4533" : serverUrl
        let finalUrl = isOnlineMode ? "https://sopranosnavi.share.zrok.io" : localUrl
        let finalUser = username.isEmpty ? "tony" : username
        let finalPass = "u4vTyG7BcBxR-9-"
        
        client.configure(url: finalUrl, user: finalUser, pass: finalPass)
        client.fetchEverything()
    }
}
