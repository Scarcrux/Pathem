import Foundation

#if canImport(Network)
    /// Requests a NAT-PMP port mapping from the home router so inbound peers can reach our
    /// listener. Finds the default gateway, asks it to forward our port, and re-maps before the
    /// lease expires. Best-effort: routers without NAT-PMP simply don't answer, and outbound
    /// connections (and seeding over them) work regardless.
    public actor NATPMPClient {
        private var refreshTask: Task<Void, Never>?

        public init() {}

        /// Map `port` (TCP) on the router to us, then keep it renewed. Returns the external port on
        /// the first success, or nil if no NAT-PMP gateway answered.
        @discardableResult
        public func mapTCP(port: UInt16) async -> UInt16? {
            guard let gateway = Self.defaultGateway() else { return nil }
            guard let first = await requestMapping(gateway: gateway, port: port, tcp: true) else { return nil }

            // Renew a bit before each lease expires.
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                var lifetime = first.lifetime
                while !Task.isCancelled {
                    let renewIn = max(60, UInt64(lifetime) / 2)
                    try? await Task.sleep(nanoseconds: renewIn * 1_000_000_000)
                    if Task.isCancelled { return }
                    guard let self, let result = await self.requestMapping(gateway: gateway, port: port, tcp: true)
                    else { continue }
                    lifetime = result.lifetime
                }
            }
            return first.externalPort
        }

        public func stop() {
            refreshTask?.cancel()
            refreshTask = nil
        }

        private func requestMapping(gateway: String, port: UInt16, tcp: Bool) async -> NATPMP.MapResult? {
            let request = NATPMP.mapRequest(internalPort: port, suggestedExternalPort: port, tcp: tcp)
            guard let reply = await UDP.query(host: gateway, port: 5351, payload: request, timeout: 3),
                let result = NATPMP.parseMapResponse(reply, tcp: tcp), result.ok
            else { return nil }
            return result
        }

        /// The default IPv4 gateway, via `route -n get default`. Nil if it can't be determined.
        static func defaultGateway() -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/route")
            process.arguments = ["-n", "get", "default"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("gateway:") {
                    return trimmed.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }
    }
#endif
