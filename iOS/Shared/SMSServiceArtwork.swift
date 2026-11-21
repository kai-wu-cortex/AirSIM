import Foundation
import SwiftUI

// Presentation only: exact service-number artwork, never sender authentication.
// Adapted from PR #47 (2020cqyd), b8a9bac. See docs/SMSCarrierIcons.md.
enum SMSCarrierBrand: String, CaseIterable, Sendable {
    case mobile = "SMSCarrierMobile", unicom = "SMSCarrierUnicom", telecom = "SMSCarrierTelecom"
    case icbc = "SMSServiceICBC"
    case ccb = "SMSServiceCCB"
    case abc = "SMSServiceABC"
    case boc = "SMSServiceBOC"
    case bocom = "SMSServiceBOCOM"
    case sf = "SMSServiceSF"
    case jd = "SMSServiceJD"
    case zto = "SMSServiceZTO"
    case yto = "SMSServiceYTO"
    case cmb = "SMSServiceCMB", minsheng = "SMSServiceMinsheng"
    static func match(_ sender: String) -> SMSCarrierBrand? {
        let allowed = CharacterSet(charactersIn: "+0123456789 -()")
        let value = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !value.dropFirst().contains("+") else { return nil }
        var digits = value.filter { $0.isASCII && $0.isNumber }
        if value.hasPrefix("+86") { digits = String(digits.dropFirst(2)) }
        else if value.hasPrefix("0086") { digits = String(digits.dropFirst(4)) }
        else if value.hasPrefix("+") { return nil }
        switch digits {
        case "10086": return .mobile
        case "10010": return .unicom
        case "10000": return .telecom
        case "95588": return .icbc
        case "95533": return .ccb
        case "95599": return .abc
        case "95566": return .boc
        case "95559": return .bocom
        case "95338": return .sf
        case "950616": return .jd
        case "95311": return .zto
        case "95554": return .yto
        case "1069095599", "10690955998": return .abc
        case "106980095533": return .ccb
        case "95555", "1065795555", "106941995555", "106807695555", "10694395555", "106913595555", "106903695555", "106918195555", "1069170795555", "1069329095555", "1069411095555", "1068338795555", "1068078595555", "1068775395555", "1068486095555", "1068039095555", "106946895555", "1069208795555", "1069220695555", "106934095555", "106934795555", "1069210395555", "1069232695555", "1069101695555", "106904095555", "106903395555", "106929395555", "1068116095555", "106575595555", "1069118895555", "1068015195555", "106910095555", "1068455695555", "106935295555", "1069109695555", "1069057295555", "1069449695555", "1069249395555", "1069352995555", "106930095555", "106920095555", "1069100995555", "1069001995555", "106900795555": return .cmb
        case "95568", "106980095568", "10680195568", "10685095568", "106857695568", "106835195568", "1068071895568", "1069120695568", "106935595568", "1069161795568", "10691895568", "106901195568": return .minsheng
        default: return nil
        }
    }
}

struct SMSServiceArtwork: View {
    let brand: SMSCarrierBrand
    var size: CGFloat = 32

    var body: some View {
        Image(brand.rawValue)
            .resizable()
            .scaledToFit()
            .padding(size * 0.16)
            .frame(width: size, height: size)
            .background(Color.white, in: Circle())
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
