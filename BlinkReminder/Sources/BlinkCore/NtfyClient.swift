import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ntfy (https://ntfy.sh) 로 푸시 알림을 보낸다. JSON publish 를 써서 한글 제목/본문도 그대로 전달된다.
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

    struct Payload: Encodable {
        var topic: String
        var title: String
        var message: String
        var priority: Int
        var tags: [String]
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

    public func makeRequest(title: String, message: String, priority: Int, tags: [String]) throws -> URLRequest {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTopic.isEmpty else { throw NtfyError.emptyTopic }
        let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedServer), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw NtfyError.badServer
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        let payload = Payload(topic: trimmedTopic, title: title, message: message,
                              priority: min(5, max(1, priority)), tags: tags)
        req.httpBody = try JSONEncoder().encode(payload)
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
