import AppKit
import Darwin

#if BUNDLED_SPEECH
if CommandLine.arguments.contains("--wemm-eval") {
    Task {
        let status = await WeMMEmbeddingCLI.run(arguments: CommandLine.arguments)
        exit(Int32(status))
    }
    dispatchMain()
}
if CommandLine.arguments.contains("--asr-tuning-experiment") {
    Task {
        let status = await WhisperTuningExperimentCLI.run(arguments: CommandLine.arguments)
        exit(Int32(status))
    }
    dispatchMain()
}
#endif

Log.bootstrap()
Telemetry.start()
Analytics.start()
Analytics.capture(.appOpened)

// Initialize AppKit before starting background CoreText work. Registering
// bundled fonts before NSApplication.shared can race HIServices application
// registration during launch and terminate the process in
// _RegisterApplication.
let app = NSApplication.shared

AccountService.shared.configure()
ModelCatalog.shared.configure()

// Shorten the default tooltip delay from 2s to 0.01s.
UserDefaults.standard.set(10, forKey: "NSInitialToolTipDelay")

let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = MainMenuBuilder.buildMenu()
BundledFonts.register()
app.run()
