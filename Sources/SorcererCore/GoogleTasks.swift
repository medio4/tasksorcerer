import Foundation

/// Minimal Google Tasks REST client (https://developers.google.com/workspace/tasks/reference/rest).
public final class GoogleTasksClient {
    static let base = URL(string: "https://tasks.googleapis.com/tasks/v1/")!
    public let auth: GoogleAuth
    private let session: URLSession

    public init(auth: GoogleAuth, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    public func lists() async throws -> [ListInfo] {
        var result: [ListInfo] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "100")]
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
            let json = try await request("GET", "users/@me/lists", query: query)
            for item in json["items"] as? [[String: Any]] ?? [] {
                if let id = item["id"] as? String {
                    result.append(ListInfo(id: id, title: item["title"] as? String ?? "(untitled)"))
                }
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return result
    }

    public func provider(listID: String, title: String) -> GoogleTasksListProvider {
        GoogleTasksListProvider(client: self, listID: listID, title: title)
    }

    @discardableResult
    func request(_ method: String, _ path: String, query: [URLQueryItem] = [],
                 body: [String: Any]? = nil) async throws -> [String: Any] {
        var comps = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        var attempt = 0
        while true {
            req.setValue("Bearer \(try await auth.token())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                if data.isEmpty { return [:] }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            }
            // Back off and retry on rate limiting and transient server errors.
            if (status == 429 || status >= 500) && attempt < 3 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                continue
            }
            throw SorcererError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

public final class GoogleTasksListProvider: TaskListProvider {
    let client: GoogleTasksClient
    public let listID: String
    public let displayName: String

    init(client: GoogleTasksClient, listID: String, title: String) {
        self.client = client
        self.listID = listID
        self.displayName = "Google: \(title)"
    }

    private var path: String { "lists/\(listID)/tasks" }

    public func fetchTasks() async throws -> [RawTask] {
        var result: [RawTask] = []
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "maxResults", value: "100"),
                URLQueryItem(name: "showCompleted", value: "true"),
                URLQueryItem(name: "showHidden", value: "true"),
            ]
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
            let json = try await client.request("GET", path, query: query)
            result += (json["items"] as? [[String: Any]] ?? []).compactMap(Self.parse)
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return result
    }

    public func create(_ task: RawTask) async throws -> RawTask {
        let json = try await client.request("POST", path, body: Self.body(task))
        guard let created = Self.parse(json) else { throw SorcererError.http(0, "unexpected create response") }
        return created
    }

    public func update(_ task: RawTask) async throws {
        try await client.request("PATCH", "\(path)/\(task.id)", body: Self.body(task))
    }

    public func delete(id: String) async throws {
        do {
            try await client.request("DELETE", "\(path)/\(id)")
        } catch SorcererError.http(404, _) {
            // Already gone.
        }
    }

    static func parse(_ json: [String: Any]) -> RawTask? {
        guard let id = json["id"] as? String, json["deleted"] as? Bool != true else { return nil }
        return RawTask(
            id: id,
            title: json["title"] as? String ?? "",
            notes: json["notes"] as? String ?? "",
            scheduled: (json["due"] as? String).flatMap(TaskDate.init(rfc3339DayPrefix:)),
            completed: json["status"] as? String == "completed",
            modified: (json["updated"] as? String).flatMap(parseTimestamp)
        )
    }

    static func body(_ task: RawTask) -> [String: Any] {
        var body: [String: Any] = [
            "title": task.title,
            "notes": task.notes.isEmpty ? NSNull() : task.notes as Any,
            // Google only keeps the date part of `due`.
            "due": task.scheduled.map { "\($0.dayKey)T00:00:00.000Z" } ?? NSNull(),
            "status": task.completed ? "completed" : "needsAction",
        ]
        if !task.completed { body["completed"] = NSNull() }
        return body
    }

    static func parseTimestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
