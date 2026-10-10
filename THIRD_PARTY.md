# Third-party material

SpellBar contains no third-party code, data, fonts or models. It is built only against frameworks that ship with
macOS, and it bundles nothing besides its own icon.

| Used | Part of | Licence |
|---|---|---|
| AppKit, Foundation, Core Graphics, OSLog, ServiceManagement | macOS | Apple SDK terms |
| `NSSpellChecker` (candidates and corrections) | AppKit | Apple SDK terms |
| Dictionary Services `DCSCopyTextDefinition` (word meanings) | Core Services | Apple SDK terms |
| Accessibility API (`AXUIElement`) | Application Services | Apple SDK terms |
| Text Input Services (`TISCopyCurrentKeyboardInputSource`) | Carbon | Apple SDK terms |

The word meanings SpellBar shows come from the dictionaries installed in macOS. They belong to their publishers and
are not redistributed: the app asks the system for them at the moment it displays one.

The built-in list of programming terms in `Sources/SeedTerms.swift` was written for this project.
