import AppKit
import CoreImage

// The app already draws its PromptPay QR this way; same generator, same look.
let payload = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
let scale = CGFloat(Double(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "14")!)

let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue(Data(payload.utf8), forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
let rep = NSCIImageRep(ciImage: image)
let bitmap = NSImage(size: rep.size)
bitmap.addRepresentation(rep)
let tiff = bitmap.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) at \(Int(rep.size.width))px")
