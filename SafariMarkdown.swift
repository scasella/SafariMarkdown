// SafariMarkdown — Convert Safari pages to clean Markdown via Codex
// Day 6 · daily-macwidgets · 2026-02-23

import SwiftUI
import Network
import Security

// MARK: - Theme

enum SMTheme {
    static let bg = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let surface = Color(red: 0.16, green: 0.16, blue: 0.19)
    static let surfaceHover = Color(red: 0.20, green: 0.20, blue: 0.24)
    static let border = Color.white.opacity(0.08)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let accent = Color(red: 0.40, green: 0.65, blue: 1.0)
    static let success = Color(red: 0.30, green: 0.78, blue: 0.50)
    static let warning = Color(red: 1.0, green: 0.60, blue: 0.25)
    static let error = Color(red: 0.95, green: 0.35, blue: 0.35)
}

// MARK: - RawWebSocket (from CodexPilot)

class RawWebSocket {
    private var connection: NWConnection?
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "ws", qos: .userInitiated)

    var onMessage: ((String) -> Void)?
    var onConnect: (() -> Void)?
    var onDisconnect: ((String) -> Void)?

    private var handshakeComplete = false
    private var receiveBuffer = Data()

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func connect() {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.performHandshake()
            case .failed(let err):
                DispatchQueue.main.async { self?.onDisconnect?("Failed: \(err)") }
            case .cancelled:
                DispatchQueue.main.async { self?.onDisconnect?("Cancelled") }
            default: break
            }
        }
        connection?.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        handshakeComplete = false
        receiveBuffer = Data()
    }

    func send(_ text: String) {
        guard handshakeComplete else { return }
        let frame = encodeTextFrame(text)
        connection?.send(content: frame, completion: .contentProcessed({ _ in }))
    }

    private func performHandshake() {
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &keyBytes)
        let key = Data(keyBytes).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        connection?.send(content: request.data(using: .utf8)!, completion: .contentProcessed({ [weak self] err in
            if let err {
                DispatchQueue.main.async { self?.onDisconnect?("Handshake send failed: \(err)") }
                return
            }
            self?.readHandshakeResponse()
        }))
    }

    private func readHandshakeResponse() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, err in
            guard let self else { return }
            if let err {
                DispatchQueue.main.async { self.onDisconnect?("Handshake read failed: \(err)") }
                return
            }
            guard let data else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("101") && text.lowercased().contains("upgrade") {
                self.handshakeComplete = true
                DispatchQueue.main.async { self.onConnect?() }
                self.startReading()
            } else {
                DispatchQueue.main.async { self.onDisconnect?("Handshake rejected: \(text.prefix(100))") }
            }
        }
    }

    private func encodeTextFrame(_ text: String) -> Data {
        let payload = Array(text.utf8)
        var frame = Data()
        frame.append(0x81)
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len) | 0x80)
        } else if len < 65536 {
            frame.append(126 | 0x80)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127 | 0x80)
            for i in (0..<8).reversed() { frame.append(UInt8((len >> (i * 8)) & 0xFF)) }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mask)
        frame.append(contentsOf: mask)
        for (i, byte) in payload.enumerated() { frame.append(byte ^ mask[i % 4]) }
        return frame
    }

    private func startReading() {
        connection?.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, _, _, err in
            guard let self else { return }
            if let err {
                DispatchQueue.main.async { self.onDisconnect?("Read error: \(err)") }
                return
            }
            if let data {
                self.receiveBuffer.append(data)
                self.processFrames()
            }
            self.startReading()
        }
    }

    private func processFrames() {
        while receiveBuffer.count >= 2 {
            let b0 = receiveBuffer[0]
            let b1 = receiveBuffer[1]
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var payloadLen = Int(b1 & 0x7F)
            var offset = 2
            if payloadLen == 126 {
                guard receiveBuffer.count >= 4 else { return }
                payloadLen = Int(receiveBuffer[2]) << 8 | Int(receiveBuffer[3])
                offset = 4
            } else if payloadLen == 127 {
                guard receiveBuffer.count >= 10 else { return }
                payloadLen = 0
                for i in 0..<8 { payloadLen = (payloadLen << 8) | Int(receiveBuffer[2 + i]) }
                offset = 10
            }
            var maskKey: [UInt8] = []
            if masked {
                guard receiveBuffer.count >= offset + 4 else { return }
                maskKey = Array(receiveBuffer[offset..<offset+4])
                offset += 4
            }
            guard receiveBuffer.count >= offset + payloadLen else { return }
            var payload = Array(receiveBuffer[offset..<offset+payloadLen])
            if masked { for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] } }
            receiveBuffer = Data(receiveBuffer[(offset + payloadLen)...])
            switch opcode {
            case 0x1:
                if let text = String(bytes: payload, encoding: .utf8) {
                    DispatchQueue.main.async { self.onMessage?(text) }
                }
            case 0x8:
                DispatchQueue.main.async { self.onDisconnect?("Server closed connection") }
                return
            case 0x9:
                var pong = Data([0x8A])
                pong.append(UInt8(payload.count) | 0x80)
                var mask = [UInt8](repeating: 0, count: 4)
                _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mask)
                pong.append(contentsOf: mask)
                for (i, byte) in payload.enumerated() { pong.append(byte ^ mask[i % 4]) }
                connection?.send(content: pong, completion: .contentProcessed({ _ in }))
            default: break
            }
        }
    }
}

// MARK: - Safari Reader

struct SafariPage {
    let url: String
    let title: String
    let bodyText: String
}

struct ReaderError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { self.description = msg }
}

struct SafariReader {
    static func readCurrentPage() -> Result<SafariPage, ReaderError> {
        // Check if Safari is running
        let checkScript = NSAppleScript(source: """
            tell application "System Events"
                return (name of processes) contains "Safari"
            end tell
        """)
        var errorInfo: NSDictionary?
        let checkResult = checkScript?.executeAndReturnError(&errorInfo)
        if checkResult?.booleanValue != true {
            return .failure(ReaderError("Safari is not running. Open a page in Safari and try again."))
        }

        // Get URL
        let urlScript = NSAppleScript(source: """
            tell application "Safari"
                return URL of current tab of front window
            end tell
        """)
        errorInfo = nil
        guard let urlResult = urlScript?.executeAndReturnError(&errorInfo) else {
            let errMsg = (errorInfo?[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            return .failure(ReaderError("Could not read Safari URL: \(errMsg)"))
        }
        let url = urlResult.stringValue ?? ""

        // Get title
        let titleScript = NSAppleScript(source: """
            tell application "Safari"
                return name of current tab of front window
            end tell
        """)
        errorInfo = nil
        let titleResult = titleScript?.executeAndReturnError(&errorInfo)
        let title = titleResult?.stringValue ?? "Untitled"

        // Get body text via JavaScript
        let bodyScript = NSAppleScript(source: """
            tell application "Safari"
                return do JavaScript "document.body.innerText" in current tab of front window
            end tell
        """)
        errorInfo = nil
        guard let bodyResult = bodyScript?.executeAndReturnError(&errorInfo) else {
            let errMsg = (errorInfo?[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            return .failure(ReaderError("Could not read page content: \(errMsg). Make sure Safari > Settings > Advanced > 'Show features for web developers' is enabled."))
        }
        var bodyText = bodyResult.stringValue ?? ""

        if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(ReaderError("Page content is empty. The page may still be loading, or it may be a PDF/image."))
        }

        // Truncate to ~60K chars (~15K tokens)
        let maxChars = 60_000
        if bodyText.count > maxChars {
            bodyText = String(bodyText.prefix(maxChars)) + "\n\n[Content truncated at \(maxChars) characters]"
        }

        return .success(SafariPage(url: url, title: title, bodyText: bodyText))
    }
}

// MARK: - Conversion State

enum ConversionState: Equatable {
    case idle
    case readingPage
    case connecting
    case converting
    case done
    case error(String)
}

// MARK: - MarkdownConverter

@Observable
class MarkdownConverter {
    var state: ConversionState = .idle
    var markdownOutput = ""
    var sourceTitle = ""
    var sourceURL = ""
    var pageCharCount = 0

    private var ws: RawWebSocket?
    private var nextId = 1
    private var threadId: String?
    private var pendingRequests: [Int: String] = [:]

    var statusText: String {
        switch state {
        case .idle: return "Ready"
        case .readingPage: return "Reading Safari page..."
        case .connecting: return "Connecting to Codex server..."
        case .converting: return "Converting to Markdown..."
        case .done: return "Done — \(markdownOutput.count) chars"
        case .error(let msg): return msg
        }
    }

    var menuBarIcon: String {
        switch state {
        case .idle: return "doc.richtext"
        case .readingPage, .connecting: return "ellipsis.circle"
        case .converting: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    func convert() {
        guard state == .idle || state == .done || isError else { return }
        markdownOutput = ""
        threadId = nil
        nextId = 1
        pendingRequests = [:]

        state = .readingPage

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = SafariReader.readCurrentPage()
            DispatchQueue.main.async {
                switch result {
                case .success(let page):
                    self.sourceTitle = page.title
                    self.sourceURL = page.url
                    self.pageCharCount = page.bodyText.count
                    self.connectAndConvert(page: page)
                case .failure(let err):
                    self.state = .error(err.description)
                }
            }
        }
    }

    func cancel() {
        ws?.disconnect()
        ws = nil
        state = .idle
    }

    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdownOutput, forType: .string)
    }

    func reset() {
        ws?.disconnect()
        ws = nil
        markdownOutput = ""
        sourceTitle = ""
        sourceURL = ""
        pageCharCount = 0
        threadId = nil
        state = .idle
    }

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }

    // MARK: - Protocol

    private func connectAndConvert(page: SafariPage) {
        state = .connecting
        let socket = RawWebSocket(host: "127.0.0.1", port: 8080)

        socket.onConnect = { [weak self] in
            self?.sendInitialize()
        }

        socket.onMessage = { [weak self] msg in
            self?.handleMessage(msg, page: page)
        }

        socket.onDisconnect = { [weak self] reason in
            guard let self else { return }
            if case .converting = self.state {
                self.state = .error("Disconnected: \(reason)")
            } else if case .connecting = self.state {
                self.state = .error("Could not connect to Codex server. Is `codex-app-server --listen ws://127.0.0.1:8080` running?")
            }
        }

        ws = socket
        socket.connect()
    }

    private func rpcSend(method: String, params: Any) -> Int {
        let id = nextId
        nextId += 1
        pendingRequests[id] = method

        let msg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let text = String(data: data, encoding: .utf8) {
            ws?.send(text)
        }
        return id
    }

    private func rpcRespond(id: Any, result: Any) {
        let msg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let text = String(data: data, encoding: .utf8) {
            ws?.send(text)
        }
    }

    private func sendInitialize() {
        let params: [String: Any] = [
            "clientInfo": [
                "name": "SafariMarkdown",
                "version": "0.1.0"
            ]
        ]
        _ = rpcSend(method: "initialize", params: params)
    }

    private func sendThreadStart() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let params: [String: Any] = [
            "model": "gpt-5.3-codex-spark",
            "ephemeral": true,
            "cwd": home
        ]
        _ = rpcSend(method: "thread/start", params: params)
    }

    private func sendTurnStart(page: SafariPage) {
        guard let tid = threadId else { return }

        let prompt = """
        Convert the following web page content to clean, well-structured Markdown.

        Instructions:
        - Extract the MAIN article/content only. Skip navigation, sidebars, footers, ads, cookie banners, and boilerplate.
        - Use proper Markdown hierarchy: # for the title, ## for major sections, ### for subsections.
        - Preserve code blocks with language hints (```python, ```javascript, etc.) if present.
        - Preserve links as [text](url) where possible.
        - Use bullet lists and numbered lists where the original uses them.
        - For tables, use Markdown table syntax.
        - Keep the content faithful to the original — do not add commentary or summaries.
        - At the very end, add a source line: `> Source: [\(page.title)](\(page.url))`

        Page title: \(page.title)
        Page URL: \(page.url)

        --- PAGE CONTENT ---
        \(page.bodyText)
        --- END PAGE CONTENT ---
        """

        let params: [String: Any] = [
            "threadId": tid,
            "effort": "medium",
            "input": [
                [
                    "type": "text",
                    "text": prompt,
                    "textElements": [] as [Any]
                ]
            ]
        ]
        _ = rpcSend(method: "turn/start", params: params)
    }

    // Save page ref for use in message handler
    private var currentPage: SafariPage?

    private func handleMessage(_ text: String, page: SafariPage) {
        currentPage = page

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Response to our requests
        if let id = json["id"] as? Int, let method = pendingRequests[id] {
            pendingRequests.removeValue(forKey: id)

            if let error = json["error"] as? [String: Any] {
                let msg = error["message"] as? String ?? "Unknown error"
                state = .error("Server error (\(method)): \(msg)")
                return
            }

            let result = json["result"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                sendThreadStart()
            case "thread/start":
                if let thread = result["thread"] as? [String: Any],
                   let tid = thread["id"] as? String {
                    threadId = tid
                    state = .converting
                    sendTurnStart(page: page)
                } else {
                    state = .error("Failed to create thread")
                }
            default:
                break
            }
            return
        }

        // Server requests (approvals) — auto-accept
        if let id = json["id"], let method = json["method"] as? String {
            if method.contains("Approval") || method.contains("approval") ||
               method == "commandExecution" || method == "fileChange" {
                rpcRespond(id: id, result: ["decision": "accept"])
            }
            return
        }

        // Notifications
        if let method = json["method"] as? String {
            let params = json["params"] as? [String: Any] ?? [:]

            switch method {
            case "item/agentMessage/delta":
                if let delta = params["delta"] as? String {
                    markdownOutput += delta
                }

            case "turn/completed":
                state = .done
                ws?.disconnect()
                ws = nil

            case "turn/error":
                let msg = params["error"] as? String ?? "Turn failed"
                state = .error(msg)
                ws?.disconnect()
                ws = nil

            default:
                break
            }
        }
    }
}

// MARK: - Views

struct IdleView: View {
    let onConvert: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "safari")
                .font(.system(size: 36))
                .foregroundStyle(SMTheme.accent)

            Text("Safari → Markdown")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SMTheme.textPrimary)

            Text("Reads the current Safari tab and converts\nits content to clean Markdown via Codex.")
                .font(.system(size: 12))
                .foregroundStyle(SMTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Button(action: onConvert) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("Convert Current Page")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(SMTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 300)
    }
}

struct ProgressView2: View {
    let statusText: String

    var body: some View {
        VStack(spacing: 12) {
            SwiftUI.ProgressView()
                .controlSize(.small)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(SMTheme.textSecondary)
        }
        .padding(20)
        .frame(width: 300)
    }
}

struct ConvertingView: View {
    let converter: MarkdownConverter

    var body: some View {
        VStack(spacing: 0) {
            // Source header
            HStack(spacing: 6) {
                Image(systemName: "safari")
                    .font(.system(size: 11))
                    .foregroundStyle(SMTheme.accent)
                Text(converter.sourceTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SMTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if converter.state == .converting {
                    SwiftUI.ProgressView()
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SMTheme.surface)

            Divider().overlay(SMTheme.border)

            // Markdown output
            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(converter.markdownOutput.isEmpty ? "Waiting for response..." : converter.markdownOutput)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(converter.markdownOutput.isEmpty ? SMTheme.textSecondary : SMTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .onChange(of: converter.markdownOutput) { _, _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: 350)
            .background(SMTheme.bg)

            Divider().overlay(SMTheme.border)

            // Action bar
            HStack(spacing: 8) {
                if converter.state == .converting {
                    Text("\(converter.markdownOutput.count) chars")
                        .font(.system(size: 11))
                        .foregroundStyle(SMTheme.textSecondary)
                    Spacer()
                    Button("Cancel") { converter.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(SMTheme.warning)
                } else {
                    // Done state
                    Text("\(converter.markdownOutput.count) chars from \(converter.pageCharCount) source")
                        .font(.system(size: 11))
                        .foregroundStyle(SMTheme.textSecondary)
                    Spacer()
                    Button(action: { converter.reset() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("New")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(SMTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { converter.copyToClipboard() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(SMTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SMTheme.surface)
        }
        .frame(width: 420)
    }
}

struct ErrorView: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(SMTheme.error)

            Text("Conversion Failed")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SMTheme.textPrimary)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(SMTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            HStack(spacing: 8) {
                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.system(size: 12))
                        .foregroundStyle(SMTheme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(SMTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(SMTheme.border))
                }
                .buttonStyle(.plain)

                Button(action: onRetry) {
                    Text("Try Again")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(SMTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

struct ContentView: View {
    @Bindable var converter: MarkdownConverter

    var body: some View {
        VStack(spacing: 0) {
            switch converter.state {
            case .idle:
                IdleView(onConvert: { converter.convert() })

            case .readingPage, .connecting:
                ProgressView2(statusText: converter.statusText)

            case .converting, .done:
                ConvertingView(converter: converter)

            case .error(let msg):
                ErrorView(
                    message: msg,
                    onRetry: { converter.convert() },
                    onDismiss: { converter.reset() }
                )
            }

            // Footer
            HStack {
                Text("SafariMarkdown v0.1.0")
                    .font(.system(size: 10))
                    .foregroundStyle(SMTheme.textSecondary.opacity(0.5))
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(.system(size: 10))
                    .foregroundStyle(SMTheme.textSecondary.opacity(0.5))
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(SMTheme.surface.opacity(0.5))
        }
        .background(SMTheme.bg)
    }
}

// MARK: - App

@main
struct SafariMarkdownApp: App {
    @State private var converter = MarkdownConverter()

    var body: some Scene {
        MenuBarExtra {
            ContentView(converter: converter)
        } label: {
            Label {
                switch converter.state {
                case .done: Text("Done")
                default: Text("MD")
                }
            } icon: {
                Image(systemName: converter.menuBarIcon)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
