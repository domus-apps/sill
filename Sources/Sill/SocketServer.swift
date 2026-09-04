import Foundation

/* Unix-domain socket server the zsh sessions connect to. Plain BSD sockets
   with DispatchSources — Network.framework's unix-socket listener support
   is rough, and this is ~120 dependency-free lines.

   Everything is funneled onto the main queue: message rates are keystroke-
   scale, and the consumers (parser, popup) live on the main thread anyway. */
final class SocketServer {
    typealias ClientID = Int32

    var onMessage: ((ClientID, ShellMessage) -> Void)?
    var onDisconnect: ((ClientID) -> Void)?

    static let socketURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sill/sill.sock")

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [ClientID: Client] = [:]

    private final class Client {
        let fd: Int32
        let source: DispatchSourceRead
        var framer = LineFramer()
        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    func start() throws {
        let url = Self.socketURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        unlink(url.path)  // stale socket from a previous run

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = url.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, size)
            }
        }
        guard bound == 0, listen(listenFD, 16) == 0 else {
            close(listenFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        chmod(path, 0o600)  // same-user only

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        for (id, _) in clients { dropClient(id) }
        unlink(Self.socketURL.path)
    }

    func send(_ command: InsertCommand, to client: ClientID) {
        send(command.encoded(), to: client)
    }

    func send(_ command: PopupStateCommand, to client: ClientID) {
        send(command.encoded(), to: client)
    }


    private func send(_ data: Data, to client: ClientID) {
        guard clients[client] != nil else { return }
        let written = data.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        if written != data.count { dropClient(client) }
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        // A dying shell must not kill the app with SIGPIPE on write.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        clients[fd] = Client(fd: fd, source: source)
        source.setEventHandler { [weak self] in self?.readClient(fd) }
        source.resume()
    }

    private func readClient(_ fd: ClientID) {
        guard let client = clients[fd] else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else {
            dropClient(fd)
            return
        }
        for line in client.framer.consume(Data(buffer[0..<count])) {
            guard let message = ShellMessage.decode(line) else { continue }
            onMessage?(fd, message)
        }
    }

    private func dropClient(_ fd: ClientID) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        client.source.cancel()
        close(fd)
        onDisconnect?(fd)
    }
}
