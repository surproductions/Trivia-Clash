import Foundation
import MultipeerConnectivity
import UIKit

// MARK: - Wire protocol

enum WireProtocol {
    static let version = 2
    static let serviceType = "tclash" // must match NSBonjourServices in Info.plist

    static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? { try? JSONDecoder().decode(type, from: data) }
}

/// Guest → host. Guests can only ask; the host's engine decides.
enum ClientMessage: Codable, Equatable {
    case hello(playerId: String, name: String, avatar: Int, seen: [String], protocolVersion: Int)
    case setReady(ready: Bool)
    case setTeam(target: String, team: Int)
    /// `elapsedMs` is the reaction time measured on the guest's phone, from reveal
    /// to tap. The host only credits it within the measured network delay.
    case submit(round: Int, choice: Int, elapsedMs: Int64)
    /// Clock-sync probe from the guest (guest clock).
    case ping(sentAt: Int64)
    /// Reply to the host's latency probe (echoes the host clock).
    case pong(sentAt: Int64)
    case leave(reason: String)
}

/// Host → one guest. `state` carries only that guest's filtered view.
enum HostMessage: Codable, Equatable {
    case welcome(playerId: String, roomCode: String)
    case state(view: PlayerView)
    case submitResult(round: Int, outcome: SubmitOutcome)
    /// Reply to a guest's clock probe, carrying the host's clock at reply time.
    case pong(sentAt: Int64, hostNow: Int64)
    /// Latency probe from the host (host clock), echoed back by the guest.
    case ping(sentAt: Int64)
    case rejected(reason: String)
    case closed(reason: String)
}

/// Invitation context a guest sends so the host only admits players who typed
/// (or picked) its room code.
struct JoinContext: Codable {
    let code: String
    let protocolVersion: Int
}

// MARK: - Host transport

final class NearbyHostTransport: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate {
    let peer: MCPeerID
    let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let code: String

    var onMessage: ((MCPeerID, ClientMessage) -> Void)?
    var onPeerConnected: ((MCPeerID, Bool) -> Void)?
    var shouldAccept: (() -> Bool)?

    init(displayName: String, code: String) {
        self.code = code
        peer = MCPeerID(displayName: String(displayName.prefix(30)))
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peer,
                                               discoveryInfo: ["code": code, "host": String(displayName.prefix(30)),
                                                               "v": "\(WireProtocol.version)"],
                                               serviceType: WireProtocol.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
    }

    func startAdvertising() { advertiser.startAdvertisingPeer() }
    func stopAdvertising() { advertiser.stopAdvertisingPeer() }

    func stop() {
        advertiser.stopAdvertisingPeer()
        session.disconnect()
    }

    func send(_ message: HostMessage, to peers: [MCPeerID]) {
        let targets = peers.filter { session.connectedPeers.contains($0) }
        guard !targets.isEmpty, let data = WireProtocol.encode(message) else { return }
        try? session.send(data, toPeers: targets, with: .reliable)
    }

    // MCNearbyServiceAdvertiserDelegate
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let ctx = context.flatMap { WireProtocol.decode(JoinContext.self, from: $0) }
        DispatchQueue.main.async {
            let ok = ctx?.code == self.code && ctx?.protocolVersion == WireProtocol.version && (self.shouldAccept?() ?? true)
            invitationHandler(ok, ok ? self.session : nil)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {}

    // MCSessionDelegate
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected: self.onPeerConnected?(peerID, true)
            case .notConnected: self.onPeerConnected?(peerID, false)
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = WireProtocol.decode(ClientMessage.self, from: data) else { return }
        DispatchQueue.main.async { self.onMessage?(peerID, message) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Host session

/// The host's phone runs the authoritative engine and sends every guest its own
/// filtered view after each change. Guests' answers are timestamped on receipt
/// by the host's monotonic clock.
final class NearbyHostSession: EngineSession {
    private let transport: NearbyHostTransport
    private var peerToPlayer: [MCPeerID: String] = [:]
    /// Smoothed round-trip time to each guest, measured by the host itself.
    private var rttByPlayer: [String: Int64] = [:]
    private var probeTimer: Timer?
    /// Credit given to a guest whose latency hasn't been measured yet.
    private static let defaultCompensationMs: Int64 = 150

    init(profile: Profile, mode: GameMode, settings: MatchSettings, bank: QuestionBank, seen: Set<String>) {
        let engine = MatchEngine(mode: mode, settings: settings, timing: .nearby) { settings, allSeen, count in
            bank.pick(settings: settings, seen: allSeen, count: count)
        }
        transport = NearbyHostTransport(displayName: profile.name, code: engine.code)
        super.init(engine: engine, myId: profile.id)
        _ = try? engine.join(id: profile.id, name: profile.name, avatar: profile.avatar, seen: seen, now: Monotonic.nowMs())
        transport.shouldAccept = { [weak self] in
            guard let self else { return false }
            return self.engine.phase == .lobby ? self.engine.activePlayers.count < self.engine.maxPlayers : true
        }
        transport.onMessage = { [weak self] peer, message in self?.handle(message, from: peer) }
        transport.onPeerConnected = { [weak self] peer, connected in self?.peer(peer, connected: connected) }
        transport.startAdvertising()
        UIApplication.shared.isIdleTimerDisabled = true
        startTicking()
        let probe = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.probeLatency() }
        RunLoop.main.add(probe, forMode: .common)
        probeTimer = probe
    }

    private func probeLatency() {
        let peers = Array(peerToPlayer.keys)
        guard !peers.isEmpty else { return }
        transport.send(.ping(sentAt: Monotonic.nowMs()), to: peers)
    }

    /// The network delay credited to a guest's answer: their measured round trip
    /// plus a little slack, capped by the engine.
    private func compensation(for playerId: String) -> Int64 {
        guard let rtt = rttByPlayer[playerId] else { return Self.defaultCompensationMs }
        return rtt + 40
    }

    override var title: String { engine.mode.title }

    private func peer(_ peer: MCPeerID, connected: Bool) {
        guard !connected, let playerId = peerToPlayer.removeValue(forKey: peer) else { return }
        if !peerToPlayer.values.contains(playerId) { engine.setConnected(playerId, false) }
        pump()
    }

    private func handle(_ message: ClientMessage, from peer: MCPeerID) {
        let now = Monotonic.nowMs()
        if case let .hello(playerId, name, avatar, seen, version) = message {
            guard version == WireProtocol.version else {
                transport.send(.rejected(reason: "Please update Trivia Clasher to play together."), to: [peer])
                return
            }
            let cleanName = Profile.isValid(name) ? Profile.clean(name) : "Player"
            do {
                try engine.join(id: playerId, name: cleanName, avatar: min(max(avatar, 0), 11), seen: Set(seen.prefix(600)), now: now)
                // A device that reconnects may arrive with a new peer id; drop stale mappings.
                for (oldPeer, id) in peerToPlayer where id == playerId && oldPeer != peer { peerToPlayer.removeValue(forKey: oldPeer) }
                peerToPlayer[peer] = playerId
                engine.setConnected(playerId, true)
                transport.send(.welcome(playerId: playerId, roomCode: engine.code), to: [peer])
                transport.send(.state(view: engine.view(for: playerId, now: now)), to: [peer])
            } catch let error as EngineError {
                transport.send(.rejected(reason: GameSession.message(for: error)), to: [peer])
            } catch {}
            pump()
            return
        }
        guard let playerId = peerToPlayer[peer] else { return }
        switch message {
        case .hello:
            break
        case let .setReady(ready):
            try? engine.setReady(playerId, ready)
        case let .setTeam(target, team):
            do { try engine.setTeam(by: playerId, target: target, team: team) } catch let error as EngineError {
                transport.send(.rejected(reason: GameSession.message(for: error)), to: [peer])
            } catch {}
        case let .submit(round, choice, elapsedMs):
            if let outcome = try? engine.submit(playerId: playerId, round: round, choice: choice, now: now,
                                                reportedElapsedMs: max(0, elapsedMs),
                                                compensationMs: compensation(for: playerId)) {
                transport.send(.submitResult(round: round, outcome: outcome), to: [peer])
            }
        case let .ping(sentAt):
            transport.send(.pong(sentAt: sentAt, hostNow: Monotonic.nowMs()), to: [peer])
            return
        case let .pong(sentAt):
            let rtt = max(0, now - sentAt)
            if let previous = rttByPlayer[playerId] {
                // Rises slowly and falls fast, so one slow packet doesn't inflate the credit.
                rttByPlayer[playerId] = rtt < previous ? rtt : (previous * 3 + rtt) / 4
            } else {
                rttByPlayer[playerId] = rtt
            }
            return
        case .leave:
            engine.leave(playerId, now: now)
            peerToPlayer.removeValue(forKey: peer)
        }
        pump()
    }

    override func didChange(now: Int64) {
        for (peer, playerId) in peerToPlayer {
            transport.send(.state(view: engine.view(for: playerId, now: now)), to: [peer])
        }
        if engine.phase == .lobby { transport.startAdvertising() } else { transport.stopAdvertising() }
    }

    override func leave() {
        transport.send(.closed(reason: "The host ended the game."), to: Array(peerToPlayer.keys))
        probeTimer?.invalidate()
        stopTicking()
        engine.close()
        transport.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override func resume() {
        if engine.phase == .lobby { transport.startAdvertising() }
        pump()
    }

    deinit {
        probeTimer?.invalidate()
        transport.stop()
    }
}

// MARK: - Guest transport and discovery

struct NearbyRoom: Identifiable, Equatable {
    let peer: MCPeerID
    let code: String
    let hostName: String
    var id: String { "\(code)-\(peer.hash)" }
}

final class NearbyGuestTransport: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate {
    let peer: MCPeerID
    private(set) var session: MCSession
    private let browser: MCNearbyServiceBrowser
    private(set) var rooms: [NearbyRoom] = []

    var onRoomsChanged: (([NearbyRoom]) -> Void)?
    var onConnected: ((Bool) -> Void)?
    var onMessage: ((HostMessage) -> Void)?
    var onBrowseError: ((String) -> Void)?

    init(displayName: String) {
        peer = MCPeerID(displayName: String(displayName.prefix(30)))
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: WireProtocol.serviceType)
        super.init()
        session.delegate = self
        browser.delegate = self
    }

    func startBrowsing() { browser.startBrowsingForPeers() }
    func stopBrowsing() { browser.stopBrowsingForPeers() }

    func connect(to room: NearbyRoom) {
        // A fresh session for every attempt avoids stale connection state after drops.
        session.disconnect()
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        let context = WireProtocol.encode(JoinContext(code: room.code, protocolVersion: WireProtocol.version))
        browser.invitePeer(room.peer, to: session, withContext: context, timeout: 15)
    }

    func send(_ message: ClientMessage) {
        guard !session.connectedPeers.isEmpty, let data = WireProtocol.encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    func stop() {
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    // MCNearbyServiceBrowserDelegate
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let code = info?["code"], info?["v"] == "\(WireProtocol.version)" else { return }
        let room = NearbyRoom(peer: peerID, code: code, hostName: info?["host"] ?? peerID.displayName)
        DispatchQueue.main.async {
            self.rooms.removeAll { $0.peer == peerID }
            self.rooms.append(room)
            self.onRoomsChanged?(self.rooms)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.rooms.removeAll { $0.peer == peerID }
            self.onRoomsChanged?(self.rooms)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async {
            self.onBrowseError?("Nearby play needs Local Network access. Turn it on in Settings › Privacy › Local Network.")
        }
    }

    // MCSessionDelegate
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard session === self.session else { return }
        DispatchQueue.main.async {
            switch state {
            case .connected: self.onConnected?(true)
            case .notConnected: self.onConnected?(false)
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = WireProtocol.decode(HostMessage.self, from: data) else { return }
        DispatchQueue.main.async { self.onMessage?(message) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

/// Discovers nearby rooms for the Join screen.
final class NearbyBrowser: ObservableObject {
    @Published private(set) var rooms: [NearbyRoom] = []
    @Published var error: String?
    let transport: NearbyGuestTransport

    init(profile: Profile) {
        transport = NearbyGuestTransport(displayName: profile.name)
        transport.onRoomsChanged = { [weak self] rooms in self?.rooms = rooms.sorted { $0.hostName < $1.hostName } }
        transport.onBrowseError = { [weak self] message in self?.error = message }
    }

    func start() { transport.startBrowsing() }
    func stop() { transport.stopBrowsing() }

    func room(withCode code: String) -> NearbyRoom? { rooms.first { $0.code == code } }
}

// MARK: - Guest session

/// A guest never holds the answer key: it renders the host's views and sends
/// requests. If the connection drops it keeps looking for the same room and
/// rejoins with the same player id (the host restores the seat; the round
/// deadline is unaffected).
final class NearbyGuestSession: GameSession {
    private let transport: NearbyGuestTransport
    private let profile: Profile
    private let seen: [String]
    private(set) var roomCode: String
    private var pingTimer: Timer?
    private var reconnectDeadline: Date?
    private var everConnected = false
    private var closedByHost = false

    init(profile: Profile, room: NearbyRoom, transport: NearbyGuestTransport, seen: [String]) {
        self.transport = transport
        self.profile = profile
        self.seen = seen
        self.roomCode = room.code
        super.init(myId: profile.id)
        connection = .connecting
        transport.onConnected = { [weak self] connected in self?.connectionChanged(connected) }
        transport.onMessage = { [weak self] message in self?.handle(message) }
        transport.onRoomsChanged = { [weak self] rooms in self?.roomsChanged(rooms) }
        transport.startBrowsing()
        transport.connect(to: room)
        UIApplication.shared.isIdleTimerDisabled = true
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.heartbeat() }
        RunLoop.main.add(t, forMode: .common)
        pingTimer = t
    }

    override var title: String { view?.room.mode.title ?? "Nearby" }

    private func connectionChanged(_ connected: Bool) {
        if connected {
            everConnected = true
            reconnectDeadline = nil
            connection = .connected
            transport.send(.hello(playerId: profile.id, name: profile.name, avatar: profile.avatar,
                                  seen: Array(seen.suffix(300)), protocolVersion: WireProtocol.version))
            // A quick burst of clock probes so the shared reveal time is accurate
            // before the first question; the lowest-latency sample wins.
            for i in 0..<6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(i)) { [weak self] in
                    self?.transport.send(.ping(sentAt: Monotonic.nowMs()))
                }
            }
        } else if !closedByHost {
            if case .lost = connection { return }
            connection = everConnected ? .reconnecting : .connecting
            if reconnectDeadline == nil { reconnectDeadline = Date().addingTimeInterval(everConnected ? 60 : 20) }
            if let room = transport.rooms.first(where: { $0.code == roomCode }) { transport.connect(to: room) }
        }
    }

    private func roomsChanged(_ rooms: [NearbyRoom]) {
        guard connection == .reconnecting || connection == .connecting else { return }
        if let room = rooms.first(where: { $0.code == roomCode }) { transport.connect(to: room) }
    }

    private func heartbeat() {
        if connection == .connected {
            transport.send(.ping(sentAt: Monotonic.nowMs()))
        } else if let deadline = reconnectDeadline, Date() > deadline {
            connection = .lost(everConnected ? "Lost connection to the host." : "Couldn't reach that room.")
            transport.stop()
            pingTimer?.invalidate()
        }
    }

    private func handle(_ message: HostMessage) {
        let now = Monotonic.nowMs()
        switch message {
        case .welcome(_, let code):
            roomCode = code
        case .state(let newView):
            apply(newView, receivedAt: now)
        case let .submitResult(_, outcome):
            switch outcome.status {
            case .accepted, .alreadyAnswered: pendingChoice = outcome.choice
            case .tooLate:
                pendingChoice = nil
                notice = "Time's up — that answer reached the host too late."
            case .notActive: pendingChoice = nil
            }
        case let .pong(sentAt, hostNow):
            recordClockSample(sentAt: sentAt, authorityNow: hostNow, receivedAt: now)
        case .ping(let sentAt):
            transport.send(.pong(sentAt: sentAt))
        case .rejected(let reason):
            if view == nil {
                connection = .lost(reason)
                transport.stop()
            } else {
                notice = reason
            }
        case .closed(let reason):
            closedByHost = true
            connection = .lost(reason)
            transport.stop()
        }
    }

    override func submit(choice: Int) {
        guard let round = view?.round, pendingChoice == nil, !round.closed, isRevealed(round) else { return }
        pendingChoice = choice
        transport.send(.submit(round: round.no, choice: choice, elapsedMs: reactionMs(round)))
    }

    override func setReady(_ ready: Bool) { transport.send(.setReady(ready: ready)) }
    override func setTeam(target: String, team: Int) { transport.send(.setTeam(target: target, team: team)) }

    override func leave() {
        transport.send(.leave(reason: "left"))
        pingTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [transport] in transport.stop() }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override func resume() {
        if connection != .connected, !closedByHost {
            if case .lost = connection { return }
            transport.startBrowsing()
            if let room = transport.rooms.first(where: { $0.code == roomCode }) { transport.connect(to: room) }
        }
    }

    deinit { pingTimer?.invalidate() }
}
