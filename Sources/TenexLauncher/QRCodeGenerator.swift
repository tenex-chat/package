import AppKit
import CoreImage.CIFilterBuiltins

enum QRCodeGenerator {
    static func generate(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }

    static func mobileSetupURL(nsec: String, relay: String?, backendPubkey: String?) -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tenex.chat"
        components.path = "/signin"
        var items = [URLQueryItem(name: "nsec", value: nsec)]
        if let relay { items.append(URLQueryItem(name: "relay", value: relay)) }
        if let backendPubkey { items.append(URLQueryItem(name: "backend", value: backendPubkey)) }
        components.queryItems = items
        return components.url?.absoluteString ?? ""
    }
}
