import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ntfy (https://ntfy.sh) 로 푸시 알림을 보낸다.
/// `POST https://server/topic` 에 본문을 메시지로 보내고 제목/우선순위/태그는 헤더로 전달한다.
/// 한글 제목은 RFC 2047 (=?UTF-8?B?...?=) 로 인코딩한다 (ntfy 가 지원).
public struct NtfyClient {
    public enum NtfyError: LocalizedError {
        case badServer
        case emptyTopic
        case http(Int, String)

        public var errorDescription: String? {
            switch self {
            case .badServer: return "서버 주소가 올바르지 않습니다 (예: https://ntfy.sh)"
            case .emptyTopic: return "주제(topic)를 입력하세요"
            case .http(let code, let body): return "서버 응답 \(code): \(body)"
            }
        }
    }

    public var server: String
    public var topic: String
    public var session: URLSession

    public init(server: String, topic: String, session: URLSession = .shared) {
        self.server = server
        self.topic = topic
        self.session = session
    }

    /// 주제 이름으로 쓸 무작위 문자열 (소문자+숫자 20자)
    public static func randomTopic(prefix: String = "blink") -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return prefix + "-" + String((0..<20).map { _ in chars.randomElement()! })
    }

    /// 서버 칸에 "https://ntfy.sh/내주제" 처럼 주제까지 붙여 넣어도 호스트만 쓴다.
    /// 주제 칸이 비어 있으면 서버 주소의 경로를 주제로 쓴다.
    public func resolved() throws -> (base: URL, topic: String) {
        var topicName = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        var serverText = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if serverText.isEmpty { serverText = "https://ntfy.sh" }
        if !serverText.contains("://") { serverText = "https://" + serverText }
        guard let url = URL(string: serverText), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else {
            throw NtfyError.badServer
        }
        let pathTopic = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if topicName.isEmpty, let last = pathTopic.last { topicName = last }
        guard !topicName.isEmpty else { throw NtfyError.emptyTopic }
        var base = "\(scheme)://\(host)"
        if let port = url.port { base += ":\(port)" }
        guard let baseURL = URL(string: base) else { throw NtfyError.badServer }
        return (baseURL, topicName)
    }

    /// 헤더에 넣을 수 없는 문자(한글 등)가 있으면 RFC 2047 로 인코딩한다.
    public static func headerValue(_ s: String) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
        if oneLine.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) { return oneLine }
        return "=?UTF-8?B?" + Data(oneLine.utf8).base64EncodedString() + "?="
    }

    public func makeRequest(title: String, message: String, priority: Int, tags: [String]) throws -> URLRequest {
        let (base, topicName) = try resolved()
        var req = URLRequest(url: base.appendingPathComponent(topicName))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.headerValue(title), forHTTPHeaderField: "Title")
        req.setValue(String(min(5, max(1, priority))), forHTTPHeaderField: "Priority")
        if !tags.isEmpty { req.setValue(tags.joined(separator: ","), forHTTPHeaderField: "Tags") }
        req.httpBody = Data(message.utf8)
        return req
    }

    public func send(title: String, message: String, priority: Int = 4, tags: [String] = ["eye"]) async throws {
        let req = try makeRequest(title: title, message: message, priority: priority, tags: tags)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NtfyError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
