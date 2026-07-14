import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.lucky.AgentDashboard", category: "HookServer")

class HookServer {
    enum RequestReadState: Equatable {
        case incomplete
        case complete
        case rejected(status: String)
    }

    static let maxHeaderBytes = 32 * 1024
    static let maxBodyBytes = 8 * 1024 * 1024

    private var listener: NWListener?
    private let port: UInt16 = 8765
    private let readTimeout: TimeInterval = 2
    var onEvent: ((@Sendable (HookEvent) -> Void))?

    func start() {
        guard listener == nil else {
            logger.debug("HookServer already started")
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            logger.error("Invalid port: \(self.port)")
            return
        }
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)

        let newListener: NWListener
        do {
            newListener = try NWListener(using: params)
        } catch {
            logger.warning("HookServer failed to create listener: \(error.localizedDescription)")
            return
        }
        listener = newListener
        // This is a decrementing delivery budget, not a concurrent-connection cap.
        // Each Claude hook opens a short-lived TCP connection, so a finite value would
        // permanently stop delivery after that many events even after connections close.
        newListener.newConnectionLimit = NWListener.InfiniteConnectionLimit

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            switch state {
            case .ready:
                logger.info("HookServer listening on 127.0.0.1:8765")
            case .failed(let error):
                logger.warning("HookServer listener failed: \(error.localizedDescription)")
                if let self, let newListener, self.listener === newListener {
                    self.listener = nil
                }
            case .cancelled:
                logger.info("HookServer stopped")
            default:
                break
            }
        }

        newListener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        let timeout = DispatchWorkItem { [weak connection] in
            connection?.cancel()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + readTimeout, execute: timeout)
        receiveData(on: connection, accumulated: Data(), timeout: timeout)
    }

    private func receiveData(on connection: NWConnection, accumulated: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else {
                timeout.cancel()
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let content = content {
                buffer.append(content)
            }

            switch Self.requestReadState(buffer) {
            case .complete:
                timeout.cancel()
                self.processRequest(data: buffer, connection: connection)
            case .rejected(let status):
                timeout.cancel()
                self.sendResponse(connection: connection, status: status)
            case .incomplete:
                if isComplete || error != nil {
                    timeout.cancel()
                    self.sendResponse(connection: connection, status: "400 Bad Request")
                } else {
                    self.receiveData(on: connection, accumulated: buffer, timeout: timeout)
                }
            }
        }
    }

    static func requestReadState(_ data: Data) -> RequestReadState {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return data.count > maxHeaderBytes
                ? .rejected(status: "431 Request Header Fields Too Large")
                : .incomplete
        }

        let headerBytes = data.distance(from: data.startIndex, to: headerRange.lowerBound)
        guard headerBytes <= maxHeaderBytes,
              let headers = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return .rejected(status: "431 Request Header Fields Too Large")
        }

        let contentLengthLine = headers.components(separatedBy: "\r\n").first {
            $0.lowercased().hasPrefix("content-length:")
        }
        guard let contentLengthLine,
              let colon = contentLengthLine.firstIndex(of: ":"),
              let contentLength = Int(contentLengthLine[contentLengthLine.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)),
              contentLength >= 0 else {
            return .rejected(status: "411 Length Required")
        }
        guard contentLength <= maxBodyBytes else {
            return .rejected(status: "413 Payload Too Large")
        }

        let bodyStart = data.distance(from: data.startIndex, to: headerRange.upperBound)
        return data.count >= bodyStart + contentLength ? .complete : .incomplete
    }

    private func processRequest(data: Data, connection: NWConnection) {
        defer { sendResponse(connection: connection, status: "200 OK") }

        guard let request = String(data: data, encoding: .utf8) else { return }

        let (method, path, body) = parseHTTPRequest(request)
        guard method == "POST", path.hasPrefix("/hook") else { return }

        let queryType = extractQueryParam(path: path, key: "type") ?? ""
        guard !queryType.isEmpty else { return }

        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return
        }

        if let event = HookEvent(queryType: queryType, json: json) {
            onEvent?(event)
        }
    }

    private func parseHTTPRequest(_ raw: String) -> (method: String, path: String, body: String) {
        let headerBodySplit = raw.components(separatedBy: "\r\n\r\n")
        let body = headerBodySplit.count > 1 ? headerBodySplit[1] : ""

        let firstLine = raw.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : ""
        let path = parts.count > 1 ? parts[1] : ""

        return (method, path, body)
    }

    private func extractQueryParam(path: String, key: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let query = String(path[path.index(after: queryStart)...])
        let pairs = query.components(separatedBy: "&")
        for pair in pairs {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2, kv[0] == key {
                return kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        return nil
    }

    private func sendResponse(connection: NWConnection, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        let data = response.data(using: .utf8) ?? Data()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
