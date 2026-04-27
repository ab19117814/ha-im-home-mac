import CoreBluetooth
import CryptoKit
import Foundation

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

func log(_ msg: String) {
    print(msg)
    fflush(stdout)
}

// MARK: - Config (/Library/Application Support/ImHome/imhome.json)

private let kWindowSec: Int64 = 30
private let kConfigPath = "/Library/Application Support/ImHome/imhome.json"

struct ImHomeConfigResponse: Codable {
    var users: [ImHomeUser]
    var service_uuid: String?
    var write_uuid: String?
}

struct ImHomeUser: Codable {
    var name: String
    var secret: String
}

struct ImHomeConfig: Codable {
    var ha_url: String
    var ha_token: String
    var service_uuid: String?   // generated once, unique per installation
    var write_uuid: String?

    var notifyURL: String { "\(ha_url)/api/ha_im_home/arrived" }
    var configURL:  String { "\(ha_url)/api/ha_im_home/config" }
}

func loadConfig() -> ImHomeConfig? {
    guard let data = FileManager.default.contents(atPath: kConfigPath),
          var cfg  = try? JSONDecoder().decode(ImHomeConfig.self, from: data)
    else {
        log("⚠️  Config not found. Create \(kConfigPath):")
        log("""
        {
          "ha_url":   "http://homeassistant.local:8123",
          "ha_token": "eyJ0eXAi..."
        }
        """)
        return nil
    }

    // Generate unique UUIDs on first run — stored permanently in config
    var dirty = false
    if cfg.service_uuid == nil {
        cfg.service_uuid = UUID().uuidString
        dirty = true
    }
    if cfg.write_uuid == nil {
        cfg.write_uuid = UUID().uuidString
        dirty = true
    }
    if dirty {
        if let updated = try? JSONEncoder().encode(cfg) {
            try? updated.write(to: URL(fileURLWithPath: kConfigPath))
            log("[CFG] Generated unique BLE UUIDs for this installation")
        }
    }
    return cfg
}

// Fetch users from HA synchronously (called at startup before RunLoop)
func fetchUsers(cfg: ImHomeConfig) -> [ImHomeUser] {
    guard let url = URL(string: cfg.configURL) else { return [] }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.setValue("Bearer \(cfg.ha_token)", forHTTPHeaderField: "Authorization")

    let sem = DispatchSemaphore(value: 0)
    var result: [ImHomeUser] = []

    URLSession.shared.dataTask(with: req) { data, resp, error in
        defer { sem.signal() }
        if let error {
            log("⚠️  fetchUsers error: \(error.localizedDescription)")
            return
        }
        guard let http = resp as? HTTPURLResponse else {
            log("⚠️  fetchUsers: not HTTP response")
            return
        }
        log("[DBG] HTTP status: \(http.statusCode)")
        guard http.statusCode == 200 else {
            log("⚠️  fetchUsers: bad status \(http.statusCode)")
            return
        }
        guard let data else {
            log("⚠️  fetchUsers: no data")
            return
        }
        log("[DBG] Raw response: \(String(data: data, encoding: .utf8) ?? "nil")")
        guard let json = try? JSONDecoder().decode(ImHomeConfigResponse.self, from: data) else {
            log("⚠️  fetchUsers: JSON decode failed")
            return
        }
        let users = json.users
        result = users
        log("[CFG] Loaded \(users.count) user(s): \(users.map(\.name).joined(separator: ", "))")
    }.resume()

    sem.wait()
    return result
}

// MARK: - Daemon

final class ImHomeDaemon: NSObject, CBPeripheralManagerDelegate {
    private var manager:   CBPeripheralManager!
    private var writeChar: CBMutableCharacteristic!
    private var usedNonces: Set<String> = []
    private var users: [ImHomeUser] = []
    private var cfg: ImHomeConfig!

    private let serviceUUID: CBUUID
    private let writeUUID: CBUUID

    init(cfg: ImHomeConfig, users: [ImHomeUser]) {
        self.cfg         = cfg
        self.users       = users
        self.serviceUUID = CBUUID(string: cfg.service_uuid!)
        self.writeUUID   = CBUUID(string: cfg.write_uuid!)
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .global(qos: .userInitiated))
        // Refresh users from HA every 5 minutes, clear nonce cache
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            let fresh = fetchUsers(cfg: self.cfg)
            if !fresh.isEmpty { self.users = fresh }
            self.usedNonces.removeAll()
        }
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            log("[BLE] Bluetooth ready — publishing service")
            setupService()
        case .poweredOff:
            log("[BLE] Bluetooth off")
        case .unauthorized:
            log("[BLE] No Bluetooth permission")
        default:
            log("[BLE] State: \(peripheral.state.rawValue)")
        }
    }

    private func setupService() {
        writeChar = CBMutableCharacteristic(
            type: writeUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [writeChar]
        manager.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            log("[BLE] Service error: \(error)")
            return
        }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey:    "ImHome",
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            log("[BLE] Advertising error: \(error)")
        } else {
            log("[BLE] Advertising — waiting for iPhone ✅")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            guard req.characteristic.uuid == writeUUID,
                  let data = req.value, data.count == 40
            else {
                peripheral.respond(to: req, withResult: .invalidAttributeValueLength)
                log("[BLE] Bad write: \(req.value?.count ?? 0) bytes")
                continue
            }
            peripheral.respond(to: req, withResult: .success)
            handleArrival(data)
        }
    }

    // MARK: Auth

    // Payload: timestamp (8 bytes BE Int64) + HMAC-SHA256(timestamp, secret) (32 bytes)
    private func handleArrival(_ data: Data) {
        let tsData = data.prefix(8)
        let rxHMAC = data.suffix(32)

        // 1. Timestamp window ±30s
        let ts  = tsData.withUnsafeBytes { $0.load(as: Int64.self).bigEndian }
        let now = Int64(Date().timeIntervalSince1970)
        guard abs(now - ts) <= kWindowSec else {
            log("[AUTH] Stale timestamp: \(abs(now - ts))s")
            return
        }

        // 2. Replay protection
        let nonceKey = tsData.hexString
        guard !usedNonces.contains(nonceKey) else {
            log("[AUTH] Replay detected")
            return
        }
        usedNonces.insert(nonceKey)

        // 3. Try each user's HMAC
        for user in users {
            let key      = SymmetricKey(data: Data(user.secret.utf8))
            let expected = Data(HMAC<SHA256>.authenticationCode(for: tsData, using: key))
            if Data(rxHMAC) == expected {
                log("[AUTH] OK — user: \(user.name)")
                notifyHA(userName: user.name)
                return
            }
        }
        log("[AUTH] HMAC mismatch — no matching user")
    }

    private func notifyHA(userName: String) {
        guard let url = URL(string: cfg.notifyURL) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cfg.ha_token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["user": userName])
        URLSession.shared.dataTask(with: req) { _, resp, error in
            if let error {
                log("[HA] Error: \(error.localizedDescription)")
            } else if let http = resp as? HTTPURLResponse {
                log("[HA] \(http.statusCode == 200 ? "✅" : "⚠️") HTTP \(http.statusCode)")
            }
        }.resume()
    }
}

func registerWithHA(cfg: ImHomeConfig) {
    guard let url = URL(string: "\(cfg.ha_url)/api/ha_im_home/register") else { return }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(cfg.ha_token)", forHTTPHeaderField: "Authorization")
    req.httpBody = try? JSONSerialization.data(withJSONObject: [
        "service_uuid": cfg.service_uuid!,
        "write_uuid":   cfg.write_uuid!,
    ])

    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, resp, error in
        defer { sem.signal() }
        if let error {
            log("[CFG] Register error: \(error.localizedDescription)")
        } else if let http = resp as? HTTPURLResponse {
            log("[CFG] Registered with HA (\(http.statusCode == 200 ? "✅" : "⚠️ HTTP \(http.statusCode)"))")
        }
    }.resume()
    sem.wait()
}

// MARK: - Entry point

guard let cfg = loadConfig() else { exit(1) }
log("HA Im Home daemon starting — config: \(kConfigPath)")
log("[CFG] service UUID: \(cfg.service_uuid!)")
log("[CFG] Fetching users from HA…")
let initialUsers = fetchUsers(cfg: cfg)
guard !initialUsers.isEmpty else {
    log("⚠️  No users loaded — check ha_url and ha_token in \(kConfigPath)")
    exit(1)
}
registerWithHA(cfg: cfg)
let daemon = ImHomeDaemon(cfg: cfg, users: initialUsers)
RunLoop.main.run()
