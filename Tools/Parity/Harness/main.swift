import Foundation

Task { @MainActor in
    let code = await ParityHarness.run(Array(CommandLine.arguments.dropFirst()))
    exit(code)
}
dispatchMain()
