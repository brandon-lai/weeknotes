import CryptoKit
import Foundation

/// Contact matching sends only hashes of E.164 numbers; the raw numbers never leave the phone.
/// The server hashes once more with a secret pepper before comparing, so a leaked table can't
/// be reversed by enumerating every phone number.
public enum PhoneNumber {
    /// E.164 ("+14155550101") from however a contact stored it, or nil when it can't be a
    /// real number. `region` is the device's region, used for numbers written without a
    /// country code.
    public static func e164(_ raw: String, region: String?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Extensions ("x204", ";ext=") aren't part of the number
        let main = trimmed.split(whereSeparator: { "xX;,#".contains($0) }).first.map(String.init) ?? trimmed
        let digits = main.filter(\.isNumber).compactMap { $0.wholeNumberValue.map(String.init) }.joined()
        guard !digits.isEmpty else { return nil }

        var international: String
        if main.hasPrefix("+") {
            international = digits
        } else if digits.hasPrefix("00") {
            international = String(digits.dropFirst(2))
        } else if digits.hasPrefix("011"), region.map(nanpRegions.contains) ?? false {
            international = String(digits.dropFirst(3))
        } else {
            guard let region = region?.uppercased(), let code = callingCodes[region] else { return nil }
            if code == "1" {
                if digits.count == 10 {
                    international = "1" + digits
                } else if digits.count == 11 && digits.hasPrefix("1") {
                    international = digits
                } else {
                    return nil
                }
            } else {
                // Drop the national trunk prefix ("07700 900123" → "7700900123")
                let national = digits.hasPrefix("0") ? String(digits.dropFirst()) : digits
                international = code + national
            }
        }
        if international.hasPrefix("1") && international.count != 11 { return nil }
        guard (8...15).contains(international.count) else { return nil }
        return "+" + international
    }

    /// Lowercase hex SHA-256 of an E.164 string. Postgres computes the same thing from the
    /// verified phone on `auth.users` (`private.phone_digest`).
    public static func hash(_ e164: String) -> String {
        SHA256.hash(data: Data(e164.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static let nanpRegions: Set<String> = ["US", "CA", "PR", "GU", "VI", "AS", "MP", "BS", "BB", "JM", "TT", "DO", "AG", "BM", "KY", "DM", "GD", "KN", "LC", "VC", "TC", "VG", "AI", "MS", "SX"]

    /// Country calling codes by ISO region, for numbers saved without a "+".
    static let callingCodes: [String: String] = {
        var codes: [String: String] = [
            "GB": "44", "IE": "353", "FR": "33", "DE": "49", "ES": "34", "IT": "39", "PT": "351", "NL": "31", "BE": "32",
            "CH": "41", "AT": "43", "SE": "46", "NO": "47", "DK": "45", "FI": "358", "IS": "354", "PL": "48", "CZ": "420",
            "SK": "421", "HU": "36", "RO": "40", "BG": "359", "GR": "30", "TR": "90", "UA": "380", "RU": "7", "IL": "972",
            "AE": "971", "SA": "966", "QA": "974", "EG": "20", "MA": "212", "NG": "234", "GH": "233", "KE": "254",
            "ZA": "27", "ET": "251", "IN": "91", "PK": "92", "BD": "880", "LK": "94", "NP": "977", "CN": "86", "HK": "852",
            "TW": "886", "JP": "81", "KR": "82", "SG": "65", "MY": "60", "TH": "66", "VN": "84", "PH": "63", "ID": "62",
            "AU": "61", "NZ": "64", "MX": "52", "BR": "55", "AR": "54", "CL": "56", "CO": "57", "PE": "51", "VE": "58",
            "EC": "593", "UY": "598", "CR": "506", "PA": "507", "GT": "502", "SV": "503", "HN": "504", "NI": "505",
            "CU": "53", "LU": "352", "MT": "356", "CY": "357", "EE": "372", "LV": "371", "LT": "370", "HR": "385",
            "SI": "386", "RS": "381", "BA": "387", "AL": "355", "MK": "389", "GE": "995", "AM": "374", "AZ": "994",
            "KZ": "7", "UZ": "998", "JO": "962", "LB": "961", "KW": "965", "BH": "973", "OM": "968", "IR": "98", "IQ": "964",
        ]
        for region in nanpRegions { codes[region] = "1" }
        return codes
    }()
}
