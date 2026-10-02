import AppKit
import CoreImage
for path in CommandLine.arguments.dropFirst() {
    guard let image = CIImage(contentsOf: URL(fileURLWithPath: path)) else { print("\(path): unreadable"); continue }
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                              options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
    let found = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    print("\(path) -> \(found.isEmpty ? ["NOTHING DECODED"] : found)")
}
