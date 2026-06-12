//
//  ContentView.swift
//  Scrcpy Remote
//
//  Created by Ethan on 12/5/24.
//

import SwiftUI

struct MainContentView: View {
    @StateObject private var connectionManager = SessionConnectionManager.shared
    
    @State private var selectedTab = 0
    @State private var isSettingsPresented = false
    @State private var isSessionCreatePresented = false
    @State private var isNewActionPresented = false
    @State private var editingSession: ScrcpySession? = nil
    @State private var savedSessions: [ScrcpySession] = []
    @State private var currentStatusMessage: String?
    @State private var isNavigationBarHidden: Bool = false
    @State private var shouldShowNavigationBarAfterDismiss: Bool = false
    @State private var userDismissedConnection: Bool = false
    @State private var showMigrationAlert: Bool = false
    @State private var legacyDeviceInfo: (host: String, port: String)?
    @EnvironmentObject var appSettings: AppSettings
    
    init(sessions: [ScrcpySession] = []) {
        self._savedSessions = State(initialValue: sessions)
        
        // Configure navigation bar and tab bar appearance for iOS 14+
        if #available(iOS 14.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
            appearance.shadowColor = UIColor.separator  // Add subtle shadow/border below navigation bar
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
            
            let tabBarAppearance = UITabBarAppearance()
            tabBarAppearance.configureWithDefaultBackground()
            tabBarAppearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
            UITabBar.appearance().standardAppearance = tabBarAppearance
            if #available(iOS 15.0, *) {
                UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
            }
        }
    }
    
    func reloadSessions() {
        savedSessions = SessionManager.shared.loadSessions().map {
            ScrcpySession(sessionModel: $0)
        }
        print("Reloaded sessions:", savedSessions.count)
    }
    
    /// 连接到指定会话
    private func connectToSession(_ session: ScrcpySession) {
        print("Connecting to session:", session.title)
        
        // 重置用户关闭标志，允许显示新的连接状态
        userDismissedConnection = false
        
        // 使用 SessionConnectionManager 进行连接
        SessionConnectionManager.shared.connectToSession(
            session.sessionModel,
            statusCallback: { status, message, isConnecting in
                // 状态更新由 @ObservedObject 自动处理
                DispatchQueue.main.async {
                    print("📝 [MainContentView] Status callback received - Status: \(status.description), Message: \(message ?? "nil"), IsConnecting: \(isConnecting)")
                    self.currentStatusMessage = message
                    if let msg = message {
                        print("📝 [MainContentView] Setting currentStatusMessage to: \(msg)")
                    } else {
                        print("📝 [MainContentView] Setting currentStatusMessage to nil")
                    }
                }
                
                switch status {
                case ScrcpyStatusSDLWindowAppeared:
                    print("✅ Connected to session:", session.title)
                    
                case ScrcpyStatusConnectingFailed:
                    print("❌ Failed to connect to session:", session.title)
                    
                default:
                    print("🔄 Connection status update:", status.description)
                    if let msg = message {
                        print("📝 Status message:", msg)
                    }
                }
            },
            errorCallback: { title, message in
                // 错误信息现在通过 ConnectionStatusView 展示，不再显示 alert
                print("❌ [MainContentView] Connection error: \(title) - \(message)")
                // 错误信息会通过 statusCallback 传递到 ConnectionStatusView
            }
        )
    }

    // MARK: - Computed Properties
    
    // MARK: - Migration Methods
    
    private func checkForMigration() {
        DispatchQueue.main.async {
            if SessionManager.shared.shouldShowMigrationPrompt() {
                self.legacyDeviceInfo = SessionManager.shared.getLegacyDeviceInfo()
                self.showMigrationAlert = true
            }
        }
    }
    
    private func performMigration() {
        SessionManager.shared.performUserRequestedMigration()
        reloadSessions()
        showMigrationAlert = false
    }
    
    private func declineMigration() {
        SessionManager.shared.declineMigration()
        showMigrationAlert = false
    }
    
    // MARK: - Computed Properties
    
    /// 判断是否应该显示连接状态视图
    private var shouldShowConnectionStatusView: Bool {
        // 如果用户主动关闭了连接状态视图，立即隐藏
        guard !userDismissedConnection else {
            return false
        }
        
        // 只有在以下情况下才显示 ConnectionStatusView：
        // 1. 正在连接中
        // 2. 连接失败（等待用户主动点击 dismiss 按钮）
        // 3. 有当前会话且状态处于连接过程中（不包括连接失败）
        return connectionManager.isConnecting || 
               (connectionManager.connectionStatus == ScrcpyStatusConnectingFailed && currentStatusMessage != nil) ||
               (connectionManager.currentSession != nil && 
                connectionManager.connectionStatus != ScrcpyStatusDisconnected &&
                connectionManager.connectionStatus != ScrcpyStatusConnectingFailed &&
                connectionManager.connectionStatus.rawValue < ScrcpyStatusSDLWindowAppeared.rawValue)
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                TabView(selection: $selectedTab) {
                    SessionsView(savedSessions: $savedSessions, onDeleteSession: { id in
                        print("Deleting session:", id)
                        SessionManager.shared.deleteSession(id: id)
                        reloadSessions()
                    }, onConnectSession: { session in
                        connectToSession(session)
                    }, onEditSession: { session in
                        print("Editing session:", session.title)
                        editingSession = session
                    }, onDuplicateSession: { duplicatedSession in
                        print("Duplicating session:", duplicatedSession.title)
                        SessionManager.shared.saveSession(duplicatedSession.sessionModel)
                        reloadSessions()
                    })
                        .tabItem {
                            Image(systemName: "rectangle.stack")
                            Text("Sessions")
                        }
                        .tag(0)
                    ActionsView()
                        .tabItem {
                            Image(systemName: "play.square.stack.fill")
                            Text("Actions")
                        }
                        .tag(1)
                }
                .navigationTitle(
                    selectedTab == 0 ? "Scrcpy Sessions" : "Scrcpy Actions"
                )
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: {
                            isSettingsPresented.toggle()
                        }) {
                            Image(systemName: "gear")
                        }
                        .disabled(connectionManager.isConnecting)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            if selectedTab == 0 {
                                isSessionCreatePresented.toggle()
                            } else if selectedTab == 1 {
                                isNewActionPresented.toggle()
                            }
                        }) {
                            Image(systemName: "plus")
                        }
                        .disabled(connectionManager.isConnecting)
                    }
                }
                .navigationBarHidden(isNavigationBarHidden)
                .sheet(isPresented: $isSettingsPresented) {
                    SettingsView()
                        .environmentObject(appSettings)
                }
                .sheet(isPresented: $isSessionCreatePresented, onDismiss: {
                    editingSession = nil
                    reloadSessions()
                }) {
                    SessionCreateView()
                        .environmentObject(appSettings)
                }
                .sheet(isPresented: $isNewActionPresented) {
                    NewActionView { action in
                        ActionManager.shared.saveAction(action)
                    }
                }
                .sheet(item: $editingSession, onDismiss: {
                    editingSession = nil
                    reloadSessions()
                }) { item in
                    SessionCreateView(sessionModel: item.sessionModel)
                        .environmentObject(appSettings)
                }
                .overlay {
                    if shouldShowConnectionStatusView {
                        ConnectionStatusView(
                            session: ScrcpySession(sessionModel: connectionManager.currentSession ?? ScrcpySessionModel()),
                            connectionStatus: connectionManager.connectionStatus,
                            statusMessage: currentStatusMessage,
                            onCancel: {
                                print("🚫 [MainContentView] User dismissed connection, restoring navigation bar")
                                
                                // 立即设置用户关闭标志，强制隐藏连接状态视图
                                userDismissedConnection = true
                                
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    isNavigationBarHidden = false
                                }
                                currentStatusMessage = nil
                                
                                // 断开连接并清理会话状态
                                SessionConnectionManager.shared.disconnectCurrent()
                                
                                // 对于连接失败的情况，需要手动清理会话状态
                                if connectionManager.connectionStatus == ScrcpyStatusConnectingFailed {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        SessionConnectionManager.shared.clearCurrentSession()
                                    }
                                }
                            }
                        )
                        .transition(.opacity.combined(with: .scale))
                        .animation(.easeInOut(duration: 0.3), value: shouldShowConnectionStatusView)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .startSchemeConnection)) { notification in
                    guard let session = notification.userInfo?["session"] as? ScrcpySessionModel else {
                        print("❌ [MainContentView] No session found in scheme connection notification")
                        return
                    }
                    
                    print("🔗 [MainContentView] Received scheme connection request for: \(session.host):\(session.port)")
                    
                    let scrcpySession = ScrcpySession(sessionModel: session)
                    connectToSession(scrcpySession)
                    
                    selectedTab = 0
                }
                .onAppear {
                    if savedSessions.isEmpty {
                        reloadSessions()
                    }
                    checkForMigration()
                }
                // Session store mutated outside this view (e.g. the DEBUG
                // harness RPC writing through SessionManager) — re-read it.
                .onReceive(NotificationCenter.default.publisher(
                    for: Notification.Name("ScrcpySessionStoreChanged"))) { _ in
                    reloadSessions()
                }
                .onChange(of: connectionManager.isConnecting) { isConnecting in
                    if isConnecting {
                        isNavigationBarHidden = true
                    }
                    
                    if !isConnecting && connectionManager.connectionStatus != ScrcpyStatusConnectingFailed {
                        print("🧹 [MainContentView] Auto-clearing currentStatusMessage (not in failure state)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            currentStatusMessage = nil
                            print("🧹 [MainContentView] currentStatusMessage cleared")
                        }
                    } else if !isConnecting && connectionManager.connectionStatus == ScrcpyStatusConnectingFailed {
                        print("⚠️ [MainContentView] Not auto-clearing currentStatusMessage (in failure state)")
                    }
                }
                .onChange(of: connectionManager.connectionStatus) { newStatus in
                    print("🔄 [MainContentView] Connection status changed to: \(newStatus.description)")
                    print("🔄 [MainContentView] Current currentStatusMessage: \(currentStatusMessage ?? "nil")")
                    
                    switch newStatus {
                    case ScrcpyStatusSDLWindowAppeared:
                        print("✅ [MainContentView] SDL Window appeared, restoring navigation bar and hiding status view")
                        isNavigationBarHidden = false
                        userDismissedConnection = false // 重置用户关闭标志
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            currentStatusMessage = nil
                            print("🧹 [MainContentView] currentStatusMessage cleared after SDL window appeared")
                        }
                        
                    case ScrcpyStatusConnected:
                        print("✅ [MainContentView] Connection successful, preparing to hide status view")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            currentStatusMessage = nil
                            print("🧹 [MainContentView] currentStatusMessage cleared after connection success")
                        }
                        
                    case ScrcpyStatusConnectingFailed:
                        print("❌ [MainContentView] Connection failed, waiting for user to dismiss")
                        print("❌ [MainContentView] Current currentStatusMessage: \(currentStatusMessage ?? "nil")")
                        isNavigationBarHidden = true
                        
                        // 不自动清除状态消息，等待用户点击 dismiss 按钮
                        
                    case ScrcpyStatusDisconnected:
                        print("🔌 [MainContentView] Connection disconnected, restoring navigation bar and cleaning up")
                        isNavigationBarHidden = false
                        userDismissedConnection = false // 重置用户关闭标志
                        currentStatusMessage = nil
                        print("🧹 [MainContentView] currentStatusMessage cleared after disconnect")
                        
                    default:
                        break
                    }
                }
                // Migration prompt
                .alert("Legacy Data Found", isPresented: $showMigrationAlert) {
                    Button("Migrate") {
                        performMigration()
                    }
                    Button("Skip", role: .cancel) {
                        declineMigration()
                    }
                } message: {
                    if let deviceInfo = legacyDeviceInfo {
                        Text("We found device settings from the previous versions:\n\n📱 Device: \(deviceInfo.host):\(deviceInfo.port)\n\nWould you like to migrate this device to the new app? A new ADB device will be created with your previous settings.")
                    } else {
                        Text("We found settings from the previous versions. Would you like to migrate them to the new version?")
                    }
                }
            }
        } else {
            NavigationView {
                TabView(selection: $selectedTab) {
                    SessionsView(savedSessions: $savedSessions, onDeleteSession: { id in
                        print("Deleting session:", id)
                        SessionManager.shared.deleteSession(id: id)
                        reloadSessions()
                    }, onConnectSession: { session in
                        connectToSession(session)
                    }, onEditSession: { session in
                        print("Editing session:", session.title)
                        editingSession = session
                    }, onDuplicateSession: { duplicatedSession in
                        print("Duplicating session:", duplicatedSession.title)
                        SessionManager.shared.saveSession(duplicatedSession.sessionModel)
                        reloadSessions()
                    })
                        .tabItem {
                            Image(systemName: "rectangle.stack")
                            Text("Sessions")
                        }
                        .tag(0)
                    ActionsView()
                        .tabItem {
                            if #available(iOS 15.0, *) {
                                Image(systemName: "play.rectangle.on.rectangle.fill")
                            } else {
                                Image(systemName: "play.rectangle.on.rectangle")
                            }
                            Text("Actions")
                        }
                        .tag(1)
                }
                .navigationBarTitle(
                    selectedTab == 0 ? "Scrcpy Sessions" : "Scrcpy Actions",
                    displayMode: .inline
                )
                .navigationBarItems(leading: Button(action: {
                    isSettingsPresented.toggle()
                }) {
                    Image(systemName: "gear")
                }.disabled(connectionManager.isConnecting), trailing: Button(action: {
                    if selectedTab == 0 {
                        isSessionCreatePresented.toggle()
                    } else if selectedTab == 1 {
                        isNewActionPresented.toggle()
                    }
                }) {
                    Image(systemName: "plus")
                }.disabled(connectionManager.isConnecting))
                .navigationBarHidden(isNavigationBarHidden)
                .sheet(isPresented: $isSettingsPresented) {
                    SettingsView()
                        .environmentObject(appSettings)
                }
                .sheet(isPresented: $isSessionCreatePresented, onDismiss: {
                    editingSession = nil
                    reloadSessions()
                }) {
                    SessionCreateView()
                        .environmentObject(appSettings)
                }
                .sheet(isPresented: $isNewActionPresented) {
                    NewActionView { action in
                        ActionManager.shared.saveAction(action)
                    }
                }
                .sheet(item: $editingSession, onDismiss: {
                    editingSession = nil
                    reloadSessions()
                }) { item in
                    SessionCreateView(sessionModel: item.sessionModel)
                        .environmentObject(appSettings)
                }
                .overlay {
                    if shouldShowConnectionStatusView {
                        ConnectionStatusView(
                            session: ScrcpySession(sessionModel: connectionManager.currentSession ?? ScrcpySessionModel()),
                            connectionStatus: connectionManager.connectionStatus,
                            statusMessage: currentStatusMessage,
                            onCancel: {
                                print("🚫 [MainContentView] User dismissed connection, restoring navigation bar")
                                
                                // 立即设置用户关闭标志，强制隐藏连接状态视图
                                userDismissedConnection = true
                                
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    isNavigationBarHidden = false
                                }
                                currentStatusMessage = nil
                                
                                // 断开连接并清理会话状态
                                SessionConnectionManager.shared.disconnectCurrent()
                                
                                // 对于连接失败的情况，需要手动清理会话状态
                                if connectionManager.connectionStatus == ScrcpyStatusConnectingFailed {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        SessionConnectionManager.shared.clearCurrentSession()
                                    }
                                }
                            }
                        )
                        .transition(.opacity.combined(with: .scale))
                        .animation(.easeInOut(duration: 0.3), value: shouldShowConnectionStatusView)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .startSchemeConnection)) { notification in
                    guard let session = notification.userInfo?["session"] as? ScrcpySessionModel else {
                        print("❌ [MainContentView] No session found in scheme connection notification")
                        return
                    }
                    
                    print("🔗 [MainContentView] Received scheme connection request for: \(session.host):\(session.port)")
                    
                    let scrcpySession = ScrcpySession(sessionModel: session)
                    connectToSession(scrcpySession)
                    
                    selectedTab = 0
                }
                .onAppear {
                    if savedSessions.isEmpty {
                        reloadSessions()
                    }
                    checkForMigration()
                }
                // Session store mutated outside this view (e.g. the DEBUG
                // harness RPC writing through SessionManager) — re-read it.
                .onReceive(NotificationCenter.default.publisher(
                    for: Notification.Name("ScrcpySessionStoreChanged"))) { _ in
                    reloadSessions()
                }
                .onChange(of: connectionManager.isConnecting) { isConnecting in
                    if isConnecting {
                        isNavigationBarHidden = true
                    }
                    
                    if !isConnecting && connectionManager.connectionStatus != ScrcpyStatusConnectingFailed {
                        print("🧹 [MainContentView] Auto-clearing currentStatusMessage (not in failure state)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            currentStatusMessage = nil
                            print("🧹 [MainContentView] currentStatusMessage cleared")
                        }
                    } else if !isConnecting && connectionManager.connectionStatus == ScrcpyStatusConnectingFailed {
                        print("⚠️ [MainContentView] Not auto-clearing currentStatusMessage (in failure state)")
                    }
                }
                .onChange(of: connectionManager.connectionStatus) { newStatus in
                    print("🔄 [MainContentView] Connection status changed to: \(newStatus.description)")
                    print("🔄 [MainContentView] Current currentStatusMessage: \(currentStatusMessage ?? "nil")")
                    
                    switch newStatus {
                    case ScrcpyStatusSDLWindowAppeared:
                        print("✅ [MainContentView] SDL Window appeared, restoring navigation bar and hiding status view")
                        isNavigationBarHidden = false
                        userDismissedConnection = false // 重置用户关闭标志
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            currentStatusMessage = nil
                            print("🧹 [MainContentView] currentStatusMessage cleared after SDL window appeared")
                        }
                        
                    case ScrcpyStatusConnected:
                        print("✅ [MainContentView] Connection successful, preparing to hide status view")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            currentStatusMessage = nil
                            print("🧹 [MainContentView] currentStatusMessage cleared after connection success")
                        }
                        
                    case ScrcpyStatusConnectingFailed:
                        print("❌ [MainContentView] Connection failed, waiting for user to dismiss")
                        print("❌ [MainContentView] Current currentStatusMessage: \(currentStatusMessage ?? "nil")")
                        isNavigationBarHidden = true
                        
                        // 不自动清除状态消息，等待用户点击 dismiss 按钮
                        
                    case ScrcpyStatusDisconnected:
                        print("🔌 [MainContentView] Connection disconnected, restoring navigation bar and cleaning up")
                        isNavigationBarHidden = false
                        userDismissedConnection = false // 重置用户关闭标志
                        currentStatusMessage = nil
                        print("🧹 [MainContentView] currentStatusMessage cleared after disconnect")
                        
                    default:
                        break
                    }
                }
                // Migration prompt
                .alert(isPresented: $showMigrationAlert) {
                    let title = "Legacy Data Found"
                    let message: String
                    if let deviceInfo = legacyDeviceInfo {
                        message = "We found device settings from the previous scrcpy-ios app:\n\n📱 Device: \(deviceInfo.host):\(deviceInfo.port)\n\nWould you like to migrate this device to the new app? A new ADB device will be created with your previous settings."
                    } else {
                        message = "We found settings from the previous scrcpy-ios app. Would you like to migrate them to the new version?"
                    }
                    
                    return Alert(
                        title: Text(title),
                        message: Text(message),
                        primaryButton: .default(Text("Migrate")) {
                            performMigration()
                        },
                        secondaryButton: .cancel(Text("Skip")) {
                            declineMigration()
                        }
                    )
                }
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
    }
}

#Preview {
    MainContentView(sessions: [
        ScrcpySession(sessionModel: ScrcpySessionModel(host: "test.abc.com", port: "5555", sessionName: "Test Server")),
        ScrcpySession(sessionModel: ScrcpySessionModel(host: "vnc://myvnc.com", port: "5901", sessionName: "My VNC")),
        ScrcpySession(sessionModel: ScrcpySessionModel(host: "adb://test.example.com", port: "1555")),
        ScrcpySession(sessionModel: ScrcpySessionModel(host: "10.1.1.1", port: "8080", sessionName: "Local Device")),
        ScrcpySession(sessionModel: ScrcpySessionModel(host: "test2.examle.com", port: "5555"))
    ])
}
