import Foundation
import Network
import GuguKernel

/// 极简**只读**静态 HTTP 服务,把 blog 目录暴露在局域网(仅同一网络的设备可见)。
/// 手写、零依赖,基于 Network.framework。**默认不启动**,只在 modules.blog_lan 开时由模块拉起。
///
/// 隐私:只读、只服务 blog 目录、防目录穿越;不绑公网穿透。线程上所有状态只在自有
/// `queue` 上动,故标 @unchecked Sendable(满足项目的 complete 并发)。
final class BlogLANServer: @unchecked Sendable {
    private let directory: URL
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "gugu.blog.lan")
    private var listener: NWListener?

    init(directory: URL, port: UInt16) {
        self.directory = directory
        self.port = NWEndpoint.Port(rawValue: port) ?? 8420
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: port)
        l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// 对外展示的访问地址(局域网 IP + 端口)。取不到网卡 IP 时退回 localhost。
    var url: String {
        "http://\(BlogLANServer.localIPv4() ?? "localhost"):\(port.rawValue)"
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let path = data.flatMap { String(data: $0, encoding: .utf8) }.map(BlogLANServer.requestPath) ?? "/"
            let response = self.httpResponse(for: path)
            conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    /// 从 "GET /xxx?y HTTP/1.1" 取出路径(去掉查询串)。
    private static func requestPath(_ request: String) -> String {
        let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        return path.isEmpty ? "/" : path
    }

    private func httpResponse(for rawPath: String) -> Data {
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        var rel = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        if rel.isEmpty { rel = "index.html" }
        // 防目录穿越:任何 ".." 直接拒绝。
        if rel.contains("..") {
            return BlogLANServer.http(status: "403 Forbidden",
                                      type: "text/plain; charset=utf-8", body: Data("forbidden".utf8))
        }
        let fileURL = directory.appendingPathComponent(rel)
        guard let body = try? Data(contentsOf: fileURL) else {
            return BlogLANServer.http(status: "404 Not Found", type: "text/html; charset=utf-8",
                                      body: Data("<h1>404</h1><p><a href=\"/\">回首页</a></p>".utf8))
        }
        return BlogLANServer.http(status: "200 OK", type: BlogLANServer.contentType(for: fileURL), body: body)
    }

    private static func http(status: String, type: String, body: Data) -> Data {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "md", "txt": return "text/plain; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }

    /// 取本机第一个非回环 IPv4(优先 en0/en1,即 Wi‑Fi/有线),用于展示局域网访问地址。
    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let sa = ptr.pointee.ifa_addr else { continue }
            let addr = sa.pointee
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  (flags & IFF_LOOPBACK) == 0,
                  addr.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(addr.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
