import Foundation

struct ADBManifest: Codable, Sendable, Equatable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let platformToolsVersion: String
    let downloadURL: URL
    let archiveBytes: Int
    let sha256: String
    let licenseURL: URL
    let verifiedAt: Date

    init?(
        schemaVersion: Int,
        platformToolsVersion: String,
        downloadURL: URL,
        archiveBytes: Int,
        sha256: String,
        licenseURL: URL,
        verifiedAt: Date
    ) {
        guard schemaVersion == Self.supportedSchemaVersion,
              platformToolsVersion.range(
                of: #"^[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?$"#,
                options: .regularExpression
              ) != nil,
              downloadURL.scheme == "https",
              downloadURL.host == "dl.google.com",
              archiveBytes > 0,
              sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              licenseURL.scheme == "https" else {
            return nil
        }
        self.schemaVersion = schemaVersion
        self.platformToolsVersion = platformToolsVersion
        self.downloadURL = downloadURL
        self.archiveBytes = archiveBytes
        self.sha256 = sha256
        self.licenseURL = licenseURL
        self.verifiedAt = verifiedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        let platformToolsVersion = try values.decode(String.self, forKey: .platformToolsVersion)
        let downloadURL = try values.decode(URL.self, forKey: .downloadURL)
        let archiveBytes = try values.decode(Int.self, forKey: .archiveBytes)
        let sha256 = try values.decode(String.self, forKey: .sha256)
        let licenseURL = try values.decode(URL.self, forKey: .licenseURL)
        let verifiedAt = try values.decode(Date.self, forKey: .verifiedAt)
        guard let manifest = ADBManifest(
            schemaVersion: schemaVersion,
            platformToolsVersion: platformToolsVersion,
            downloadURL: downloadURL,
            archiveBytes: archiveBytes,
            sha256: sha256,
            licenseURL: licenseURL,
            verifiedAt: verifiedAt
        ) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid ADB manifest"
            ))
        }
        self = manifest
    }
}
