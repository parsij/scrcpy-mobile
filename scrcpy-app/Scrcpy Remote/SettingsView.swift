//
//  SettingView.swift
//  Scrcpy Remote
//
//  Created by Ethan on 12/8/24.
//

import SwiftUI
import UniformTypeIdentifiers
import SafariServices

enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system = "System"
    case dark = "Dark"
    case light = "Light"

    var id: String { self.rawValue }
}

enum BackgroundActiveDuration: String, Codable, CaseIterable, Identifiable {
    case oneMinute = "1 minute"
    case fiveMinutes = "5 minutes"
    case tenMinutes = "10 minutes"
    case thirtyMinutes = "30 minutes"
    case oneHour = "1 hour"
    case always = "Always"

    var id: String { self.rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .tenMinutes: return 600
        case .thirtyMinutes: return 1800
        case .oneHour: return 3600
        case .always: return nil
        }
    }
}

class AppSettings: ObservableObject {
    @AppStorage("settings.appearance")
    var apperance: Appearance = .system {
        didSet {
            print("Current apperance:", apperance)
            applyTheme()
        }
    }
    
    @AppStorage("settings.background_active_duration")
    var backgroundActiveDuration: BackgroundActiveDuration = .fiveMinutes
    
    // Logging related settings
    @AppStorage("settings.logging.enabled")
    var loggingEnabled: Bool = false {
        didSet {
            // Only call AppLogManager when the value actually changes
            if loggingEnabled != AppLogManager.shared.isLoggingEnabled {
                AppLogManager.shared.toggleLogging(loggingEnabled)
            }
        }
    }

    init() {
        applyTheme()

        // Initialize logging settings, sync state without triggering didSet
        let savedLoggingEnabled = UserDefaults.standard.bool(forKey: "settings.logging.enabled")
        AppLogManager.shared.isLoggingEnabled = savedLoggingEnabled

        // Listen for system appearance change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChange),
            name: NSNotification.Name("UITraitCollectionDidChangeNotification"),
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleAppearanceChange() {
        // When system appearance changes, apply the theme if user has set it to system mode
        if apperance == .system {
            applyTheme()
        }
    }
    
    var apperanceMode: ColorScheme {
        switch apperance {
        case .dark:
            return .dark
        case .light:
            return .light
        case .system:
            var window: UIWindow?

            // First try iOS 14+ method to get the window
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                window = windowScene.windows.first
            }

            // If the above method is not available (iOS 13), try the old method
            if window == nil {
                window = UIApplication.shared.windows.first
            }

            if let window = window {
                return window.traitCollection.userInterfaceStyle == .dark ? .dark : .light
            }

            return .dark // Return dark as fallback only
        }
    }
    
    func applyTheme() {
        var window: UIWindow?

        // First try iOS 14+ method to get the window
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = windowScene.windows.first
        }

        // If the above method is not available (iOS 13), try the old method
        if window == nil {
            window = UIApplication.shared.windows.first
        }
        
        guard let window = window else {
            return
        }

        switch apperance {
        case .system:
            window.overrideUserInterfaceStyle = .unspecified
        case .light:
            window.overrideUserInterfaceStyle = .light
        case .dark:
            window.overrideUserInterfaceStyle = .dark
        }
    }
    
    @AppStorage("settings.socks_proxy.enable")
    var enableSocksProxy: Bool = false
    
    @AppStorage("settings.socks_proxy.address")
    var socksProxyAddress: String = ""
    
    @AppStorage("settings.socks_proxy.port")
    var socksProxyPort: String = ""
    
    @AppStorage("settings.socks_proxy.auth.enable")
    var enableSocksAuth: Bool = false
    
    @AppStorage("settings.socks_proxy.auth.username")
    var socksAuthUsername: String = ""
    
    @AppStorage("settings.socks_proxy.auth.password")
    var socksAuthPassword: String = ""
    
    @AppStorage("settings.tailscale.hostname")
    var tailscaleHostname: String = "ScrcpyRemote_iOS"

    @AppStorage("settings.tailscale.auth_key")
    var tailscaleAuthKey: String = ""

    // OAuth settings for generating auth keys
    @AppStorage("settings.tailscale.oauth_client_id")
    var tailscaleOAuthClientID: String = ""

    @AppStorage("settings.tailscale.oauth_client_secret")
    var tailscaleOAuthClientSecret: String = ""

    @AppStorage("settings.tailscale.oauth_tag")
    var tailscaleOAuthTag: String = "tag:scrcpy-remote"

    // Track if auth key was generated via OAuth (for display purposes)
    @AppStorage("settings.tailscale.auth_key_generated_via_oauth")
    var tailscaleAuthKeyGeneratedViaOAuth: Bool = false

    @AppStorage("settings.tailscale.auth_key_expires_at")
    var tailscaleAuthKeyExpiresAt: String = ""
    
    @AppStorage("settings.live_activity.enabled")
    var liveActivityEnabled: Bool = true

    // Auto reconnect setting
    @AppStorage("settings.auto_reconnect.enabled")
    var autoReconnectEnabled: Bool = false

    // Send Files Default Path setting
    @AppStorage("settings.send_files.default_path")
    var sendFilesDefaultPath: String = "/sdcard/Download"

    // New: ADB pairing history
    @AppStorage("settings.adb_pairing_history")
    var adbPairingHistory: String = ""

    // Pairing history item structure
    struct PairingHistoryItem: Codable, Identifiable {
        let id = UUID()
        let hostPort: String
        let timestamp: Date
        
        init(hostPort: String, timestamp: Date = Date()) {
            self.hostPort = hostPort
            self.timestamp = timestamp
        }
    }
    
    // Get pairing history array
    var pairingHistoryArray: [PairingHistoryItem] {
        if adbPairingHistory.isEmpty {
            return []
        }

        do {
            let data = Data(adbPairingHistory.utf8)
            let items = try JSONDecoder().decode([PairingHistoryItem].self, from: data)
            return items
        } catch {
            // If parsing fails, try to support old format (plain string array)
            let oldFormat = adbPairingHistory.components(separatedBy: ",").filter { !$0.isEmpty }
            return oldFormat.map { PairingHistoryItem(hostPort: $0) }
        }
    }

    // Add pairing history
    func addPairingHistory(_ hostPort: String) {
        var history = pairingHistoryArray
        // Remove existing same record
        history.removeAll { $0.hostPort == hostPort }
        // Add to the beginning
        history.insert(PairingHistoryItem(hostPort: hostPort), at: 0)
        // Limit history to 10 items
        if history.count > 10 {
            history = Array(history.prefix(10))
        }

        // Save as JSON format
        do {
            let data = try JSONEncoder().encode(history)
            adbPairingHistory = String(data: data, encoding: .utf8) ?? ""
        } catch {
            print("Failed to encode pairing history: \(error)")
        }
    }

    // Clear pairing history
    func clearPairingHistory() {
        adbPairingHistory = ""
    }
}

struct SettingsView: View {
    @State private var showingClearAllLogsAlert = false
    @State private var showingSafariController = false
    @State private var currentSafariURL: URL?
    @EnvironmentObject var appSettings: AppSettings
    @StateObject private var logManager = AppLogManager.shared
    @Environment(\.presentationMode) var presentationMode

    // Check if there are any ADB type sessions
    private var hasADBSessions: Bool {
        let sessions = SessionManager.shared.loadSessions()
        return sessions.contains { $0.deviceType == .adb }
    }
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("General")) {
                    NavigationLink(destination: AppearanceSettingsView()) {
                        Text("Appearance")
                    }

                    Picker("Background Active", selection: $appSettings.backgroundActiveDuration) {
                        ForEach(BackgroundActiveDuration.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }

                    Toggle(NSLocalizedString("Auto Reconnect When Foregrounded", comment: "Auto reconnect setting"), isOn: $appSettings.autoReconnectEnabled)

                    if #available(iOS 16.1, *) {
                        Toggle("Live Activity in Dynamic Island", isOn: $appSettings.liveActivityEnabled)
                        
                        #if DEBUG
                        NavigationLink(destination: LiveActivityDebugView()) {
                            HStack {
                                Text("Debug Live Activity")
                                Spacer()
                                Image(systemName: "ladybug")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                            }
                        }
                        #endif
                    }

                    NavigationLink(destination: AboutView()) {
                        Text("About Scrcpy Remote")
                    }
                }
                Section(header: Text("Networking")) {
                    // NavigationLink(destination: ProxySettingsView()) {
                    //    Text("Use Socks Proxy")
                    // }
                    NavigationLink(destination: TailscaleAuthSettingsView()) {
                        Text("Tailscale Auth Setting")
                    }
                }
                // Only show ADB management options when there are ADB type sessions
                if hasADBSessions {
                    Section(header: Text("ADB Managements")) {
                        NavigationLink(destination: ADBKeysManagementView()) {
                            Text("Manage ADB Keys")
                        }
                        NavigationLink(destination: ADBPairingView()) {
                            Text("Pair ADB with Pairing Code")
                        }
                        NavigationLink(destination: SendFilesSettingsView()) {
                            HStack {
                                Text("Send Files Default Path")
                                Spacer()
                                Text(appSettings.sendFilesDefaultPath)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                Section(header: Text("Application Logs")) {
                    Toggle("Enable Log Recording", isOn: $appSettings.loggingEnabled)
                    
                    NavigationLink(destination: LogsManagementView()) {
                        HStack {
                            Text("Logs Management")
                            Spacer()
                            if logManager.logFilesCount > 0 {
                                Text(String(
                                    format: NSLocalizedString("(%d files)", comment: "Number of log files"),
                                    logManager.logFilesCount
                                ))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Button(action: {
                        showingClearAllLogsAlert = true
                    }) {
                        Text("Clear All Logs")
                            .foregroundColor(.red)
                    }
                    .alert(isPresented: $showingClearAllLogsAlert) {
                        Alert(
                            title: Text("Clear All Logs"),
                            message: Text("This will permanently delete all log files. This action cannot be undone!"),
                            primaryButton: .destructive(Text("Clear All")) {
                                logManager.clearAllLogs()
                            },
                            secondaryButton: .cancel()
                        )
                    }
                    
                    if logManager.totalLogFilesSize > 0 {
                        HStack {
                            Text("Total logs size:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: logManager.totalLogFilesSize, countStyle: .file))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Section(header: Text("Request & Support")) {
                    Button(action: {
                        currentSafariURL = URL(string: "https://github.com/wsvn53/scrcpy-mobile/issues")
                        showingSafariController = true
                    }) {
                        HStack {
                            Text("Submit an Issue")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                        }
                    }
                    .foregroundColor(.blue)

                    Button(action: {
                        currentSafariURL = URL(string: "https://scrcpy-remote.github.io/")
                        showingSafariController = true
                    }) {
                        HStack {
                            Text("Usage Guide")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                        }
                    }
                    .foregroundColor(.blue)
                }
            }
            .navigationBarTitle("Settings", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
        }
        .sheet(isPresented: $showingSafariController) {
            if let url = currentSafariURL {
                SafariView(url: url)
            }
        }
        .onAppear {
            // Initialize log manager state
            appSettings.loggingEnabled = logManager.isLoggingEnabled
        }
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject var appSettings: AppSettings

    var body: some View {
        List {
            ForEach(Appearance.allCases) { mode in
                Button(action: {
                    appSettings.apperance = mode
                }) {
                    HStack {
                        Text(mode.rawValue)
                        if mode == appSettings.apperance {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .foregroundColor(.primary)
            }
        }
        .navigationBarTitle("Appearance", displayMode: .inline)
    }
}

struct ProxySettingsView: View {
    @EnvironmentObject var appSettings: AppSettings

    var body: some View {
        Form {
            Toggle("Enable Proxy", isOn: $appSettings.enableSocksProxy)
            TextField("SOCKS Proxy Host", text: $appSettings.socksProxyAddress)
                .textContentType(.URL)
            TextField("SOCKS Proxy Port", text: $appSettings.socksProxyPort)
                .keyboardType(.numberPad)
            Toggle("Enable SOCKS Authentication", isOn: $appSettings.enableSocksAuth)
            if $appSettings.enableSocksAuth.wrappedValue {
                TextField("User", text: $appSettings.socksAuthUsername)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled(true)
                SecureField("Password", text: $appSettings.socksAuthPassword)
                    .textContentType(.password)
            }
        }
        .navigationBarTitle("Socks Proxy", displayMode: .inline)
    }
}

struct TailscaleAuthSettingsView: View {
    @EnvironmentObject var appSettings: AppSettings
    @State private var isConnecting: Bool = false
    @State private var connectionResult: String = ""
    @State private var isConnected: Bool = false
    @State private var tailscaleIPv4: String = ""
    @State private var tailscaleIPv6: String = ""
    @State private var tailscaleMagicDNS: String = ""

    // OAuth states
    @State private var isGeneratingKey: Bool = false
    @State private var oauthResult: String = ""
    @State private var oauthSuccess: Bool = false
    @State private var showOAuthSection: Bool = false

    // Check if OAuth credentials are configured for auto-regeneration
    private var hasOAuthCredentials: Bool {
        !appSettings.tailscaleOAuthClientID.isEmpty &&
        !appSettings.tailscaleOAuthClientSecret.isEmpty &&
        !appSettings.tailscaleOAuthTag.isEmpty
    }

    var body: some View {
        Form {
            Section(header: Text("Tailscale Configuration")) {
                TextField("Hostname", text: $appSettings.tailscaleHostname)
                    .textContentType(.name)
                    .autocapitalization(.none)
                    .autocorrectionDisabled(true)

                VStack(alignment: .leading, spacing: 4) {
                    SecureField("Auth Key", text: $appSettings.tailscaleAuthKey)
                        .textContentType(.password)
                        .autocapitalization(.none)
                        .autocorrectionDisabled(true)

                    if appSettings.tailscaleAuthKeyGeneratedViaOAuth && !appSettings.tailscaleAuthKeyExpiresAt.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: "key.fill")
                                    .foregroundColor(.green)
                                    .font(.caption2)
                                Text("Generated via OAuth")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                                Text("• Expires: \(formatExpiryDate(appSettings.tailscaleAuthKeyExpiresAt))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            if hasOAuthCredentials {
                                Text("Will auto-regenerate when connecting")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .italic()
                            }
                        }
                    }
                }
            }

            Section(header: Text("Manual Auth Key")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste an auth key from Tailscale admin console:")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("1. Visit https://login.tailscale.com/admin/settings/keys")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .textSelection(.enabled)

                    Text("2. Create a new Auth Key")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("3. Copy the key and paste it in the Auth Key field above")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            // Generate Auth Key via OAuth Section
            Section(header: HStack {
                Text("Generate Auth Key via OAuth")
                Spacer()
                Button(action: { withAnimation { showOAuthSection.toggle() } }) {
                    Image(systemName: showOAuthSection ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
            }) {
                if showOAuthSection {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OAuth Client ID")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Client ID", text: $appSettings.tailscaleOAuthClientID)
                                .textContentType(.username)
                                .autocapitalization(.none)
                                .autocorrectionDisabled(true)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("OAuth Client Secret")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            SecureField("Client Secret", text: $appSettings.tailscaleOAuthClientSecret)
                                .textContentType(.password)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Device Tag (required for OAuth)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("tag:your-tag", text: $appSettings.tailscaleOAuthTag)
                                .autocapitalization(.none)
                                .autocorrectionDisabled(true)
                        }

                        Button(action: {
                            generateAuthKeyViaOAuth()
                        }) {
                            HStack {
                                if isGeneratingKey {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "key.viewfinder")
                                }
                                Text(isGeneratingKey ? "Generating..." : "Generate Auth Key")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isGeneratingKey ||
                                  appSettings.tailscaleOAuthClientID.isEmpty ||
                                  appSettings.tailscaleOAuthClientSecret.isEmpty ||
                                  appSettings.tailscaleOAuthTag.isEmpty)

                        if !oauthResult.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: oauthSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(oauthSuccess ? .green : .red)
                                Text(oauthResult)
                                    .font(.caption)
                                    .foregroundColor(oauthSuccess ? .green : .red)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Benefits of OAuth-generated keys:")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("• Can be automatically regenerated (up to 90 days each)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("• More secure than long-lived manual keys")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("• OAuth credentials can generate unlimited keys")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)

                    // How to setup OAuth - now inside the OAuth section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How to create an OAuth client:")
                            .font(.caption)
                            .fontWeight(.medium)

                        Text("Step 1: Create a Tag")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)

                        Text("Visit https://login.tailscale.com/admin/acls/visual/tags")
                            .font(.caption2)
                            .foregroundColor(.blue)
                            .textSelection(.enabled)

                        Text("Click 'Add Tag' and enter a name like 'scrcpy-remote'")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Text("Step 2: Create OAuth Client")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .padding(.top, 4)

                        Text("Visit https://login.tailscale.com/admin/settings/trust-credentials")
                            .font(.caption2)
                            .foregroundColor(.blue)
                            .textSelection(.enabled)

                        Text("Click 'Credential' -> 'OAuth'")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Text("Select 'auth_keys' scope with Write permission")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Text("Select the tag you created (e.g., 'tag:scrcpy-remote')")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Text("Click 'Generate credential' and copy the Client ID and Secret")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button(action: { withAnimation { showOAuthSection = true } }) {
                        HStack {
                            Image(systemName: "key.viewfinder")
                            Text("Configure OAuth to generate auth keys automatically")
                                .font(.subheadline)
                        }
                    }
                }
            }

            Section {
                Button(action: {
                    connectAndTestTailscale()
                }) {
                    HStack {
                        if isConnecting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.8)
                        }
                        Text(isConnecting ? "Connecting..." : "Connect & Test Tailscale")
                    }
                }
                .disabled(isConnecting || appSettings.tailscaleAuthKey.isEmpty)

                if isConnected || !connectionResult.isEmpty {
                    Button(action: {
                        cleanupTailscale()
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Disconnect & Cleanup")
                        }
                    }
                    .foregroundColor(.red)

                    Button(action: {
                        clearPersistentState()
                    }) {
                        HStack {
                            Image(systemName: "trash.fill")
                            Text("Clear Persistent State")
                        }
                    }
                    .foregroundColor(.orange)
                }
            }

            if !connectionResult.isEmpty {
                Section(header: Text("Connection Status")) {
                    if isConnected {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Connected Successfully")
                                    .fontWeight(.medium)
                                    .foregroundColor(.green)
                            }

                            if !tailscaleIPv4.isEmpty || !tailscaleIPv6.isEmpty || !tailscaleMagicDNS.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Network Addresses")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Spacer()
                                        Text("Long press to copy")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    if !tailscaleIPv4.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Tailscale IPv4:")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                                .foregroundColor(.secondary)
                                            Text(tailscaleIPv4)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundColor(.blue)
                                                .textSelection(.enabled)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color(.systemGray6))
                                                .cornerRadius(6)
                                        }
                                    }

                                    if !tailscaleIPv6.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Tailscale IPv6:")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                                .foregroundColor(.secondary)
                                            Text(tailscaleIPv6)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundColor(.blue)
                                                .textSelection(.enabled)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color(.systemGray6))
                                                .cornerRadius(6)
                                        }
                                    }

                                    if !tailscaleMagicDNS.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("MagicDNS:")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                                .foregroundColor(.secondary)
                                            Text(tailscaleMagicDNS)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundColor(.purple)
                                                .textSelection(.enabled)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color(.systemGray6))
                                                .cornerRadius(6)
                                        }
                                    }
                                }
                            }

                            Text(connectionResult)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("Connection Failed")
                                    .fontWeight(.medium)
                                    .foregroundColor(.red)
                            }

                            Text(connectionResult)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationBarTitle("Tailscale Auth", displayMode: .inline)
        .onAppear {
            checkCurrentStatus()
        }
        .onDisappear {
            // Do not cleanup on disappear
            // TailscaleManager will close connections automatically if not active
        }
    }

    private func formatExpiryDate(_ isoDate: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }

        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }

        return isoDate
    }

    private func generateAuthKeyViaOAuth() {
        guard !appSettings.tailscaleOAuthClientID.isEmpty,
              !appSettings.tailscaleOAuthClientSecret.isEmpty,
              !appSettings.tailscaleOAuthTag.isEmpty else {
            oauthResult = "Please fill in all OAuth fields"
            oauthSuccess = false
            return
        }

        isGeneratingKey = true
        oauthResult = ""
        oauthSuccess = false

        DispatchQueue.global(qos: .userInitiated).async {
            let manager = TailscaleManager.shared

            print("[OAuth] Setting credentials...")
            guard manager.setOAuthCredentials(
                clientID: self.appSettings.tailscaleOAuthClientID,
                clientSecret: self.appSettings.tailscaleOAuthClientSecret
            ) else {
                DispatchQueue.main.async {
                    self.isGeneratingKey = false
                    self.oauthResult = "Failed to set OAuth credentials"
                    self.oauthSuccess = false
                }
                return
            }

            print("[OAuth] Creating auth key with tag: \(self.appSettings.tailscaleOAuthTag)")
            manager.resetOAuthStatus()

            guard manager.createAuthKeyViaOAuth(
                tags: [self.appSettings.tailscaleOAuthTag],
                reusable: true,
                ephemeral: false,
                preauthorized: true,
                expirySeconds: 0, // Use default (90 days max)
                description: "Generated by Scrcpy Remote"
            ) else {
                DispatchQueue.main.async {
                    self.isGeneratingKey = false
                    self.oauthResult = "Failed to initiate auth key creation"
                    self.oauthSuccess = false
                }
                return
            }

            // Poll for result
            let timeoutSeconds = 30
            var elapsed = 0

            while elapsed < timeoutSeconds {
                let status = manager.getOAuthStatus()

                if status == 1 {
                    // Success
                    if let authKey = manager.getOAuthLastAuthKey() {
                        let expiresAt = manager.getOAuthLastExpiresAt() ?? ""
                        DispatchQueue.main.async {
                            self.isGeneratingKey = false
                            self.appSettings.tailscaleAuthKey = authKey
                            self.appSettings.tailscaleAuthKeyGeneratedViaOAuth = true
                            self.appSettings.tailscaleAuthKeyExpiresAt = expiresAt
                            self.oauthResult = "Auth key generated successfully!"
                            self.oauthSuccess = true
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.isGeneratingKey = false
                            self.oauthResult = "Key generated but could not be retrieved"
                            self.oauthSuccess = false
                        }
                    }
                    return
                } else if status == -1 {
                    // Error
                    let errorMsg = manager.getOAuthLastError() ?? "Unknown error"
                    DispatchQueue.main.async {
                        self.isGeneratingKey = false
                        self.oauthResult = "Failed: \(errorMsg)"
                        self.oauthSuccess = false
                    }
                    return
                }

                Thread.sleep(forTimeInterval: 0.5)
                elapsed += 1
            }

            // Timeout
            DispatchQueue.main.async {
                self.isGeneratingKey = false
                self.oauthResult = "Timeout waiting for auth key generation"
                self.oauthSuccess = false
            }
        }
    }

    private func checkCurrentStatus() {
        let manager = TailscaleManager.shared

        if manager.isConnected() {
            isConnected = true

            // Get current IPs and MagicDNS separately
            tailscaleIPv4 = manager.getLastIPv4() ?? ""
            tailscaleIPv6 = manager.getLastIPv6() ?? ""
            tailscaleMagicDNS = manager.getLastMagicDNS() ?? ""

            // Get detailed connection info
            if let info = manager.getConnectionInfo() {
                connectionResult = "Already connected to Tailscale network!\n\(info)"
            } else {
                connectionResult = "Already connected to Tailscale network!"
            }
        } else if manager.hasPersistentState() {
            // Show that persistent state exists but not currently connected
            connectionResult = "Persistent Tailscale state found at: \(manager.getStateDirectoryPath())\nTap 'Connect & Test Tailscale' to restore connection."
        }
    }
    
    private func cleanupTailscale() {
        DispatchQueue.global(qos: .userInitiated).async {
            let cleanedCount = TailscaleManager.shared.cleanup()
            
            DispatchQueue.main.async {
                self.isConnected = false
                self.connectionResult = "Cleaned up \(cleanedCount) connections. Tailscale disconnected."
                self.tailscaleIPv4 = ""
                self.tailscaleIPv6 = ""
                self.tailscaleMagicDNS = ""
            }
        }
    }
    
    private func clearPersistentState() {
        DispatchQueue.global(qos: .userInitiated).async {
            let manager = TailscaleManager.shared

            // First cleanup any active connections
            let cleanedCount = manager.cleanup()

            // Then clear persistent state
            let success = manager.clearPersistentState()
            
            DispatchQueue.main.async {
                self.isConnected = false
                self.tailscaleIPv4 = ""
                self.tailscaleIPv6 = ""
                self.tailscaleMagicDNS = ""
                
                if success {
                    self.connectionResult = "Persistent state cleared successfully. Cleaned up \(cleanedCount) connections."
                } else {
                    self.connectionResult = "Failed to clear persistent state. Cleaned up \(cleanedCount) connections."
                }
            }
        }
    }
    
    private func connectAndTestTailscale() {
        guard !appSettings.tailscaleAuthKey.isEmpty else {
            return
        }
        
        isConnecting = true
        connectionResult = ""
        isConnected = false
        tailscaleIPv4 = ""
        tailscaleIPv6 = ""
        tailscaleMagicDNS = ""
        
        // Execute Tailscale connection in background queue
        DispatchQueue.global(qos: .userInitiated).async {
            let manager = TailscaleManager.shared
            
            print("[Tailscale] Starting connection test...")
            print("[Tailscale] Auth Key: \(self.appSettings.tailscaleAuthKey.prefix(10))...")
            print("[Tailscale] Hostname: \(self.appSettings.tailscaleHostname)")
            
            // Step 1: Set authentication key
            print("[Tailscale] Setting authentication key...")
            guard manager.setAuthKey(self.appSettings.tailscaleAuthKey) else {
                print("[Tailscale] ERROR: Failed to set authentication key")
                DispatchQueue.main.async {
                    self.isConnecting = false
                    self.isConnected = false
                    self.connectionResult = "Failed to set authentication key. Please check if the key format is correct."
                }
                return
            }
            print("[Tailscale] Authentication key set successfully")
            
            // Step 2: Set hostname
            print("[Tailscale] Setting hostname...")
            guard manager.setHostname(self.appSettings.tailscaleHostname) else {
                print("[Tailscale] ERROR: Failed to set hostname")
                DispatchQueue.main.async {
                    self.isConnecting = false
                    self.isConnected = false
                    self.connectionResult = "Failed to set hostname '\(self.appSettings.tailscaleHostname)'. Please check the hostname format."
                }
                return
            }
            print("[Tailscale] Hostname set successfully")
            
            // Step 3: Set state directory (use persistent directory in Library)
            print("[Tailscale] Setting up persistent state directory...")
            guard manager.setupPersistentStateDirectory() else {
                print("[Tailscale] ERROR: Failed to setup persistent state directory")
                DispatchQueue.main.async {
                    self.isConnecting = false
                    self.isConnected = false
                    self.connectionResult = "Failed to setup persistent state directory. Check app permissions."
                }
                return
            }
            print("[Tailscale] Persistent state directory set successfully: \(manager.getStateDirectoryPath())")
            
            // Step 4: Show current configuration
            let config = manager.getCurrentConfig()
            print("[Tailscale] Current config - Hostname: \(config.hostname ?? "N/A"), StateDir: \(config.stateDir ?? "N/A")")

            // Step 5: Start async connection
            print("[Tailscale] Starting async connection...")
            manager.connectAsync()

            // Step 6: Wait for connection with timeout
            let timeoutSeconds = 60
            var elapsed = 0
            
            print("[Tailscale] Waiting for connection (timeout: \(timeoutSeconds)s)...")
            
            while elapsed < timeoutSeconds {
                let status = manager.getConnectionStatus()
                
                if elapsed % 10 == 0 {
                    print("[Tailscale] Status check at \(elapsed)s: \(status)")
                }
                
                if status == 1 {
                    // Connection successful
                    print("[Tailscale] Connection successful!")
                    DispatchQueue.main.async {
                        self.isConnecting = false
                        self.isConnected = true

                        // Get connection information
                        let ipv4 = manager.getLastIPv4()
                        let ipv6 = manager.getLastIPv6()
                        let hostname = manager.getLastHostname()
                        let magicDNS = manager.getLastMagicDNS()

                        print("[Tailscale] Connection info - IPv4: \(ipv4 ?? "N/A"), IPv6: \(ipv6 ?? "N/A")")
                        print("[Tailscale] Hostname: \(hostname ?? "N/A"), MagicDNS: \(magicDNS ?? "N/A")")

                        // Store connection information
                        self.tailscaleIPv4 = ipv4 ?? ""
                        self.tailscaleIPv6 = ipv6 ?? ""
                        self.tailscaleMagicDNS = magicDNS ?? ""
                        
                        var resultComponents: [String] = []
                        resultComponents.append("Successfully connected to Tailscale network!")
                        
                        if let hostname = hostname, !hostname.isEmpty {
                            resultComponents.append("Hostname: \(hostname)")
                        }
                        
                        if let magicDNS = magicDNS, !magicDNS.isEmpty {
                            resultComponents.append("MagicDNS: \(magicDNS)")
                        }
                        
                        if manager.isStarted() {
                            resultComponents.append("TSNet server is running")
                            print("[Tailscale] TSNet server is confirmed running")
                            
                            if let allIPs = manager.getTailscaleIPs(), !allIPs.isEmpty {
                                resultComponents.append("Available IPs: \(allIPs)")
                                print("[Tailscale] All available IPs: \(allIPs)")
                            }
                        } else {
                            print("[Tailscale] WARNING: TSNet server is not running")
                        }
                        
                        self.connectionResult = resultComponents.joined(separator: "\n")
                    }
                    return

                } else if status == -1 {
                    // Connection failed
                    print("[Tailscale] Connection failed!")
                    DispatchQueue.main.async {
                        self.isConnecting = false
                        self.isConnected = false

                        let errorMessage = manager.getLastError() ?? "Unknown error"
                        print("[Tailscale] Error message: \(errorMessage)")
                        self.connectionResult = "Connection failed: \(errorMessage)\n\nTroubleshooting:\n• Check if Auth Key is valid and not expired\n• Ensure network connectivity\n• Verify Tailscale account permissions"
                    }
                    return
                }

                // Still connecting, wait a bit more
                Thread.sleep(forTimeInterval: 1.0)
                elapsed += 1
            }

            // Timeout reached
            print("[Tailscale] Connection timeout after \(timeoutSeconds) seconds")
            DispatchQueue.main.async {
                self.isConnecting = false
                self.isConnected = false
                self.connectionResult = "Connection timeout after \(timeoutSeconds) seconds.\n\nPossible causes:\n• Auth Key is invalid or expired\n• Network connectivity issues\n• Tailscale service unavailable\n• Firewall blocking connection\n\nPlease check your Auth Key and network connection."
            }
        }
    }
}

struct AboutView: View {
    @State private var appVersion: String = "Unknown"
    @State private var scrcpyVersion: String = "Unknown"
    @State private var showingSafariController = false
    @State private var currentSafariURL: URL?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .center, spacing: 8) {
                    Text("Scrcpy Remote v\(appVersion)")
                        .font(.title3)
                        .bold()
                    Text("Based on Scrcpy \(scrcpyVersion)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 15)
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Scrcpy Remote is a remote desktop tool based on VNC/ADB protocols, typically used for connecting to services with public IP addresses or services within the same local network.")
                        .font(.body)
                    
                    Text("If you cannot connect to your service normally, please first check whether the network connection is working properly.")
                        .font(.body)
                        .foregroundColor(.orange)
                    
                    Text("Additionally, this app has built-in Tailscale tsnet module, which allows you to establish a virtual network between the app and your target service through Tailscale, then connect to it.")
                        .font(.body)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("For detailed usage help, please check:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        // Button for Tailscale README
                        Button(action: {
                            currentSafariURL = URL(string: "https://github.com/wsvn53/scrcpy-mobile/blob/main/Tailscale_README.md")
                            showingSafariController = true
                        }) {
                            HStack {
                                Text("→ Tailscale Usage Guide")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("VNC Client Implementation:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("This app uses LibVNCClient, a cross-platform C library that provides VNC client functionality. LibVNCClient is part of the LibVNCServer/LibVNCClient project, which is free software licensed under the GPL.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Button(action: {
                            currentSafariURL = URL(string: "https://libvnc.github.io/")
                            showingSafariController = true
                        }) {
                            HStack {
                                Text("→ LibVNCClient Documentation")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    Text("If you encounter problems and need help while using, you can also join our Telegram Channel.")
                        .font(.body)
                    
                    // Button for Telegram Channel
                    Button(action: {
                        currentSafariURL = URL(string: "https://telegram.org")
                        showingSafariController = true
                    }) {
                        HStack {
                            Text("→ Join Our Telegram Channel")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                        }
                    }
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .sheet(isPresented: $showingSafariController) {
            if let url = currentSafariURL {
                SafariView(url: url)
            }
        }
        .navigationBarTitle("About Scrcpy Remote", displayMode: .inline)
        .onAppear {
            loadVersionInfo()
        }
    }
    
    private func loadVersionInfo() {
        // Get app version from bundle
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            appVersion = version
        }
        
        // Get Scrcpy core version
        let coreVersionCString = ScrcpyCoreVersion()
        if let coreVersionCString = coreVersionCString {
            scrcpyVersion = String(cString: coreVersionCString)
        }
    }
}

struct LogsManagementView: View {
    @StateObject private var logManager = AppLogManager.shared
    @State private var logFiles: [LogFileInfo] = []
    @State private var showingDeleteAlert = false
    @State private var selectedLogFile: LogFileInfo?
    @State private var showingClearOldLogsAlert = false
    
    var body: some View {
        List {
            Section(header: Text("Log Files Statistics")) {
                HStack {
                    Text("Total files:")
                    Spacer()
                    Text("\(logManager.logFilesCount)")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Total size:")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: logManager.totalLogFilesSize, countStyle: .file))
                        .foregroundColor(.secondary)
                }
                
                if logManager.currentLogFileSize > 0 {
                    HStack {
                        Text("Current log size:")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: logManager.currentLogFileSize, countStyle: .file))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Section(header: Text("Quick Actions")) {
                Button(action: {
                    showingClearOldLogsAlert = true
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear Old Logs")
                        Spacer()
                        Text("Keep Current Only")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .foregroundColor(.orange)
                .alert(isPresented: $showingClearOldLogsAlert) {
                    Alert(
                        title: Text("Clear Old Logs"),
                        message: Text("This will delete all log files except the current one. Are you sure?"),
                        primaryButton: .destructive(Text("Clear Old Logs")) {
                            logManager.clearOldLogs()
                            refreshLogFiles()
                        },
                        secondaryButton: .cancel()
                    )
                }
            }
            
            if !logFiles.isEmpty {
                Section(header: Text("Log Files")) {
                    ForEach(logFiles) { logFile in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(logFile.fileName)
                                        .font(.subheadline)
                                        .fontWeight(logFile.isCurrentLog ? .medium : .regular)
                                    
                                    Text(logFile.formattedDate)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                VStack(alignment: .trailing) {
                                    Text(logFile.formattedFileSize)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    if logFile.isCurrentLog {
                                        Text("Current")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue)
                                            .foregroundColor(.white)
                                            .cornerRadius(4)
                                    }
                                }
                            }
                            
                            HStack(spacing: 16) {
                                NavigationLink(destination: LogFileDetailView(logFile: logFile)) {
                                    Label("View", systemImage: "doc.text")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(PlainButtonStyle())
                                
                                Spacer()
                                
                                Button(action: {
                                    selectedLogFile = logFile
                                    showingDeleteAlert = true
                                }) {
                                    Label("Delete", systemImage: "trash")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.top, 4)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                Section {
                    VStack(alignment: .center, spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No log files found")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("Enable logging in settings to start recording logs")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }
        }
        .navigationBarTitle("Logs Management", displayMode: .inline)
        .navigationBarItems(trailing: Button("Refresh") {
            refreshLogFiles()
        })
        .onAppear {
            refreshLogFiles()
        }
        .alert(isPresented: $showingDeleteAlert) {
            Alert(
                title: Text("Delete Log File"),
                message: Text("Are you sure you want to delete \(selectedLogFile?.fileName ?? "this log file")?"),
                primaryButton: .destructive(Text("Delete")) {
                    if let logFile = selectedLogFile {
                        logManager.deleteLogFile(logFile.filePath)
                        refreshLogFiles()
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    private func refreshLogFiles() {
        logFiles = logManager.getLogFilesList()
    }
}

struct LogFileDetailView: View {
    let logFile: LogFileInfo
    @State private var logContent: String = "Loading..."
    @State private var isLoading: Bool = true
    @State private var showingShareSheet = false

    var body: some View {
        VStack {
            // File information
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("File:")
                        .fontWeight(.medium)
                    Spacer()
                    Text(logFile.fileName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Size:")
                        .fontWeight(.medium)
                    Spacer()
                    Text(logFile.formattedFileSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Last Modified:")
                        .fontWeight(.medium)
                    Spacer()
                    Text(logFile.formattedDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(8)
            .padding(.horizontal)

            // Log content or empty state
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                    Text("Loading log content...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if isLogContentEmpty {
                // Empty log file notice
                VStack(alignment: .center, spacing: 16) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    
                    VStack(spacing: 8) {
                        Text("Empty Log File")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text("This log file contains no content yet.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        if logFile.isCurrentLog {
                            Text("Start using the app to generate logs.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                // Log content
                ScrollView {
                    Text(logContent)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
                .background(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
                .padding(.horizontal)
            }
        }
        .navigationBarTitle("Log Detail", displayMode: .inline)
        .navigationBarItems(trailing:
            HStack(spacing: 16) {
                Button(action: {
                    showingShareSheet = true
                }) {
                    Image(systemName: "square.and.arrow.up")
                }
                
                Button(action: {
                    refreshContent()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        )
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(activityItems: [URL(fileURLWithPath: logFile.filePath)])
        }
        .onAppear {
            loadLogContent()
        }
    }

    // Check if log content is empty
    private var isLogContentEmpty: Bool {
        let trimmedContent = logContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedContent.isEmpty ||
               trimmedContent == "No log file found at: \(logFile.filePath)" ||
               trimmedContent == "Failed to read log file" ||
               trimmedContent.hasPrefix("Log file not found")
    }
    
    private func loadLogContent() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let content = AppLogManager.shared.readLogFile(logFile.filePath, lineCount: 2000)
            DispatchQueue.main.async {
                self.logContent = content
                self.isLoading = false
            }
        }
    }
    
    private func refreshContent() {
        loadLogContent()
    }
}

struct DetailedLogsView: View {
    @StateObject private var logManager = AppLogManager.shared
    @State private var logs: String = "Loading logs..."
    @State private var isLoading: Bool = true
    @State private var isAutoRefreshEnabled: Bool = false
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack {
            // Control bar
            HStack {
                Toggle("Auto Refresh", isOn: $isAutoRefreshEnabled)
                    .onChange(of: isAutoRefreshEnabled) { enabled in
                        if enabled {
                            startAutoRefresh()
                        } else {
                            stopAutoRefresh()
                        }
                    }
                
                Spacer()
                
                Button(action: {
                    loadLogs()
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                }
                .disabled(isLoading)
            }
            .padding()
            .background(Color(.systemGray6))

            // Log content
            ScrollView {
                Text(logs)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
            }
            .background(Color(.systemBackground))
        }
        .navigationBarTitle("Current Logs", displayMode: .inline)
        .navigationBarItems(trailing: 
            Button(action: {
                shareContent()
            }) {
                Image(systemName: "square.and.arrow.up")
            }
        )
        .onAppear {
            loadLogs()
        }
        .onDisappear {
            stopAutoRefresh()
        }
    }
    
    private func loadLogs() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let content = logManager.readLatestLogs(lineCount: 1000)
            DispatchQueue.main.async {
                self.logs = content.isEmpty ? "No logs available.\n\nTo see logs here:\n1. Enable 'Log Recording' in Settings\n2. Use the app to generate some activity\n3. Come back to view the logs" : content
                self.isLoading = false
            }
        }
    }
    
    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            if !isLoading {
                loadLogs()
            }
        }
    }
    
    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    private func shareContent() {
        let activityVC = UIActivityViewController(activityItems: [logs], applicationActivities: nil)

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootVC = window.rootViewController {

            // For iPad
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = window
                popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            
            rootVC.present(activityVC, animated: true)
        }
    }
}

struct ADBKeysManagementView: View {
    @State private var privateKey: String = ""
    @State private var publicKey: String = ""
    @State private var showPrivateKey: Bool = false
    @State private var isLoading: Bool = false
    @State private var statusMessage: String = ""
    @State private var statusIsError: Bool = false
    @State private var showingExportPicker: Bool = false
    @State private var showingImportPicker: Bool = false
    @State private var showingGenerateAlert: Bool = false

    let adbClient = ADBClient.shared()
    
    var body: some View {
        Form {
            Section(header: Text("ADB Keys Directory")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ADB Home:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text(adbClient.getADBHomeDirectory())
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.blue)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
            
            Section(header: Text("Private Key (adbkey)")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Content:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Spacer()
                        
                        Button(action: {
                            showPrivateKey.toggle()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: showPrivateKey ? "eye.slash" : "eye")
                                Text(showPrivateKey ? "Hide" : "Show")
                            }
                            .font(.caption)
                        }
                    }
                    
                    if showPrivateKey {
                        TextEditor(text: $privateKey)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 100)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                    } else {
                        Text("••••••••••••••••••••••••••••••••")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 12)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                    }
                }
            }
            
            Section(header: Text("Public Key (adbkey.pub)")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Content:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    TextEditor(text: $publicKey)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 80)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }
            }
            
            Section {
                Button(action: {
                    saveKeys()
                }) {
                    HStack {
                        Image(systemName: "checkmark.circle")
                        Text("Save Keys")
                    }
                }
                .disabled(isLoading)

                Button(action: {
                    showingImportPicker = true
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import Keys")
                    }
                }
                .disabled(isLoading)

                Button(action: {
                    showingExportPicker = true
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export Keys")
                    }
                }
                .disabled(isLoading || !adbClient.adbKeyPairExists())

                Button(action: {
                    showingGenerateAlert = true
                }) {
                    HStack {
                        Image(systemName: "key")
                        Text("Generate New Key Pair")
                    }
                }
                .disabled(isLoading)
            }
            
            if !statusMessage.isEmpty {
                Section(header: Text("Status")) {
                    HStack {
                        Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(statusIsError ? .red : .green)
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(statusIsError ? .red : .primary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationBarTitle("ADB Keys Management", displayMode: .inline)
        .onAppear {
            loadKeys()
        }
        .fileImporter(
            isPresented: $showingImportPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    importKeys(from: url)
                }
            case .failure(let error):
                setStatus("Import failed: \(error.localizedDescription)", isError: true)
            }
        }
        .fileExporter(
            isPresented: $showingExportPicker,
            document: ADBKeysDocument(),
            contentType: .folder,
            defaultFilename: "ADB_Keys"
        ) { result in
            switch result {
            case .success(let url):
                exportKeys(to: url)
            case .failure(let error):
                setStatus("Export failed: \(error.localizedDescription)", isError: true)
            }
        }
        .alert("⚠️ Generate New ADB Key Pair", isPresented: $showingGenerateAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Generate New Keys", role: .destructive) {
                generateNewKeys()
            }
        } message: {
            Text("This is a destructive operation!\n\n• Your current ADB keys will be permanently deleted\n• All devices previously authorized with your current keys will lose authorization\n• You will need to re-authorize all devices manually\n• This action cannot be undone\n\nAre you sure you want to generate new ADB keys?")
        }
    }
    
    private func loadKeys() {
        isLoading = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            let loadedPrivateKey = adbClient.readADBPrivateKey() ?? ""
            let loadedPublicKey = adbClient.readADBPublicKey() ?? ""
            
            DispatchQueue.main.async {
                self.privateKey = loadedPrivateKey
                self.publicKey = loadedPublicKey
                self.isLoading = false
                
                if loadedPrivateKey.isEmpty && loadedPublicKey.isEmpty {
                    self.setStatus("No ADB keys found. You may need to generate a new key pair.", isError: false)
                } else if loadedPrivateKey.isEmpty || loadedPublicKey.isEmpty {
                    self.setStatus("Incomplete key pair found. Some keys are missing.", isError: true)
                } else {
                    self.setStatus("ADB keys loaded successfully", isError: false)
                }
            }
        }
    }
    
    private func saveKeys() {
        guard !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatus("Both private and public keys must be provided", isError: true)
            return
        }
        
        isLoading = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            let privateSuccess = adbClient.writeADBPrivateKey(self.privateKey)
            let publicSuccess = adbClient.writeADBPublicKey(self.publicKey)
            
            DispatchQueue.main.async {
                self.isLoading = false
                
                if privateSuccess && publicSuccess {
                    self.setStatus("ADB keys saved successfully", isError: false)
                } else {
                    var errorMessage = "Failed to save keys:"
                    if !privateSuccess { errorMessage += " private key" }
                    if !publicSuccess { errorMessage += " public key" }
                    self.setStatus(errorMessage, isError: true)
                }
            }
        }
    }
    
    private func exportKeys(to url: URL) {
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let success = adbClient.exportADBKeys(toDirectory: url.path)

            DispatchQueue.main.async {
                self.isLoading = false

                if success {
                    self.setStatus("ADB keys exported successfully to \(url.lastPathComponent)", isError: false)
                } else {
                    self.setStatus("Failed to export ADB keys", isError: true)
                }
            }
        }
    }

    private func importKeys(from url: URL) {
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            // Start accessing security-scoped resource
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let success = adbClient.importADBKeys(fromDirectory: url.path)

            DispatchQueue.main.async {
                self.isLoading = false

                if success {
                    self.setStatus("ADB keys imported successfully from \(url.lastPathComponent)", isError: false)
                    // Reload the keys after import
                    self.loadKeys()
                } else {
                    self.setStatus("Failed to import ADB keys. Make sure the folder contains both 'adbkey' and 'adbkey.pub' files.", isError: true)
                }
            }
        }
    }

    private func generateNewKeys() {
        isLoading = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            let success = adbClient.generateNewADBKeyPair()
            
            DispatchQueue.main.async {
                self.isLoading = false
                
                if success {
                    self.setStatus("New ADB key pair generated successfully", isError: false)
                    // Reload the keys after generation
                    self.loadKeys()
                } else {
                    self.setStatus("Failed to generate new ADB key pair", isError: true)
                }
            }
        }
    }
    
    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
        
        // Auto-clear status after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if self.statusMessage == message {
                self.statusMessage = ""
            }
        }
    }
}

// Helper document type for file export
struct ADBKeysDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    
    init() {}
    
    init(configuration: ReadConfiguration) throws {}
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(directoryWithFileWrappers: [:])
    }
}

// MARK: - ADB Pairing View
struct ADBPairingView: View {
    @State private var adbPairHostPort: String = ""
    @State private var adbPairCode: String = ""
    @State private var isPairing: Bool = false
    @State private var pairResultMessage: String = ""
    @State private var pairResultIsError: Bool = false
    @State private var showingClearHistoryAlert: Bool = false
    @EnvironmentObject var appSettings: AppSettings
    
    var body: some View {
        Form {
            Section(header: Text("Instructions")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To pair your Android device for wireless ADB debugging:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text("1. Open Android Settings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("2. Go to Developer Options")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("3. Enable Wireless Debugging")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("4. Tap 'Pair device with pairing code'")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("5. Enter the Host:Port and Pairing Code below")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            // Pairing history
            if !appSettings.pairingHistoryArray.isEmpty {
                Section(header: Text("Recent Pairing History")) {
                    ForEach(appSettings.pairingHistoryArray) { item in
                        Button(action: {
                            adbPairHostPort = item.hostPort
                        }) {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.hostPort)
                                        .foregroundColor(.primary)
                                        .font(.subheadline)
                                    
                                    Text(formatPairingTime(item.timestamp))
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "arrow.up.left")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    Button(action: {
                        showingClearHistoryAlert = true
                    }) {
                        HStack {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                            Text("Clear History")
                                .foregroundColor(.red)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .alert("Clear Pairing History", isPresented: $showingClearHistoryAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Clear", role: .destructive) {
                        appSettings.clearPairingHistory()
                    }
                } message: {
                    Text("This will permanently delete all pairing history. This action cannot be undone.")
                }
            }
            
            Section(header: Text("Pairing Information")) {
                TextField("Host:Port (e.g., 192.168.1.100:12345)", text: $adbPairHostPort)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .textContentType(.URL)
                
                TextField("Pairing Code (6 digits)", text: $adbPairCode)
                    .keyboardType(.numberPad)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .textContentType(.oneTimeCode)
            }
            
            Section {
                Button(action: { pairADBDevice() }) {
                    HStack {
                        if isPairing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "link")
                        }
                        Text(isPairing ? "Pairing..." : "Pair Device")
                    }
                }
                .disabled(adbPairHostPort.trimmingCharacters(in: .whitespaces).isEmpty || 
                         adbPairCode.trimmingCharacters(in: .whitespaces).isEmpty || 
                         isPairing)
            }
            
            if !pairResultMessage.isEmpty {
                Section(header: Text("Result")) {
                    HStack {
                        Image(systemName: pairResultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(pairResultIsError ? .red : .green)
                        Text(pairResultMessage)
                            .font(.subheadline)
                            .foregroundColor(pairResultIsError ? .red : .green)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationBarTitle("Pair ADB Device", displayMode: .inline)
    }
    
    private func pairADBDevice() {
        guard !adbPairHostPort.trimmingCharacters(in: .whitespaces).isEmpty,
              !adbPairCode.trimmingCharacters(in: .whitespaces).isEmpty else {
            pairResultMessage = "Please enter both Host:Port and Pairing Code."
            pairResultIsError = true
            return
        }
        
        isPairing = true
        pairResultMessage = ""
        pairResultIsError = false

        // Call ADBClient to perform pairing
        let adbClient = ADBClient.shared()
        let hostPort = adbPairHostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = adbPairCode.trimmingCharacters(in: .whitespacesAndNewlines)

        adbClient.executeADBCommandAsync(["pair", hostPort, code]) { output, returnCode in
            DispatchQueue.main.async {
                isPairing = false

                if returnCode == 0, let output = output, output.lowercased().contains("success") {
                    pairResultMessage = "Pairing succeeded! You can now connect via ADB wireless."
                    pairResultIsError = false

                    // Add to pairing history
                    appSettings.addPairingHistory(hostPort)

                    // Clear input fields
                    adbPairHostPort = ""
                    adbPairCode = ""
                } else {
                    let errorMessage = output ?? "Unknown error"
                    pairResultMessage = "Pairing failed: \(errorMessage)"
                    pairResultIsError = true
                }
            }
        }
    }
    
    private func formatPairingTime(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

// MARK: - Quick Select Tags View
struct QuickSelectTagsView: View {
    @Binding var selectedPath: String

    private let row1 = ["/sdcard/Download", "/sdcard/DCIM", "/sdcard/Documents"]
    private let row2 = ["/sdcard/Pictures", "/sdcard/Music", "/sdcard/Movies"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(row1, id: \.self) { path in
                    PathTagButton(
                        path: path,
                        isSelected: selectedPath == path,
                        action: { selectedPath = path }
                    )
                }
            }
            HStack(spacing: 8) {
                ForEach(row2, id: \.self) { path in
                    PathTagButton(
                        path: path,
                        isSelected: selectedPath == path,
                        action: { selectedPath = path }
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct PathTagButton: View {
    let path: String
    let isSelected: Bool
    let action: () -> Void

    private var displayName: String {
        path.replacingOccurrences(of: "/sdcard/", with: "")
    }

    var body: some View {
        Button(action: action) {
            Text(displayName)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Send Files Settings View
struct SendFilesSettingsView: View {
    @EnvironmentObject var appSettings: AppSettings
    @State private var editingPath: String = ""
    @State private var showingResetAlert: Bool = false

    private let defaultPath = "/sdcard/Download"

    var body: some View {
        Form {
            Section(header: Text("Default Path")) {
                TextField("Remote path", text: $editingPath)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .textContentType(.URL)
            }

            Section(header: Text("Quick Select")) {
                QuickSelectTagsView(selectedPath: $editingPath)
            }

            Section {
                Button(action: {
                    showingResetAlert = true
                }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset to Default")
                    }
                }
                .foregroundColor(.orange)
            }

            Section(header: Text("Info")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Files sent via 'Send Files' action will be pushed to this path on the Android device.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("The path must be an absolute path starting with /sdcard/ or similar accessible directory.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationBarTitle("Send Files Path", displayMode: .inline)
        .onAppear {
            editingPath = appSettings.sendFilesDefaultPath
        }
        .onChange(of: editingPath) { newValue in
            appSettings.sendFilesDefaultPath = newValue
        }
        .alert("Reset to Default", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                editingPath = defaultPath
            }
        } message: {
            Text("This will reset the path to '\(defaultPath)'.")
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
}

// MARK: - SafariView
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let safariViewController = SFSafariViewController(url: url)
        safariViewController.preferredControlTintColor = UIColor.systemBlue
        return safariViewController
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // No update needed
    }
}

// MARK: - ShareSheet
struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // Nothing to do here
    }
}
