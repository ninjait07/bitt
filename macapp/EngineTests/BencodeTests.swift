import Foundation

enum BencodeTests {
    static func run() {
        Check.section("Bencode")

        let roundTrips = ["i42e", "i-7e", "i0e", "4:spam", "0:", "le", "de",
                          "l4:spami3ee", "d3:cow3:moo4:spam4:eggse", "d1:ad1:bl1:ci1eeee"]
        for text in roundTrips {
            Check.equal("round trip \(text)",
                        try Bencode.decode(Data(ascii: text)).encoded().asciiString, text)
        }

        Check.equal("keys are sorted on encode",
                    Bencode.dictionary([Data(ascii: "b"): .integer(1),
                                        Data(ascii: "a"): .integer(2)]).encoded().asciiString,
                    "d1:ai2e1:bi1ee")

        for bad in ["i03e", "i-0e", "ie", "4:ab", "l", "d3:keye", "", "i1ex", "01:a", "d1:ae"] {
            Check.throwsError("rejects \(bad.isEmpty ? "(empty)" : bad)") {
                try Bencode.decode(Data(ascii: bad))
            }
        }

        Check.that("decodePrefix leaves trailing bytes") {
            let data = Data(ascii: "d1:ai1eeTRAILING")
            var index = data.startIndex
            let value = try Bencode.decodePrefix(data, from: &index)
            return value == .dictionary([Data(ascii: "a"): .integer(1)])
                && Data(data[index...]).asciiString == "TRAILING"
        }

        Check.that("binary strings survive untouched") {
            let payload = Data((0...255).map { UInt8($0) })
            let encoded = Bencode.string(payload).encoded()
            return try Bencode.decode(encoded).dataValue == payload
        }

        Check.that("subscript reads keys by name") {
            let value = try Bencode.decode(Data(ascii: "d4:name4:spam6:lengthi7ee"))
            return value["name"]?.stringValue == "spam" && value["length"]?.integerValue == 7
        }
    }
}
