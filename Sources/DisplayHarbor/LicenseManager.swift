import CryptoKit
import Foundation
import Security

struct LicenseConfiguration {
    let appID: String
    let publicKey: String
    let purchaseURL: URL?

    static func fromBundle(_ bundle: Bundle = .main) -> LicenseConfiguration {
        let appID = (bundle.object(forInfoDictionaryKey: "MBDLicenseAppID") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = (bundle.object(forInfoDictionaryKey: "MBDLicensePublicKey") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let purchaseURLString = (bundle.object(forInfoDictionaryKey: "MBDLicensePurchaseURL") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return LicenseConfiguration(
            appID: appID,
            publicKey: publicKey,
            purchaseURL: purchaseURLString.isEmpty ? nil : URL(string: purchaseURLString)
        )
    }

    var isConfigured: Bool {
        !appID.isEmpty && !publicKey.isEmpty
    }
}

struct VerifiedLicense {
    let claims: [String: Any]
    let jws: String

    var planCode: String { claims["plan_code"] as? String ?? "" }
    var planName: String { claims["plan_name"] as? String ?? planCode }
    var expiry: Date? {
        guard let timestamp = claims["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: timestamp.doubleValue)
    }
}

enum LicenseError: LocalizedError {
    case notConfigured
    case missingCredential
    case invalidConfiguration(String)
    case keychain(OSStatus)
    case invalidCredential(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "授权商品尚未配置"
        case .missingCredential:
            return "请输入授权凭证"
        case .invalidConfiguration(let message):
            return message
        case .keychain(let status):
            return "无法访问 macOS 钥匙串（\(status)）"
        case .invalidCredential(let message):
            return message
        }
    }
}

private enum LicenseKeychain {
    // Keep a versioned namespace so items written by older development or
    // differently signed builds cannot make the shipped app's keychain reads
    // fail with errSecAuthFailed (-25293).
    static let service = "DisplayHarbor.license.v2"
    static let installationPrivateKey = "installation-private-key"
    static let certificate = "certificate"

    static func read(_ account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LicenseError.keychain(status) }
        return result as? Data
    }

    static func write(_ data: Data, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw LicenseError.keychain(updateStatus) }
        var addQuery = query
        addQuery[kSecValueData] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw LicenseError.keychain(addStatus) }
    }
}

enum LicenseVerifier {
    static func verify(
        _ jws: String,
        configuration: LicenseConfiguration,
        installationPublicKey: String? = nil
    ) throws -> VerifiedLicense {
        guard configuration.isConfigured else { throw LicenseError.notConfigured }
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = Data(base64URLEncoded: parts[0]),
              let payloadData = Data(base64URLEncoded: parts[1]),
              let signature = Data(base64URLEncoded: parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            throw LicenseError.invalidCredential("授权凭证格式无效")
        }

        guard header["alg"] as? String == "EdDSA",
              header["typ"] as? String == "JWT"
        else {
            throw LicenseError.invalidCredential("授权凭证签名算法不受支持")
        }

        guard let publicKeyData = Data(base64URLEncoded: configuration.publicKey),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        else {
            throw LicenseError.invalidConfiguration("授权公钥格式无效")
        }

        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard publicKey.isValidSignature(signature, for: signingInput) else {
            throw LicenseError.invalidCredential("授权凭证签名校验失败")
        }

        guard claims["iss"] as? String == "zhuankuai",
              claims["aud"] as? String == configuration.appID,
              claims["protocol"] as? String == "mbd-license-v1",
              let mode = claims["mode"] as? String,
              ["offline_signed", "activate_offline"].contains(mode),
              let planCode = claims["plan_code"] as? String,
              !planCode.isEmpty
        else {
            throw LicenseError.invalidCredential("授权凭证项目或协议不匹配")
        }

        if let expiry = (claims["exp"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expiry) <= Date() {
            throw LicenseError.invalidCredential("授权已过期")
        }

        if mode == "activate_offline" {
            guard let boundPublicKey = claims["installation_public_key"] as? String,
                  !boundPublicKey.isEmpty else {
                throw LicenseError.invalidCredential("设备证书缺少安装绑定")
            }
            let localPublicKey = try installationPublicKey ?? InstallationKeyStore.publicKey()
            guard boundPublicKey == localPublicKey else {
                throw LicenseError.invalidCredential("授权未绑定当前安装")
            }
        }

        return VerifiedLicense(claims: claims, jws: jws)
    }
}

private enum InstallationKeyStore {
    static func privateKey() throws -> Curve25519.Signing.PrivateKey {
        if let raw = try LicenseKeychain.read(LicenseKeychain.installationPrivateKey) {
            do { return try Curve25519.Signing.PrivateKey(rawRepresentation: raw) }
            catch { throw LicenseError.invalidCredential("本机安装密钥损坏") }
        }
        let key = Curve25519.Signing.PrivateKey()
        try LicenseKeychain.write(key.rawRepresentation, account: LicenseKeychain.installationPrivateKey)
        return key
    }

    static func publicKey() throws -> String {
        Base64URL.encode(try privateKey().publicKey.rawRepresentation)
    }
}

private enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        let padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .padding(toLength: ((value.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        self.init(base64Encoded: padded)
    }
}

@MainActor
final class LicenseManager {
    static let shared = LicenseManager()

    enum Status {
        case notConfigured
        case unlicensed
        case licensed(VerifiedLicense)
        case expired
        case error(String)
    }

    private(set) var status: Status = .unlicensed
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    let configuration: LicenseConfiguration

    private init(configuration: LicenseConfiguration = .fromBundle()) {
        self.configuration = configuration
        if !configuration.isConfigured { status = .notConfigured }
    }

    var isLicensed: Bool {
        if case .licensed = status { return true }
        return false
    }

    var displayName: String {
        switch status {
        case .notConfigured: return "未配置授权商品"
        case .unlicensed: return "未激活"
        case .licensed(let license): return license.planName
        case .expired: return "授权已过期"
        case .error: return "授权异常"
        }
    }

    var planCode: String? {
        guard case .licensed(let license) = status else { return nil }
        return license.planCode
    }

    var expiryText: String? {
        guard case .licensed(let license) = status, let expiry = license.expiry else { return nil }
        return DateFormatter.localizedString(from: expiry, dateStyle: .medium, timeStyle: .none)
    }

    func restore() {
        guard configuration.isConfigured else {
            status = .notConfigured
            onChange?()
            return
        }
        do {
            guard let certificateData = try LicenseKeychain.read(LicenseKeychain.certificate),
                  let certificate = String(data: certificateData, encoding: .utf8)
            else {
                status = .unlicensed
                lastError = nil
                onChange?()
                return
            }
            status = .licensed(try LicenseVerifier.verify(certificate, configuration: configuration))
            lastError = nil
        } catch {
            if case LicenseError.keychain = error {
                // A stale/inaccessible keychain item must not block the free
                // product. The user can paste the authorization code again.
                status = .unlicensed
                lastError = nil
            } else {
                status = (error as? LicenseError)?.localizedDescription == "授权已过期" ? .expired : .error(error.localizedDescription)
                lastError = error.localizedDescription
            }
        }
        onChange?()
    }

    func importLicense(_ rawCredential: String) {
        let credential = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard configuration.isConfigured else { throw LicenseError.notConfigured }
            guard !credential.isEmpty else { throw LicenseError.missingCredential }
            let verified = try LicenseVerifier.verify(credential, configuration: configuration)
            try LicenseKeychain.write(Data(credential.utf8), account: LicenseKeychain.certificate)
            status = .licensed(verified)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            status = .error(error.localizedDescription)
        }
        onChange?()
    }

    func savedLicenseCredential() -> String {
        guard let credentialData = try? LicenseKeychain.read(LicenseKeychain.certificate),
              let credential = String(data: credentialData, encoding: .utf8) else { return "" }
        return credential
    }
}
