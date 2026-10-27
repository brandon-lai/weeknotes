import Contacts
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WeeknotesCore

/// Finds friends from the address book. Phone numbers are normalized to E.164 and hashed on
/// the phone; only hashes are sent (PRD §12, "Contact matching").
enum ContactsMatcher {
    static var status: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }

    static func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    /// Hashes of every phone number in the contacts the user shared with the app.
    nonisolated static func phoneHashes(region: String?) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let request = CNContactFetchRequest(keysToFetch: [CNContactPhoneNumbersKey as CNKeyDescriptor])
            request.unifyResults = false
            var hashes = Set<String>()
            try store.enumerateContacts(with: request) { contact, _ in
                for number in contact.phoneNumbers {
                    if let e164 = PhoneNumber.e164(number.value.stringValue, region: region) {
                        hashes.insert(PhoneNumber.hash(e164))
                    }
                }
            }
            return Array(hashes)
        }.value
    }

    static func findFriends(api: API) async throws -> [ContactMatch] {
        let hashes = try await phoneHashes(region: Locale.current.region?.identifier)
        var matches: [ContactMatch] = []
        for start in stride(from: 0, to: hashes.count, by: 3000) {
            matches += try await api.matchContacts(Array(hashes[start..<min(start + 3000, hashes.count)]))
        }
        return matches
    }
}

/// Photos are downscaled to 2048 px and re-encoded as JPEG without metadata, so location and
/// camera details never leave the phone.
nonisolated enum PhotoProcessor {
    struct Processed: Sendable {
        let data: Data
        let width: Int
        let height: Int
    }

    static func process(_ data: Data, maxPixel: Int = 2048, quality: Double = 0.82) -> Processed? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Processed(data: output as Data, width: image.width, height: image.height)
    }
}
