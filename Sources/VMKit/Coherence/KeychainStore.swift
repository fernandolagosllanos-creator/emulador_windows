import Foundation
#if canImport(Security)
import Security

/// Guarda la contraseña de Windows de cada VM en el llavero del Mac (solo la usa FreeRDP;
/// Windows App gestiona sus propias credenciales).
public enum KeychainStore {
    private static let service = "Paralelo"

    public static func password(for vmID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vmID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setPassword(_ password: String?, for vmID: UUID) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vmID.uuidString,
        ]
        SecItemDelete(base as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
#endif
