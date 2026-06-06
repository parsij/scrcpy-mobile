//
//  TailscaleManager.swift
//  Scrcpy Remote
//
//  Created by Ethan on 12/8/24.
//

import Foundation

// MARK: - Tailscale C Wrapper Functions
/// A manager class that provides Swift wrappers for Tailscale C library functions
/// This class handles Tailscale network connections, configuration, and status monitoring
class TailscaleManager {
    static let shared = TailscaleManager()
    
    // Connection state management
    private var connectionTimer: Timer?
    private var lastConnectionTime: Date?
    private let connectionKeepAliveSeconds: TimeInterval = 600 // 10 minutes
    
    // Port forwarding management
    private var activeForwards: [(remoteAddr: String, remotePort: Int, localPort: Int)] = []
    
    // Configuration state
    private var lastConfiguredAuthKey: String = ""
    private var lastConfiguredHostname: String = ""

    // Auto-regeneration state
    private var isRegeneratingKey: Bool = false

    private init() {}

    // MARK: - Auth Key Expiry Check

    /// Check if the current auth key has expired
    /// - Returns: true if the auth key has expired or will expire within 1 hour
    func isAuthKeyExpired() -> Bool {
        let expiresAtString = UserDefaults.standard.string(forKey: "settings.tailscale.auth_key_expires_at") ?? ""

        guard !expiresAtString.isEmpty else {
            // No expiry info, assume not expired (manual key)
            return false
        }

        // Parse ISO8601 date
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var expiryDate: Date?
        expiryDate = formatter.date(from: expiresAtString)

        // Try without fractional seconds
        if expiryDate == nil {
            formatter.formatOptions = [.withInternetDateTime]
            expiryDate = formatter.date(from: expiresAtString)
        }

        guard let expiry = expiryDate else {
            print("[TailscaleManager] Could not parse expiry date: \(expiresAtString)")
            return false
        }

        // Check if expired or will expire within 1 hour (buffer time)
        let bufferTime: TimeInterval = 3600 // 1 hour
        let isExpired = expiry.timeIntervalSinceNow < bufferTime

        if isExpired {
            print("[TailscaleManager] Auth key expired or expiring soon. Expiry: \(expiry), Now: \(Date())")
        }

        return isExpired
    }

    /// Check if OAuth credentials are configured for auto-regeneration
    /// - Returns: true if OAuth client ID, secret, and tag are all set
    func canAutoRegenerateAuthKey() -> Bool {
        let clientID = UserDefaults.standard.string(forKey: "settings.tailscale.oauth_client_id") ?? ""
        let clientSecret = UserDefaults.standard.string(forKey: "settings.tailscale.oauth_client_secret") ?? ""
        let tag = UserDefaults.standard.string(forKey: "settings.tailscale.oauth_tag") ?? ""

        return !clientID.isEmpty && !clientSecret.isEmpty && !tag.isEmpty
    }

    /// Auto-regenerate auth key using OAuth if expired
    /// - Parameter completion: Callback with success status and optional error message
    func autoRegenerateAuthKeyIfNeeded(completion: @escaping (Bool, String?) -> Void) {
        // Check if regeneration is needed
        guard isAuthKeyExpired() else {
            completion(true, nil)
            return
        }

        // Check if OAuth is configured
        guard canAutoRegenerateAuthKey() else {
            completion(false, "Auth key expired but OAuth not configured for auto-regeneration")
            return
        }

        // Prevent concurrent regeneration
        guard !isRegeneratingKey else {
            print("[TailscaleManager] Already regenerating auth key, waiting...")
            // Wait for existing regeneration
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.autoRegenerateAuthKeyIfNeeded(completion: completion)
            }
            return
        }

        isRegeneratingKey = true
        print("[TailscaleManager] Auth key expired, auto-regenerating via OAuth...")

        let clientID = UserDefaults.standard.string(forKey: "settings.tailscale.oauth_client_id") ?? ""
        let clientSecret = UserDefaults.standard.string(forKey: "settings.tailscale.oauth_client_secret") ?? ""
        let tag = UserDefaults.standard.string(forKey: "settings.tailscale.oauth_tag") ?? ""

        // Set OAuth credentials
        guard setOAuthCredentials(clientID: clientID, clientSecret: clientSecret) else {
            isRegeneratingKey = false
            completion(false, "Failed to set OAuth credentials")
            return
        }

        // Reset status and create new auth key
        resetOAuthStatus()

        guard createAuthKeyViaOAuth(
            tags: [tag],
            reusable: true,
            ephemeral: false,
            preauthorized: true,
            expirySeconds: 0,
            description: "Auto-regenerated by Scrcpy Remote"
        ) else {
            isRegeneratingKey = false
            completion(false, "Failed to initiate auth key creation")
            return
        }

        // Poll for result
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let timeoutSeconds = 30
            var elapsed = 0

            while elapsed < timeoutSeconds {
                guard let self = self else { return }

                let status = self.getOAuthStatus()

                if status == 1 {
                    // Success
                    if let authKey = self.getOAuthLastAuthKey() {
                        let expiresAt = self.getOAuthLastExpiresAt() ?? ""

                        // Save new auth key to UserDefaults
                        DispatchQueue.main.async {
                            UserDefaults.standard.set(authKey, forKey: "settings.tailscale.auth_key")
                            UserDefaults.standard.set(true, forKey: "settings.tailscale.auth_key_generated_via_oauth")
                            UserDefaults.standard.set(expiresAt, forKey: "settings.tailscale.auth_key_expires_at")

                            self.isRegeneratingKey = false
                            self.lastConfiguredAuthKey = "" // Force reconfiguration
                            print("[TailscaleManager] Auth key auto-regenerated successfully, expires: \(expiresAt)")
                            completion(true, nil)
                        }
                    } else {
                        self.isRegeneratingKey = false
                        completion(false, "Key generated but could not be retrieved")
                    }
                    return
                } else if status == -1 {
                    // Error
                    let errorMsg = self.getOAuthLastError() ?? "Unknown error"
                    self.isRegeneratingKey = false
                    completion(false, "OAuth error: \(errorMsg)")
                    return
                }

                Thread.sleep(forTimeInterval: 0.5)
                elapsed += 1
            }

            // Timeout
            self?.isRegeneratingKey = false
            completion(false, "Timeout waiting for auth key generation")
        }
    }

    /// Synchronous version of auto-regenerate for use in connection flow
    /// - Returns: true if auth key is valid (not expired or successfully regenerated)
    func ensureAuthKeyValid() -> Bool {
        guard isAuthKeyExpired() else {
            return true
        }

        guard canAutoRegenerateAuthKey() else {
            print("[TailscaleManager] Auth key expired but OAuth not configured")
            return false
        }

        var success = false
        var errorMessage: String?
        let semaphore = DispatchSemaphore(value: 0)

        autoRegenerateAuthKeyIfNeeded { result, error in
            success = result
            errorMessage = error
            semaphore.signal()
        }

        // Wait up to 35 seconds for regeneration
        let timeout = DispatchTime.now() + .seconds(35)
        if semaphore.wait(timeout: timeout) == .timedOut {
            print("[TailscaleManager] Auth key regeneration timed out")
            return false
        }

        if let error = errorMessage {
            print("[TailscaleManager] Auth key regeneration failed: \(error)")
        }

        return success
    }
    
    // MARK: - Configuration Management

    /// Configure Tailscale with settings from AppSettings
    /// - Parameter appSettings: The app settings containing Tailscale configuration
    /// - Returns: true if configuration was successful, false otherwise
    func configureFromSettings() -> Bool {
        // Get the shared AppSettings instance by reading from UserDefaults
        var authKey = UserDefaults.standard.string(forKey: "settings.tailscale.auth_key") ?? ""
        let hostname = UserDefaults.standard.string(forKey: "settings.tailscale.hostname") ?? "ScrcpyRemote_iOS"

        // Check if auth key needs regeneration (expired + OAuth configured)
        // Note: This is a quick check, actual regeneration happens in ensureConnectedWithAutoRegenerate
        if isAuthKeyExpired() && canAutoRegenerateAuthKey() {
            print("[TailscaleManager] Auth key expired, will trigger regeneration in connection flow")
        }

        // Check if configuration has changed
        let configChanged = authKey != lastConfiguredAuthKey || hostname != lastConfiguredHostname

        // Skip if configuration hasn't changed and we're already connected
        if !configChanged && isConnected() {
            print("[TailscaleManager] Configuration unchanged and already connected")
            return true
        }

        print("[TailscaleManager] Configuring with settings - Auth Key: \(authKey.isEmpty ? "EMPTY" : "\(authKey.prefix(10))..."), Hostname: \(hostname)")

        // Validate auth key
        guard !authKey.isEmpty else {
            print("[TailscaleManager] Auth key is not set in settings")
            return false
        }

        // Set authentication key
        guard setAuthKey(authKey) else {
            print("[TailscaleManager] Failed to set authentication key")
            return false
        }

        // Set hostname
        guard setHostname(hostname) else {
            print("[TailscaleManager] Failed to set hostname")
            return false
        }

        // Setup persistent state directory
        guard setupPersistentStateDirectory() else {
            print("[TailscaleManager] Failed to setup persistent state directory")
            return false
        }

        // Update last configured values
        lastConfiguredAuthKey = authKey
        lastConfiguredHostname = hostname

        print("[TailscaleManager] Configuration completed successfully")
        return true
    }

    /// Configure and connect with automatic auth key regeneration if needed
    /// - Parameter statusCallback: Optional callback to report status updates (for UI)
    /// - Parameter completion: Callback with success status
    func ensureConnectedWithAutoRegenerate(statusCallback: ((String) -> Void)? = nil, completion: @escaping (Bool) -> Void) {
        // Check if auth key needs regeneration
        if isAuthKeyExpired() && canAutoRegenerateAuthKey() {
            statusCallback?("Regenerating expired auth key...")

            autoRegenerateAuthKeyIfNeeded { [weak self] success, error in
                guard let self = self else {
                    completion(false)
                    return
                }

                if !success {
                    print("[TailscaleManager] Auto-regeneration failed: \(error ?? "Unknown error")")
                    statusCallback?("Failed to regenerate auth key")
                    completion(false)
                    return
                }

                statusCallback?("Auth key regenerated, connecting...")

                // Now configure and connect
                DispatchQueue.main.async {
                    let configured = self.configureFromSettings()
                    if configured {
                        self.connectAsync()
                        self.lastConnectionTime = Date()
                        self.setupKeepAliveTimer()
                        completion(true)
                    } else {
                        completion(false)
                    }
                }
            }
        } else {
            // No regeneration needed, proceed normally
            let configured = configureFromSettings()
            if configured {
                if isConnected() && shouldKeepConnectionAlive {
                    completion(true)
                    return
                }
                connectAsync()
                lastConnectionTime = Date()
                setupKeepAliveTimer()
                completion(true)
            } else {
                completion(false)
            }
        }
    }
    
    /// Check if Tailscale configuration is valid
    /// - Returns: true if both auth key and hostname are set, false otherwise
    func isConfigurationValid() -> Bool {
        let authKey = UserDefaults.standard.string(forKey: "settings.tailscale.auth_key") ?? ""
        
        return !authKey.isEmpty
    }
    
    /// Get current configuration status for debugging
    /// - Returns: Dictionary with configuration details
    func getConfigurationStatus() -> [String: Any] {
        let authKey = UserDefaults.standard.string(forKey: "settings.tailscale.auth_key") ?? ""
        let hostname = UserDefaults.standard.string(forKey: "settings.tailscale.hostname") ?? ""
        
        return [
            "authKeySet": !authKey.isEmpty,
            "authKeyLength": authKey.count,
            "hostname": hostname,
            "lastConfiguredAuthKey": lastConfiguredAuthKey.isEmpty ? "none" : "\(lastConfiguredAuthKey.prefix(10))...",
            "lastConfiguredHostname": lastConfiguredHostname,
            "configurationValid": isConfigurationValid(),
            "isConnected": isConnected()
        ]
    }
    
    // MARK: - Connection Management
    
    /// Checks if connection should be kept alive
    private var shouldKeepConnectionAlive: Bool {
        guard let lastTime = lastConnectionTime else { return false }
        return Date().timeIntervalSince(lastTime) < connectionKeepAliveSeconds
    }
    
    /// Starts or maintains Tailscale connection
    /// - Returns: true if connected or connection initiated successfully
    func ensureConnected() -> Bool {
        // First, configure from settings
        guard configureFromSettings() else {
            print("[TailscaleManager] Failed to configure from settings")
            return false
        }
        
        // If already connected and within keep-alive window, return success
        if isConnected() && shouldKeepConnectionAlive {
            return true
        }
        
        // Start new connection
        connectAsync()
        lastConnectionTime = Date()
        
        // Set up keep-alive timer
        setupKeepAliveTimer()
        
        return true
    }
    
    /// Sets up a timer to maintain connection for 10 minutes.
    ///
    /// Foundation's Timer is NOT thread-safe and must only be invalidated /
    /// scheduled on the runloop it lives on (main here). This is reachable
    /// from Swift Concurrency completion threads (SessionNetworking →
    /// ensureConnected) and racing two threads on `connectionTimer` produced
    /// the field crash:
    ///   TailscaleManager.setupKeepAliveTimer +36 → CFRunLoopTimerInvalidate
    ///   → CFRetain → CF_IS_OBJC (pointer-auth DA fault)
    /// Always hop to main before touching the timer.
    private func setupKeepAliveTimer() {
        if Thread.isMainThread {
            performSetupKeepAliveTimer()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.performSetupKeepAliveTimer()
            }
        }
    }

    private func performSetupKeepAliveTimer() {
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: connectionKeepAliveSeconds, repeats: false) { [weak self] _ in
            self?.handleConnectionTimeout()
        }
    }
    
    /// Handles connection timeout - cleanup if no active forwards
    private func handleConnectionTimeout() {
        if activeForwards.isEmpty {
            print("[TailscaleManager] Connection timeout, cleaning up inactive connection")
            _ = cleanup()
            lastConnectionTime = nil
        } else {
            print("[TailscaleManager] Connection timeout but has active forwards, keeping connection")
            // Extend keep-alive if there are active forwards
            setupKeepAliveTimer()
        }
    }
    
    /// Extends the connection keep-alive timer
    func extendConnectionKeepAlive() {
        lastConnectionTime = Date()
        setupKeepAliveTimer()
    }
    
    // MARK: - Configuration Functions
    
    /// Set the Tailscale authentication key
    /// - Parameter authKey: The Tailscale auth key obtained from the admin console
    /// - Returns: true if successful, false otherwise
    func setAuthKey(_ authKey: String) -> Bool {
        return authKey.withCString { cString in
            return update_tsnet_auth_key(UnsafeMutablePointer(mutating: cString)) == 0
        }
    }
    
    /// Set the device hostname for Tailscale
    /// - Parameter hostname: The hostname to use for this device
    /// - Returns: true if successful, false otherwise
    func setHostname(_ hostname: String) -> Bool {
        return hostname.withCString { cString in
            return tsnet_update_hostname(UnsafeMutablePointer(mutating: cString)) == 0
        }
    }
    
    /// Set the state directory for Tailscale data
    /// - Parameter stateDir: Path to the directory where Tailscale will store state data
    /// - Returns: true if successful, false otherwise
    func setStateDirectory(_ stateDir: String) -> Bool {
        return stateDir.withCString { cString in
            return tsnet_update_state_dir(UnsafeMutablePointer(mutating: cString)) == 0
        }
    }
    
    // MARK: - Connection Functions
    
    /// Start an asynchronous connection to Tailscale
    func connectAsync() {
        tsnet_connect_async()
    }
    
    /// Get the current connection status
    /// - Returns: 1 if connected, -1 if failed, 0 if connecting
    func getConnectionStatus() -> Int32 {
        return tsnet_get_connect_status()
    }
    
    /// Check if the TSNet server is started and running
    /// - Returns: true if the server is running, false otherwise
    func isStarted() -> Bool {
        return tsnet_is_started() != 0
    }
    
    /// Clean up all Tailscale connections
    /// - Returns: Number of connections cleaned up
    func cleanup() -> Int32 {
        invalidateConnectionTimerOnMain()
        lastConnectionTime = nil
        
        // Stop all forwards before cleanup
        _ = stopAllForwards()
        
        return tsnet_cleanup()
    }
    
    // MARK: - Port Forwarding Functions
    
    /// Start port forwarding from remote address to local port
    /// - Parameters:
    ///   - remoteAddr: Remote address to forward from
    ///   - remotePort: Remote port to forward from
    ///   - localPort: Local port to forward to
    /// - Returns: true if successful, false otherwise
    func startForward(remoteAddr: String, remotePort: Int, localPort: Int) -> Bool {
        let result = remoteAddr.withCString { cString in
            return tsnet_start_forward(UnsafeMutablePointer(mutating: cString), Int32(remotePort), Int32(localPort)) == 0
        }
        
        if result {
            // Add to active forwards list
            let forward = (remoteAddr: remoteAddr, remotePort: remotePort, localPort: localPort)
            if !activeForwards.contains(where: { $0.remoteAddr == forward.remoteAddr && $0.remotePort == forward.remotePort && $0.localPort == forward.localPort }) {
                activeForwards.append(forward)
            }
            
            // Extend connection keep-alive when starting forwards
            extendConnectionKeepAlive()
        }
        
        return result
    }
    
    /// Stop port forwarding
    /// - Parameters:
    ///   - remoteAddr: Remote address
    ///   - remotePort: Remote port
    ///   - localPort: Local port
    /// - Returns: true if successful, false otherwise
    func stopForward(remoteAddr: String, remotePort: Int, localPort: Int) -> Bool {
        let result = remoteAddr.withCString { cString in
            return tsnet_stop_forward(UnsafeMutablePointer(mutating: cString), Int32(remotePort), Int32(localPort)) == 0
        }
        
        if result {
            // Remove from active forwards list
            activeForwards.removeAll { $0.remoteAddr == remoteAddr && $0.remotePort == remotePort && $0.localPort == localPort }
        }
        
        return result
    }
    
    /// Stop all port forwarding
    /// - Returns: true if successful, false otherwise
    func stopAllForwards() -> Bool {
        let result = tsnet_stop_all_forwards() == 0
        if result {
            activeForwards.removeAll()
        }
        return result
    }
    
    /// Get list of active port forwards
    /// - Returns: Array of active forwards
    func getActiveForwards() -> [(remoteAddr: String, remotePort: Int, localPort: Int)] {
        return activeForwards
    }
    
    // MARK: - Information Retrieval Functions
    
    /// Get the last error message from Tailscale operations
    /// - Returns: Error message string, or nil if no error
    func getLastError() -> String? {
        guard let errorPtr = tsnet_get_last_error() else { return nil }
        let errorString = String(cString: errorPtr)
        free(errorPtr)
        return errorString
    }
    
    /// Get the last assigned IPv4 address
    /// - Returns: IPv4 address string, or nil if not available
    func getLastIPv4() -> String? {
        guard let ipPtr = tsnet_get_last_ipv4() else { return nil }
        let ipString = String(cString: ipPtr)
        free(ipPtr)
        return ipString
    }
    
    /// Get the last assigned IPv6 address
    /// - Returns: IPv6 address string, or nil if not available
    func getLastIPv6() -> String? {
        guard let ipPtr = tsnet_get_last_ipv6() else { return nil }
        let ipString = String(cString: ipPtr)
        free(ipPtr)
        return ipString
    }
    
    /// Get the last used hostname
    /// - Returns: Hostname string, or nil if not available
    func getLastHostname() -> String? {
        guard let hostnamePtr = tsnet_get_last_hostname() else { return nil }
        let hostnameString = String(cString: hostnamePtr)
        free(hostnamePtr)
        return hostnameString
    }
    
    /// Get the MagicDNS configuration
    /// - Returns: MagicDNS string, or nil if not available
    func getLastMagicDNS() -> String? {
        guard let dnsPtr = tsnet_get_last_magic_dns() else { return nil }
        let dnsString = String(cString: dnsPtr)
        free(dnsPtr)
        return dnsString
    }
    
    /// Get all available Tailscale IP addresses
    /// - Returns: Comma-separated list of IP addresses, or nil if not available
    func getTailscaleIPs() -> String? {
        guard let ipsPtr = tsnet_get_tailscale_ips() else { return nil }
        let ipsString = String(cString: ipsPtr)
        free(ipsPtr)
        return ipsString
    }
    
    // MARK: - Utility Functions
    
    /// Check if currently connected to Tailscale
    /// - Returns: true if connected and server is running, false otherwise
    func isConnected() -> Bool {
        return getConnectionStatus() == 1 && isStarted()
    }
    
    /// Get current configuration summary
    /// - Returns: Tuple containing current hostname and state directory
    func getCurrentConfig() -> (hostname: String?, stateDir: String?) {
        var hostname: String?
        var stateDir: String?
        
        if let hostnamePtr = tsnet_get_hostname() {
            hostname = String(cString: hostnamePtr)
            free(hostnamePtr)
        }
        
        if let stateDirPtr = tsnet_get_state_dir() {
            stateDir = String(cString: stateDirPtr)
            free(stateDirPtr)
        }
        
        return (hostname, stateDir)
    }
    
    /// Get detailed connection info for display
    /// - Returns: Formatted string with connection details, or nil if not connected
    func getConnectionInfo() -> String? {
        guard isConnected() else { return nil }
        
        var info: [String] = []
        
        if let hostname = getLastHostname() {
            info.append("Hostname: \(hostname)")
        }
        
        if let ipv4 = getLastIPv4() {
            info.append("IPv4: \(ipv4)")
        }
        
        if let ipv6 = getLastIPv6() {
            info.append("IPv6: \(ipv6)")
        }
        
        if let magicDNS = getLastMagicDNS() {
            info.append("MagicDNS: \(magicDNS)")
        }
        
        if let allIPs = getTailscaleIPs() {
            info.append("All IPs: \(allIPs)")
        }
        
        if !activeForwards.isEmpty {
            let forwardInfo = activeForwards.map { "Forward: \($0.remoteAddr):\($0.remotePort) -> 127.0.0.1:\($0.localPort)" }
            info.append(contentsOf: forwardInfo)
        }
        
        return info.isEmpty ? nil : info.joined(separator: "\n")
    }
    
    /// Get the primary IP address (IPv4 preferred, fallback to IPv6)
    /// - Returns: Primary IP address string, or nil if not available
    func getPrimaryIP() -> String? {
        if let ipv4 = getLastIPv4(), !ipv4.isEmpty {
            return ipv4
        } else if let ipv6 = getLastIPv6(), !ipv6.isEmpty {
            return ipv6
        }
        return nil
    }
    
    // MARK: - Private Helper Functions
    
    /// Get the persistent state directory path for Tailscale data
    /// - Returns: Path to the persistent state directory in app's Library folder
    private func getPersistentStateDirectory() -> String {
        let libraryPath = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first!
        let tailscaleDir = libraryPath + "/TailscaleState"
        return tailscaleDir
    }
    
    /// Ensure the state directory exists
    /// - Parameter path: Directory path to create
    /// - Returns: true if directory exists or was created successfully
    private func ensureDirectoryExists(_ path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            return true
        } catch {
            print("[TailscaleManager] Failed to create directory at \(path): \(error)")
            return false
        }
    }
    
    /// Setup persistent state directory with proper configuration
    /// - Returns: true if setup was successful, false otherwise
    func setupPersistentStateDirectory() -> Bool {
        let stateDir = getPersistentStateDirectory()
        
        // Ensure the directory exists
        guard ensureDirectoryExists(stateDir) else {
            return false
        }
        
        // Set the state directory in Tailscale
        return setStateDirectory(stateDir)
    }
    
    /// Get the current persistent state directory path
    /// - Returns: Path to the persistent state directory
    func getStateDirectoryPath() -> String {
        return getPersistentStateDirectory()
    }
    
    /// Clear all persistent state data
    /// - Returns: true if successful, false otherwise
    func clearPersistentState() -> Bool {
        let stateDir = getPersistentStateDirectory()
        
        do {
            // Remove the entire Tailscale directory
            if FileManager.default.fileExists(atPath: stateDir) {
                try FileManager.default.removeItem(atPath: stateDir)
                print("[TailscaleManager] Persistent state directory cleared: \(stateDir)")
            }
            return true
        } catch {
            print("[TailscaleManager] Failed to clear persistent state: \(error)")
            return false
        }
    }
    
    /// Check if persistent state exists
    /// - Returns: true if state directory exists and contains data
    func hasPersistentState() -> Bool {
        let stateDir = getPersistentStateDirectory()
        return FileManager.default.fileExists(atPath: stateDir)
    }
    
    deinit {
        // deinit may run on any thread; hop to main before touching the timer.
        let timer = connectionTimer
        connectionTimer = nil
        if let timer = timer {
            if Thread.isMainThread {
                timer.invalidate()
            } else {
                DispatchQueue.main.async {
                    timer.invalidate()
                }
            }
        }
    }

    private func invalidateConnectionTimerOnMain() {
        if Thread.isMainThread {
            connectionTimer?.invalidate()
            connectionTimer = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.connectionTimer?.invalidate()
                self?.connectionTimer = nil
            }
        }
    }

    // MARK: - OAuth Functions

    /// Set OAuth client credentials
    /// - Parameters:
    ///   - clientID: OAuth client ID from Tailscale admin console
    ///   - clientSecret: OAuth client secret
    /// - Returns: true if successful, false otherwise
    func setOAuthCredentials(clientID: String, clientSecret: String) -> Bool {
        return clientID.withCString { idPtr in
            return clientSecret.withCString { secretPtr in
                return oauth_set_credentials(
                    UnsafeMutablePointer(mutating: idPtr),
                    UnsafeMutablePointer(mutating: secretPtr)
                ) == 0
            }
        }
    }

    /// Validate OAuth credentials by attempting to get an access token
    func validateOAuthCredentials() {
        oauth_validate_credentials()
    }

    /// Check if OAuth credentials are configured
    /// - Returns: true if OAuth credentials are set
    func isOAuthCredentialsSet() -> Bool {
        return oauth_is_credentials_set() != 0
    }

    /// Get the configured OAuth client ID
    /// - Returns: Client ID string, or nil if not set
    func getOAuthClientID() -> String? {
        guard let clientIDPtr = oauth_get_client_id() else { return nil }
        let clientID = String(cString: clientIDPtr)
        free(clientIDPtr)
        return clientID.isEmpty ? nil : clientID
    }

    /// Clear OAuth credentials
    func clearOAuthCredentials() {
        oauth_clear_credentials()
    }

    /// Create an auth key using OAuth
    /// - Parameters:
    ///   - tags: Array of tags (e.g., ["tag:server", "tag:mobile"])
    ///   - reusable: Whether the key can be used multiple times
    ///   - ephemeral: Whether devices using this key are ephemeral
    ///   - preauthorized: Whether to skip device approval
    ///   - expirySeconds: Key expiry in seconds (0 for default, max 90 days)
    ///   - description: Optional description for the key
    /// - Returns: true if the request was initiated, false otherwise
    func createAuthKeyViaOAuth(tags: [String], reusable: Bool = true, ephemeral: Bool = false, preauthorized: Bool = true, expirySeconds: Int = 0, description: String = "") -> Bool {
        let tagsString = tags.joined(separator: ",")

        return tagsString.withCString { tagsPtr in
            return description.withCString { descPtr in
                return oauth_create_auth_key(
                    UnsafeMutablePointer(mutating: tagsPtr),
                    reusable ? 1 : 0,
                    ephemeral ? 1 : 0,
                    preauthorized ? 1 : 0,
                    Int32(expirySeconds),
                    UnsafeMutablePointer(mutating: descPtr)
                ) == 0
            }
        }
    }

    /// Get OAuth operation status
    /// - Returns: 0 = in progress, 1 = success, -1 = error
    func getOAuthStatus() -> Int32 {
        return oauth_get_status()
    }

    /// Get the last generated auth key via OAuth
    /// - Returns: Auth key string, or nil if not available
    func getOAuthLastAuthKey() -> String? {
        guard let keyPtr = oauth_get_last_auth_key() else { return nil }
        let key = String(cString: keyPtr)
        free(keyPtr)
        return key.isEmpty ? nil : key
    }

    /// Get the expiration time of the last generated auth key
    /// - Returns: Expiration time string, or nil if not available
    func getOAuthLastExpiresAt() -> String? {
        guard let expiresPtr = oauth_get_last_expires_at() else { return nil }
        let expires = String(cString: expiresPtr)
        free(expiresPtr)
        return expires.isEmpty ? nil : expires
    }

    /// Get the last OAuth error message
    /// - Returns: Error message string, or nil if no error
    func getOAuthLastError() -> String? {
        guard let errorPtr = oauth_get_last_error() else { return nil }
        let error = String(cString: errorPtr)
        free(errorPtr)
        return error.isEmpty ? nil : error
    }

    /// Reset OAuth status for a new operation
    func resetOAuthStatus() {
        oauth_reset_status()
    }
} 
