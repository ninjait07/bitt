import Foundation

let fixtures = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : nil
let pythonSeedPort = CommandLine.arguments.count > 2
    ? Int(CommandLine.arguments[2])
    : nil

BencodeTests.run()
MetainfoTests.run(fixtures: fixtures)
WireTests.run(fixtures: fixtures)
PiecesTests.run()
StorageTests.run(fixtures: fixtures)
TrackerTests.run(fixtures: fixtures)

StateTests.run()
await RateLimiterTests.run()

if let fixtures {
    await TransferTests.run(fixtures: fixtures)
    await TransferTests.resumeWhilePeersWait(fixtures: fixtures)
    await ManagerTests.run(fixtures: fixtures)
    if let pythonSeedPort {
        await TransferTests.crossCheck(fixtures: fixtures, pythonSeedPort: pythonSeedPort)
    }
}

exit(Check.summary())
