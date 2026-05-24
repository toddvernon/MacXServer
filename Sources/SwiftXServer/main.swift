// SPM executable entry. The actual setup lives in ServerEntry.run()
// so it can be shared with the Xcode .app target's @main wrapper.
// Keep this file ONLY in the SPM executable target — the Xcode .app
// excludes it and uses Xcode/ServerMain.swift instead.

ServerEntry.run()
