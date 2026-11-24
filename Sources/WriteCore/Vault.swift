import CryptoKit
import Foundation

public enum VaultError: Error, LocalizedError, Equatable {
    case wrongPassword
    case wrongRecoveryKey
    case weakPassword
    case locked
    case corrupted
    case cryptoUnavailable
    case alreadyExists
    case notFound
    case duplicatePage
    case invalidPageNumber
    case invalidJournalName
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPassword: return "That password isn't right."
        case .wrongRecoveryKey: return "That recovery key isn't right."
        case .weakPassword: return "Use at least \(Vault.minimumPasswordLength) characters."
        case .locked: return "The journal is locked."
        case .corrupted: return "This data failed its integrity check, so it was not opened."
        case .cryptoUnavailable: return "Encryption is unavailable on this Mac."
        case .alreadyExists: return "A journal vault already exists here."
        case .notFound: return "That item no longer exists."
        case .duplicatePage: return "That page number is already saved in this journal."
        case .invalidPageNumber: return "Page numbers run from 1 to \(Vault.maximumPageNumber)."
        case .invalidJournalName: return "Give the journal a name."
        case .database(let message): return "The database reported a problem: \(message)"
        }
    }
}

public struct JournalInfo: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
}

public enum ReadingStatus: String, Codable, Sendable {
    case waiting
    case reading
    case done
    case failed
}

public struct PageInfo: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var journalID: UUID
    public var number: Int
    public var status: ReadingStatus
    public var problem: String?
    public var wasCutOff: Bool
    public let createdAt: Date
    public var updatedAt: Date
    /// Missing on pages read before entries and names were added.
    public var structure: PageStructure? = nil

    public init(id: UUID, journalID: UUID, number: Int, status: ReadingStatus, problem: String?, wasCutOff: Bool,
                createdAt: Date, updatedAt: Date, structure: PageStructure? = nil) {
        self.id = id
        self.journalID = journalID
        self.number = number
        self.status = status
        self.problem = problem
        self.wasCutOff = wasCutOff
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.structure = structure
    }
}

private struct AppSettings: Codable {
    var apiKey: String?
    var hiddenWords: [String]?
}

/// The encrypted journal database.
///
/// A random master key encrypts everything. The password and the recovery key each wrap a copy
/// of that key. Journal names, page numbers, text, photos, and the API key are all ciphertext at
/// rest. Page slots are keyed hashes, so SQLite can enforce unique page numbers without seeing them.
public final class Vault: @unchecked Sendable {
    public static let minimumPasswordLength = 10
    public static let maximumPageNumber = 99_999
    private static let format: Int64 = 1
    private static let fileName = "journal.vault"

    private struct Keys {
        let master: SymmetricKey
        let records: SymmetricKey
        let slots: SymmetricKey

        init(master: SymmetricKey) {
            self.master = master
            records = Crypto.subkey(master, purpose: "records")
            slots = Crypto.subkey(master, purpose: "slots")
        }
    }

    private struct Header {
        let salt: Data
        let iterations: Int
        let passwordWrap: Data
        let recoverySalt: Data
        let recoveryWrap: Data
    }

    private let lockObject = NSRecursiveLock()
    private let database: Database
    private var keys: Keys?

    private init(database: Database, keys: Keys) {
        self.database = database
        self.keys = keys
    }

    // MARK: - Opening

    public static func databaseURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    public static func exists(in directory: URL) -> Bool {
        let url = databaseURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path),
              let database = try? Database(path: url.path),
              let count = try? database.query("SELECT COUNT(*) FROM vault", map: { $0.int(0) }).first
        else { return false }
        return count == 1
    }

    public static func create(in directory: URL, password: String) throws -> (vault: Vault, recoveryKey: String) {
        guard password.count >= minimumPasswordLength else { throw VaultError.weakPassword }
        guard !exists(in: directory) else { throw VaultError.alreadyExists }

        let database = try openDatabase(in: directory)
        let master = SymmetricKey(data: try Crypto.randomBytes(32))
        let salt = try Crypto.randomBytes(16)
        let recoverySalt = try Crypto.randomBytes(16)
        let recovery = try Crypto.makeRecoveryKey()
        let masterBytes = master.withUnsafeBytes { Data($0) }

        let passwordKey = try Crypto.passwordKey(password, salt: salt, iterations: Crypto.defaultIterations)
        let passwordWrap = try Crypto.seal(
            masterBytes, key: passwordKey, context: wrapContext("password", salt, Crypto.defaultIterations)
        )
        let recoveryKey = Crypto.recoveryWrappingKey(recovery.bytes, salt: recoverySalt)
        let recoveryWrap = try Crypto.seal(masterBytes, key: recoveryKey, context: wrapContext("recovery", recoverySalt, 0))

        try database.run(
            """
            INSERT INTO vault (id, format, salt, iterations, password_wrap, recovery_salt, recovery_wrap)
            VALUES (1, ?, ?, ?, ?, ?, ?)
            """,
            [.int(format), .blob(salt), .int(Int64(Crypto.defaultIterations)), .blob(passwordWrap),
             .blob(recoverySalt), .blob(recoveryWrap)]
        )
        return (Vault(database: database, keys: Keys(master: master)), recovery.display)
    }

    public static func unlock(in directory: URL, password: String) throws -> Vault {
        let database = try openDatabase(in: directory)
        let header = try readHeader(database)
        let key = try Crypto.passwordKey(password, salt: header.salt, iterations: header.iterations)
        guard let masterBytes = try? Crypto.open(
            header.passwordWrap, key: key, context: wrapContext("password", header.salt, header.iterations)
        ) else { throw VaultError.wrongPassword }
        return Vault(database: database, keys: Keys(master: SymmetricKey(data: masterBytes)))
    }

    public static func unlock(in directory: URL, recoveryKey: String) throws -> Vault {
        guard let bytes = Crypto.parseRecoveryKey(recoveryKey) else { throw VaultError.wrongRecoveryKey }
        let database = try openDatabase(in: directory)
        let header = try readHeader(database)
        let key = Crypto.recoveryWrappingKey(bytes, salt: header.recoverySalt)
        guard let masterBytes = try? Crypto.open(
            header.recoveryWrap, key: key, context: wrapContext("recovery", header.recoverySalt, 0)
        ) else { throw VaultError.wrongRecoveryKey }
        return Vault(database: database, keys: Keys(master: SymmetricKey(data: masterBytes)))
    }

    public func lock() {
        locked { keys = nil }
    }

    public func changePassword(to password: String) throws {
        guard password.count >= Self.minimumPasswordLength else { throw VaultError.weakPassword }
        try locked {
            let keys = try requireKeys()
            let salt = try Crypto.randomBytes(16)
            let wrappingKey = try Crypto.passwordKey(password, salt: salt, iterations: Crypto.defaultIterations)
            let wrap = try Crypto.seal(
                keys.master.withUnsafeBytes { Data($0) },
                key: wrappingKey,
                context: Self.wrapContext("password", salt, Crypto.defaultIterations)
            )
            try database.run(
                "UPDATE vault SET salt = ?, iterations = ?, password_wrap = ? WHERE id = 1",
                [.blob(salt), .int(Int64(Crypto.defaultIterations)), .blob(wrap)]
            )
        }
    }

    private static func openDatabase(in directory: URL) throws -> Database {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = databaseURL(in: directory)
        let database = try Database(path: url.path)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return database
    }

    private static func readHeader(_ database: Database) throws -> Header {
        let rows = try database.query(
            "SELECT format, salt, iterations, password_wrap, recovery_salt, recovery_wrap FROM vault WHERE id = 1"
        ) { row -> Header in
            guard row.int(0) == format else { throw VaultError.corrupted }
            return Header(salt: row.blob(1), iterations: Int(row.int(2)), passwordWrap: row.blob(3),
                          recoverySalt: row.blob(4), recoveryWrap: row.blob(5))
        }
        guard let header = rows.first else { throw VaultError.notFound }
        return header
    }

    private static func wrapContext(_ kind: String, _ salt: Data, _ iterations: Int) -> String {
        "wrap/\(kind)/\(salt.base64EncodedString())/\(iterations)"
    }

    // MARK: - Settings

    public func apiKey() throws -> String? {
        try locked { try readSettings().apiKey }
    }

    public func setAPIKey(_ key: String?) throws {
        try updateSettings { $0.apiKey = key }
    }

    public func hiddenWords() throws -> Set<String> {
        try locked { Set(try readSettings().hiddenWords ?? []) }
    }

    public func setHiddenWords(_ words: Set<String>) throws {
        try updateSettings { $0.hiddenWords = words.sorted() }
    }

    private func updateSettings(_ change: (inout AppSettings) -> Void) throws {
        try locked {
            var settings = try readSettings()
            change(&settings)
            let keys = try requireKeys()
            let sealed = try Crypto.seal(try JSONEncoder().encode(settings), key: keys.records, context: "settings")
            try database.run(
                "INSERT INTO settings (id, record) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET record = excluded.record",
                [.blob(sealed)]
            )
        }
    }

    private func readSettings() throws -> AppSettings {
        let keys = try requireKeys()
        guard let sealed = try database.query("SELECT record FROM settings WHERE id = 1", map: { $0.blob(0) }).first else {
            return AppSettings(apiKey: nil)
        }
        return try decode(AppSettings.self, sealed, key: keys.records, context: "settings")
    }

    // MARK: - Journals

    public func journals() throws -> [JournalInfo] {
        try locked {
            let keys = try requireKeys()
            return try database.query("SELECT id, record FROM journals") { row -> JournalInfo in
                try decode(JournalInfo.self, row.blob(1), key: keys.records, context: "journal/\(row.string(0))")
            }
            .sorted { $0.createdAt < $1.createdAt }
        }
    }

    @discardableResult
    public func createJournal(name: String) throws -> JournalInfo {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultError.invalidJournalName }
        return try locked {
            let journal = JournalInfo(id: UUID(), name: trimmed, createdAt: Date())
            try database.run("INSERT INTO journals (id, record) VALUES (?, ?)",
                             [.text(Self.key(journal.id)), .blob(try sealJournal(journal))])
            return journal
        }
    }

    public func renameJournal(id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultError.invalidJournalName }
        try locked {
            guard var journal = try journals().first(where: { $0.id == id }) else { throw VaultError.notFound }
            journal.name = trimmed
            try database.run("UPDATE journals SET record = ? WHERE id = ?",
                             [.blob(try sealJournal(journal)), .text(Self.key(id))])
        }
    }

    public func deleteJournal(id: UUID) throws {
        try locked {
            let pageIDs = try pages().filter { $0.journalID == id }.map(\.id)
            try database.transaction {
                for pageID in pageIDs {
                    try database.run("DELETE FROM progress WHERE id = ?", [.text(Self.key(pageID))])
                    try database.run("DELETE FROM pages WHERE id = ?", [.text(Self.key(pageID))])
                }
                try database.run("DELETE FROM journals WHERE id = ?", [.text(Self.key(id))])
                guard database.changes > 0 else { throw VaultError.notFound }
            }
        }
    }

    private func sealJournal(_ journal: JournalInfo) throws -> Data {
        let keys = try requireKeys()
        return try Crypto.seal(try JSONEncoder().encode(journal), key: keys.records,
                               context: "journal/\(Self.key(journal.id))")
    }

    // MARK: - Pages

    public func pages() throws -> [PageInfo] {
        try locked {
            let keys = try requireKeys()
            return try database.query("SELECT id, record FROM pages") { row -> PageInfo in
                try decode(PageInfo.self, row.blob(1), key: keys.records, context: "page/\(row.string(0))/record")
            }
            .sorted { ($0.number, $0.createdAt) < ($1.number, $1.createdAt) }
        }
    }

    public func pageExists(journalID: UUID, number: Int) throws -> Bool {
        try locked {
            let slot = try slot(journalID: journalID, number: number)
            return try !database.query("SELECT 1 FROM pages WHERE slot = ?", [.blob(slot)]) { _ in true }.isEmpty
        }
    }

    /// Stores the photo before any network call, so a failed reading never loses a page.
    @discardableResult
    public func addPage(journalID: UUID, number: Int, jpeg: Data, replacing: Bool = false) throws -> PageInfo {
        guard (1...Self.maximumPageNumber).contains(number) else { throw VaultError.invalidPageNumber }
        return try locked {
            let keys = try requireKeys()
            guard try journals().contains(where: { $0.id == journalID }) else { throw VaultError.notFound }
            let slot = try slot(journalID: journalID, number: number)
            let now = Date()
            let page = PageInfo(id: UUID(), journalID: journalID, number: number, status: .waiting,
                                problem: nil, wasCutOff: false, createdAt: now, updatedAt: now)
            let id = Self.key(page.id)
            let record = try sealRecord(page)
            let body = try Crypto.seal(Data(), key: keys.records, context: "page/\(id)/body")
            let image = try Crypto.seal(jpeg, key: keys.records, context: "page/\(id)/image")

            try database.transaction {
                let taken = try !database.query("SELECT 1 FROM pages WHERE slot = ?", [.blob(slot)]) { _ in true }.isEmpty
                if taken && !replacing { throw VaultError.duplicatePage }
                if taken {
                    try database.run("DELETE FROM progress WHERE id IN (SELECT id FROM pages WHERE slot = ?)", [.blob(slot)])
                    try database.run("DELETE FROM pages WHERE slot = ?", [.blob(slot)])
                }
                try database.run(
                    "INSERT INTO pages (id, slot, record, body, image) VALUES (?, ?, ?, ?, ?)",
                    [.text(id), .blob(slot), .blob(record), .blob(body), .blob(image)]
                )
            }
            return page
        }
    }

    public func text(pageID: UUID) throws -> String {
        try locked {
            let keys = try requireKeys()
            let id = Self.key(pageID)
            guard let sealed = try database.query("SELECT body FROM pages WHERE id = ?", [.text(id)], map: { $0.blob(0) }).first else {
                throw VaultError.notFound
            }
            guard let plain = try? Crypto.open(sealed, key: keys.records, context: "page/\(id)/body"),
                  let text = String(data: plain, encoding: .utf8)
            else { throw VaultError.corrupted }
            return text
        }
    }

    public func image(pageID: UUID) throws -> Data {
        try locked {
            let keys = try requireKeys()
            let id = Self.key(pageID)
            guard let sealed = try database.query("SELECT image FROM pages WHERE id = ?", [.text(id)], map: { $0.blob(0) }).first else {
                throw VaultError.notFound
            }
            guard let plain = try? Crypto.open(sealed, key: keys.records, context: "page/\(id)/image") else {
                throw VaultError.corrupted
            }
            return plain
        }
    }

    public func setText(pageID: UUID, text: String, status: ReadingStatus? = nil, wasCutOff: Bool? = nil) throws {
        try locked {
            let keys = try requireKeys()
            var page = try page(id: pageID)
            if let status {
                page.status = status
                page.problem = nil
            }
            if let wasCutOff { page.wasCutOff = wasCutOff }
            page.updatedAt = Date()
            let id = Self.key(pageID)
            let body = try Crypto.seal(Data(text.utf8), key: keys.records, context: "page/\(id)/body")
            try database.run("UPDATE pages SET record = ?, body = ? WHERE id = ?",
                             [.blob(try sealRecord(page)), .blob(body), .text(id)])
        }
    }

    /// Saves a finished reading: its text plus the entries and names found on the page.
    public func saveReading(pageID: UUID, transcription: Transcription) throws {
        try locked {
            let keys = try requireKeys()
            var page = try page(id: pageID)
            page.status = .done
            page.problem = nil
            page.wasCutOff = transcription.wasCutOff
            page.structure = transcription.structure
            page.updatedAt = Date()
            let id = Self.key(pageID)
            let body = try Crypto.seal(Data(transcription.text.utf8), key: keys.records, context: "page/\(id)/body")
            try database.transaction {
                try database.run("UPDATE pages SET record = ?, body = ? WHERE id = ?",
                                 [.blob(try sealRecord(page)), .blob(body), .text(id)])
                // A finished reading replaces any reading saved partway.
                try database.run("DELETE FROM progress WHERE id = ?", [.text(id)])
            }
        }
    }

    /// Saves a reading on this Mac partway, so it can pick up where it stopped.
    public func saveProgress(pageID: UUID, progress: LocalReadProgress) throws {
        try locked {
            let keys = try requireKeys()
            let id = Self.key(pageID)
            _ = try page(id: pageID)
            let sealed = try Crypto.seal(try JSONEncoder().encode(progress), key: keys.records, context: "page/\(id)/progress")
            try database.run("INSERT OR REPLACE INTO progress (id, record) VALUES (?, ?)", [.text(id), .blob(sealed)])
        }
    }

    /// A reading on this Mac saved partway, if there is one.
    public func progress(pageID: UUID) throws -> LocalReadProgress? {
        try locked {
            let keys = try requireKeys()
            let id = Self.key(pageID)
            guard let sealed = try database.query("SELECT record FROM progress WHERE id = ?", [.text(id)], map: { $0.blob(0) }).first
            else { return nil }
            return try decode(LocalReadProgress.self, sealed, key: keys.records, context: "page/\(id)/progress")
        }
    }

    public func clearProgress(pageID: UUID) throws {
        try locked {
            _ = try requireKeys()
            try database.run("DELETE FROM progress WHERE id = ?", [.text(Self.key(pageID))])
        }
    }

    /// Pages with a reading on this Mac saved partway.
    public func pagesWithProgress() throws -> Set<UUID> {
        try locked {
            _ = try requireKeys()
            return Set(try database.query("SELECT id FROM progress") { UUID(uuidString: $0.string(0)) }.compactMap { $0 })
        }
    }

    /// Replaces the notes on words a reading on this Mac changed or wasn't sure of.
    public func setWordNotes(pageID: UUID, notes: [WordNote]) throws {
        try locked {
            var page = try page(id: pageID)
            guard page.structure != nil else { return }
            page.structure?.wordNotes = notes.isEmpty ? nil : notes
            try database.run("UPDATE pages SET record = ? WHERE id = ?",
                             [.blob(try sealRecord(page)), .text(Self.key(pageID))])
        }
    }

    public func setStatus(pageID: UUID, status: ReadingStatus, problem: String? = nil) throws {
        try locked {
            var page = try page(id: pageID)
            page.status = status
            page.problem = problem
            page.updatedAt = Date()
            try database.run("UPDATE pages SET record = ? WHERE id = ?",
                             [.blob(try sealRecord(page)), .text(Self.key(pageID))])
        }
    }

    public func movePage(id: UUID, toJournal journalID: UUID, number: Int) throws {
        guard (1...Self.maximumPageNumber).contains(number) else { throw VaultError.invalidPageNumber }
        try locked {
            guard try journals().contains(where: { $0.id == journalID }) else { throw VaultError.notFound }
            var page = try page(id: id)
            let newSlot = try slot(journalID: journalID, number: number)
            let holders = try database.query("SELECT id FROM pages WHERE slot = ?", [.blob(newSlot)]) { $0.string(0) }
            if let holder = holders.first, holder != Self.key(id) { throw VaultError.duplicatePage }
            page.journalID = journalID
            page.number = number
            page.updatedAt = Date()
            try database.run("UPDATE pages SET slot = ?, record = ? WHERE id = ?",
                             [.blob(newSlot), .blob(try sealRecord(page)), .text(Self.key(id))])
        }
    }

    public func deletePage(id: UUID) throws {
        try locked {
            _ = try requireKeys()
            try database.run("DELETE FROM progress WHERE id = ?", [.text(Self.key(id))])
            try database.run("DELETE FROM pages WHERE id = ?", [.text(Self.key(id))])
            guard database.changes > 0 else { throw VaultError.notFound }
        }
    }

    private func page(id: UUID) throws -> PageInfo {
        let keys = try requireKeys()
        let key = Self.key(id)
        guard let sealed = try database.query("SELECT record FROM pages WHERE id = ?", [.text(key)], map: { $0.blob(0) }).first else {
            throw VaultError.notFound
        }
        return try decode(PageInfo.self, sealed, key: keys.records, context: "page/\(key)/record")
    }

    private func sealRecord(_ page: PageInfo) throws -> Data {
        let keys = try requireKeys()
        return try Crypto.seal(try JSONEncoder().encode(page), key: keys.records,
                               context: "page/\(Self.key(page.id))/record")
    }

    private func slot(journalID: UUID, number: Int) throws -> Data {
        let keys = try requireKeys()
        let code = HMAC<SHA256>.authenticationCode(
            for: Data("\(Self.key(journalID))/\(number)".utf8), using: keys.slots
        )
        return Data(code)
    }

    // MARK: - Helpers

    private func requireKeys() throws -> Keys {
        guard let keys else { throw VaultError.locked }
        return keys
    }

    private func decode<T: Decodable>(_ type: T.Type, _ sealed: Data, key: SymmetricKey, context: String) throws -> T {
        guard let plain = try? Crypto.open(sealed, key: key, context: context),
              let value = try? JSONDecoder().decode(type, from: plain)
        else { throw VaultError.corrupted }
        return value
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lockObject.lock()
        defer { lockObject.unlock() }
        return try body()
    }

    private static func key(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}
