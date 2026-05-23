//
//  AppLogManager.swift
//  Scrcpy Remote
//
//  Created by Ethan on 12/8/24.
//

import Foundation
import UIKit

class AppLogManager: ObservableObject {
    static let shared = AppLogManager()
    
    @Published var isLoggingEnabled: Bool = false
    @Published var logFilesCount: Int = 0
    @Published var currentLogFileSize: Int64 = 0
    @Published var totalLogFilesSize: Int64 = 0
    
    private var currentLogFilePath: String?
    private let logsDirectory: String
    private let dateFormatter: DateFormatter
    private var originalStdout: Int32 = 0
    private var originalStderr: Int32 = 0
    private var isLoggingActive: Bool = false
    private let maxTotalLogSize: Int64 = 100 * 1024 * 1024 // 100MB
    
    private init() {
        // 创建日志目录路径
        let libraryPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!.path
        self.logsDirectory = "\(libraryPath)/Logs"

        // 设置日期格式器
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd"

        // 创建日志目录
        createLogsDirectoryIfNeeded()

        // 初始化时更新统计信息
        updateLogStatistics()

        // 冷启动时在后台自动清理日志
        performAutoCleanupOnColdStart()

        // 备份原始的 stdout 和 stderr
        self.originalStdout = dup(STDOUT_FILENO)
        self.originalStderr = dup(STDERR_FILENO)
    }
    
    deinit {
        stopLogging()
    }
    
    // MARK: - Public Methods
    
    /// 检查是否应该开启日志记录
    var shouldEnableLogging: Bool {
        // DEBUG 和 Release 模式下都可以开启日志记录
        return isLoggingEnabled
    }
    
    /// 开始日志记录
    func startLogging() {
        guard shouldEnableLogging && !isLoggingActive else {
            return
        }

        let logPath = getCurrentLogFilePath()

        // 重定向 stdout 和 stderr 到日志文件
        // Use UTF-8 (not ASCII) for the path to avoid a nil cString when
        // the sandbox container path contains a non-ASCII byte. Open each
        // stream independently — the previous && chain meant a failed
        // stderr redirect silently skipped the stdout one.
        let pathC = (logPath as NSString).utf8String
        let okErr = freopen(pathC, "a+", stderr) != nil
        let okOut = freopen(pathC, "a+", stdout) != nil
        if okErr || okOut {
            isLoggingActive = true
            currentLogFilePath = logPath

            // freopen on a non-TTY defaults to fully-buffered, so printf()
            // bytes can sit in an 8 KB block forever. Force line buffering
            // so every '\n' flushes to disk — that's what the "no logs to
            // read" UI report turned out to be.
            setvbuf(stdout, nil, _IOLBF, 0)
            setvbuf(stderr, nil, _IOLBF, 0)

            // 记录开始日志的时间戳
            print("=== Scrcpy Remote Log Started: \(Date()) ===")
            fflush(stdout); fflush(stderr)

            updateLogStatistics()
        }
    }
    
    /// 停止日志记录
    func stopLogging() {
        guard isLoggingActive else {
            return
        }

        // 记录结束日志的时间戳
        print("=== Scrcpy Remote Log Stopped: \(Date()) ===")
        fflush(stdout)
        fflush(stderr)

        // 恢复原始的 stdout 和 stderr
        dup2(originalStdout, STDOUT_FILENO)
        dup2(originalStderr, STDERR_FILENO)

        isLoggingActive = false
        currentLogFilePath = nil

        updateLogStatistics()
    }
    
    /// 切换日志记录状态
    func toggleLogging(_ enabled: Bool) {
        isLoggingEnabled = enabled
        
        if enabled {
            startLogging()
        } else {
            stopLogging()
        }
    }
    
    /// 获取当前生效的日志文件路径
    func getCurrentLogFilePath() -> String {
        if let currentPath = currentLogFilePath {
            return currentPath
        }
        
        let appVersion = getAppVersion()
        let currentDate = dateFormatter.string(from: Date())
        let fileName = "Scrcpy_Remote_\(appVersion)_\(currentDate).log"
        
        return "\(logsDirectory)/\(fileName)"
    }
    
    /// 获取本地日志文件列表
    func getLogFilesList() -> [LogFileInfo] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logsDirectory) else {
            return []
        }
        
        let logFiles = files.filter { $0.hasPrefix("Scrcpy_Remote_") && $0.hasSuffix(".log") }
        
        var logFileInfos: [LogFileInfo] = []
        
        for fileName in logFiles {
            let filePath = "\(logsDirectory)/\(fileName)"
            if let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
               let fileSize = attributes[.size] as? Int64,
               let modificationDate = attributes[.modificationDate] as? Date {
                
                let info = LogFileInfo(
                    fileName: fileName,
                    filePath: filePath,
                    fileSize: fileSize,
                    modificationDate: modificationDate,
                    isCurrentLog: filePath == getCurrentLogFilePath()
                )
                logFileInfos.append(info)
            }
        }
        
        // 按修改时间降序排列
        logFileInfos.sort { $0.modificationDate > $1.modificationDate }
        
        return logFileInfos
    }
    
    /// 读取当前最新的指定行数日志
    func readLatestLogs(lineCount: Int = 1000) -> String {
        // Flush stdio so freshly-printed lines actually reach the file
        // before we read it; without this, even with line buffering an
        // in-flight write can lag the disk view.
        if isLoggingActive {
            fflush(stdout)
            fflush(stderr)
        }

        let currentPath = getCurrentLogFilePath()

        guard FileManager.default.fileExists(atPath: currentPath) else {
            return "No log file found at: \(currentPath)"
        }

        guard let content = try? String(contentsOfFile: currentPath, encoding: .utf8) else {
            return "Failed to read log file"
        }

        let lines = content.components(separatedBy: .newlines)
        let recentLines = Array(lines.suffix(lineCount))

        return recentLines.joined(separator: "\n")
    }
    
    /// 读取指定日志文件的内容
    func readLogFile(_ filePath: String, lineCount: Int = 1000) -> String {
        if isLoggingActive && filePath == currentLogFilePath {
            fflush(stdout)
            fflush(stderr)
        }

        guard FileManager.default.fileExists(atPath: filePath) else {
            return "Log file not found"
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
            if let fileSize = attributes[.size] as? Int64, fileSize == 0 {
                return "" // Return empty string for empty file
            }
        } catch {
            // Ignore error, proceed to read
        }

        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return "Failed to read log file"
        }

        let lines = content.components(separatedBy: .newlines)
        let recentLines = Array(lines.suffix(lineCount))
        
        return recentLines.joined(separator: "\n")
    }
    
    /// 清理所有日志文件
    func clearAllLogs() -> Bool {
        let wasLogging = isLoggingActive
        if wasLogging {
            stopLogging()
        }
        
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logsDirectory) else {
            return false
        }
        
        let logFiles = files.filter { $0.hasPrefix("Scrcpy_Remote_") && $0.hasSuffix(".log") }
        
        var allDeleted = true
        for fileName in logFiles {
            let filePath = "\(logsDirectory)/\(fileName)"
            do {
                try FileManager.default.removeItem(atPath: filePath)
            } catch {
                allDeleted = false
                print("Failed to delete log file: \(fileName), error: \(error)")
            }
        }
        
        updateLogStatistics()
        
        if wasLogging {
            startLogging()
        }
        
        return allDeleted
    }
    
    /// 清理当前日志以外的所有日志文件
    func clearOldLogs() -> Bool {
        let currentLogPath = getCurrentLogFilePath()
        
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logsDirectory) else {
            return false
        }
        
        let logFiles = files.filter { $0.hasPrefix("Scrcpy_Remote_") && $0.hasSuffix(".log") }
        
        var allDeleted = true
        for fileName in logFiles {
            let filePath = "\(logsDirectory)/\(fileName)"
            if filePath != currentLogPath {
                do {
                    try FileManager.default.removeItem(atPath: filePath)
                } catch {
                    allDeleted = false
                    print("Failed to delete old log file: \(fileName), error: \(error)")
                }
            }
        }
        
        updateLogStatistics()
        
        return allDeleted
    }
    
    /// 删除指定的日志文件
    func deleteLogFile(_ filePath: String) -> Bool {
        let wasCurrentLog = filePath == currentLogFilePath
        
        if wasCurrentLog && isLoggingActive {
            stopLogging()
        }
        
        do {
            try FileManager.default.removeItem(atPath: filePath)
            updateLogStatistics()
            
            if wasCurrentLog && isLoggingEnabled {
                startLogging()
            }
            
            return true
        } catch {
            print("Failed to delete log file: \(filePath), error: \(error)")
            return false
        }
    }
    
    // MARK: - Private Methods
    
    private func createLogsDirectoryIfNeeded() {
        if !FileManager.default.fileExists(atPath: logsDirectory) {
            try? FileManager.default.createDirectory(atPath: logsDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    private func getAppVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
    
    private func updateLogStatistics() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let logFiles = self.getLogFilesList()
            let filesCount = logFiles.count
            let totalSize = logFiles.reduce(0) { $0 + $1.fileSize }

            let currentPath = self.getCurrentLogFilePath()
            let currentSize: Int64
            if FileManager.default.fileExists(atPath: currentPath),
               let attributes = try? FileManager.default.attributesOfItem(atPath: currentPath),
               let size = attributes[.size] as? Int64 {
                currentSize = size
            } else {
                currentSize = 0
            }

            DispatchQueue.main.async {
                self.logFilesCount = filesCount
                self.totalLogFilesSize = totalSize
                self.currentLogFileSize = currentSize
            }
        }
    }

    /// 冷启动时在后台自动清理日志
    private func performAutoCleanupOnColdStart() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            let logFiles = self.getLogFilesList()
            let totalSize = logFiles.reduce(0) { $0 + $1.fileSize }

            // 总是输出当前日志大小信息
            print("📊 Current log status: \(logFiles.count) file(s), total size: \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))")

            self.autoCleanupLogsIfNeeded(totalSize: totalSize, logFiles: logFiles)
        }
    }

    /// 当日志总大小超过限制时自动清理较老的日志
    private func autoCleanupLogsIfNeeded(totalSize: Int64, logFiles: [LogFileInfo]) {
        guard totalSize > maxTotalLogSize else {
            return
        }

        print("📦 Log size (\(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))) exceeds limit (\(ByteCountFormatter.string(fromByteCount: maxTotalLogSize, countStyle: .file))), cleaning up old logs...")

        let currentLogPath = getCurrentLogFilePath()
        // 按修改时间排序，最旧的在前
        let sortedFiles = logFiles.sorted { $0.modificationDate < $1.modificationDate }

        var currentTotalSize = totalSize
        var deletedCount = 0

        for logFile in sortedFiles {
            // 保留当前日志文件
            if logFile.filePath == currentLogPath {
                continue
            }

            // 如果已经低于限制，停止删除
            if currentTotalSize <= maxTotalLogSize {
                break
            }

            do {
                try FileManager.default.removeItem(atPath: logFile.filePath)
                currentTotalSize -= logFile.fileSize
                deletedCount += 1
                print("🗑️ Deleted old log: \(logFile.fileName) (\(logFile.formattedFileSize))")
            } catch {
                print("⚠️ Failed to delete old log file: \(logFile.fileName), error: \(error)")
            }
        }

        if deletedCount > 0 {
            print("✅ Auto-cleanup completed: deleted \(deletedCount) old log file(s), current size: \(ByteCountFormatter.string(fromByteCount: currentTotalSize, countStyle: .file))")
            // 重新更新统计信息
            DispatchQueue.main.async { [weak self] in
                self?.updateLogStatistics()
            }
        }
    }
}

// MARK: - LogFileInfo Structure

struct LogFileInfo: Identifiable {
    let id = UUID()
    let fileName: String
    let filePath: String
    let fileSize: Int64
    let modificationDate: Date
    let isCurrentLog: Bool
    
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: modificationDate)
    }
} 
