# Miller Menu-Bar Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Miller's variable-width text status item with the approved compact Millrace template icon and qualify the affected host behavior.

**Architecture:** A reproducible, repository-owned source mark produces one exact-source-weight monochrome PNG resource with no optical dilation. A focused `StatusItemAppearance` unit loads and configures that resource; `AppCoordinator` retains lifecycle authority and only delegates button presentation. SwiftPM owns resource lookup, while development packaging copies the generated resource bundle into the application.

**Tech Stack:** Swift 6.1, AppKit, Swift Package Manager resources, Swift Testing, Core Graphics/ImageIO, zsh packaging scripts.

---

## File Map

- `Branding/MillraceMarkSource.png`: provenance-bound source silhouette.
- `scripts/generate-menu-bar-icon.swift`: deterministic 72-pixel template-resource generator.
- `Sources/MillerApp/Resources/MillerStatusIcon.png`: generated monochrome resource.
- `Sources/MillerApp/StatusItemAppearance.swift`: resource loading and button presentation.
- `Sources/MillerApp/AppCoordinator.swift`: square status-item construction and shortcut-failure tooltip.
- `Tests/MillerAppTests/StatusItemAppearanceTests.swift`: resource and presentation contract.
- `Package.swift`: MillerApp resource declaration.
- `scripts/package-dev-app.sh`: resource-bundle packaging and assertions.
- `PROVENANCE.md`: Millrace source and bounded transformation record.
- `docs/qualification/text-alpha-host-check.md`: actual-size icon observation row.

The repository deliberately remains on `main` with the existing uncommitted
Gate 4A implementation. This bounded change does not perform source-control
operations before H1.

### Task 1: Establish the failing status-item contract

**Files:**

- Create: `Tests/MillerAppTests/StatusItemAppearanceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import Testing
@testable import MillerApp

@Suite
@MainActor
struct StatusItemAppearanceTests {
    @Test
    func configuresCompactTemplateImageWithoutVisibleTitle() throws {
        let button = NSButton()

        let configured = StatusItemAppearance.configure(button)

        #expect(configured)
        #expect(button.title.isEmpty)
        #expect(button.imagePosition == .imageOnly)
        #expect(button.image?.isTemplate == true)
        #expect(button.image?.size == NSSize(width: 18, height: 18))
        #expect(button.toolTip == "Miller")
        #expect(button.accessibilityLabel() == "Miller status")
    }

    @Test
    func shortcutFailureChangesTooltipWithoutReplacingIcon() {
        let button = NSButton()
        #expect(StatusItemAppearance.configure(button))
        let original = button.image

        StatusItemAppearance.setShortcutAvailable(false, on: button)

        #expect(button.image === original)
        #expect(button.title.isEmpty)
        #expect(button.toolTip == "Miller — shortcut unavailable")
        #expect(button.accessibilityLabel() == "Miller status, shortcut unavailable")
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
cd /path/to/miller
./scripts/test.sh --filter StatusItemAppearanceTests
```

Expected: compilation fails because `StatusItemAppearance` does not exist.

### Task 2: Generate and configure the template resource

**Files:**

- Create: `Branding/MillraceMarkSource.png`
- Create: `scripts/generate-menu-bar-icon.swift`
- Create: `Sources/MillerApp/Resources/MillerStatusIcon.png`
- Create: `Sources/MillerApp/StatusItemAppearance.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Add the approved source mark**

Copy the exact source whose SHA-256 is
`d75978e42d26bd6c1ed96f4831c73c73f2bc54fb04e7c39992cbdc85af77b241`
to `Branding/MillraceMarkSource.png`. Verify the copied hash before any
transformation.

- [ ] **Step 2: Add the deterministic generator**

The generator must:

- accept exactly an input and output path;
- render the complete source into a centered 64-by-64-pixel optical box on a
  72-by-72 transparent canvas;
- preserve aspect ratio;
- preserve the scaled source alpha exactly, with no optical dilation;
- emit black RGB with the preserved alpha;
- refuse a missing or undecodable source; and
- create no file other than the requested output.

Run:

```bash
swift scripts/generate-menu-bar-icon.swift \
  Branding/MillraceMarkSource.png \
  Sources/MillerApp/Resources/MillerStatusIcon.png
```

Expected: one 72-by-72 RGBA PNG.

- [ ] **Step 3: Declare the SwiftPM resource**

Change the MillerApp target to:

```swift
.executableTarget(
    name: "MillerApp",
    dependencies: ["MillerCore", "MillerStorage", "MillerGateway"],
    resources: [.process("Resources")]
),
```

- [ ] **Step 4: Implement the minimal appearance unit**

```swift
import AppKit

@MainActor
enum StatusItemAppearance {
    private static let normalTooltip = "Miller"
    private static let unavailableTooltip = "Miller — shortcut unavailable"

    @discardableResult
    static func configure(
        _ button: NSButton,
        bundle: Bundle = .module
    ) -> Bool {
        guard
            let url = bundle.url(
                forResource: "MillerStatusIcon",
                withExtension: "png"
            ),
            let image = NSImage(contentsOf: url)
        else {
            button.title = "Miller"
            button.toolTip = normalTooltip
            button.setAccessibilityLabel(AccessibilityLabel.status)
            return false
        }

        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.title = ""
        setShortcutAvailable(true, on: button)
        return true
    }

    static func setShortcutAvailable(
        _ available: Bool,
        on button: NSButton
    ) {
        button.toolTip = available ? normalTooltip : unavailableTooltip
        button.setAccessibilityLabel(
            available
                ? AccessibilityLabel.status
                : "\(AccessibilityLabel.status), shortcut unavailable"
        )
    }
}
```

- [ ] **Step 5: Run the focused test and verify GREEN**

Run:

```bash
./scripts/test.sh --filter StatusItemAppearanceTests
```

Expected: both tests pass.

### Task 3: Integrate the compact status item and package its resources

**Files:**

- Modify: `Sources/MillerApp/AppCoordinator.swift`
- Modify: `scripts/package-dev-app.sh`
- Modify: `PROVENANCE.md`

- [ ] **Step 1: Use a square status item**

Construct the item with:

```swift
statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
```

At startup, replace the text assignment with:

```swift
if let button = statusItem.button {
    StatusItemAppearance.configure(button)
}
```

After shortcut registration, call:

```swift
if let button = statusItem.button {
    StatusItemAppearance.setShortcutAvailable(registered, on: button)
}
```

Remove both `button?.title` assignments.

- [ ] **Step 2: Package the SwiftPM resource bundle**

Resolve the single built `Miller_MillerApp.bundle`, copy it to the
`Miller.app/` root (where SwiftPM's generated `Bundle.module` accessor looks), and assert that the packaged
`MillerStatusIcon.png` exists. Refuse zero or multiple matching bundles.

- [ ] **Step 3: Record provenance**

Add the source path and SHA-256, state that the asset is owned by the Millrace
ecosystem, describe the 72-pixel aspect-fit monochrome transformation with no
optical dilation, and record the generated resource SHA-256.

- [ ] **Step 4: Run focused and full automated verification**

Run:

```bash
./scripts/test.sh --filter StatusItemAppearanceTests
./scripts/test.sh
./scripts/package-dev-app.sh
test -f .artifacts/Miller.app/Miller_MillerApp.bundle/MillerStatusIcon.png
git diff --check
```

Expected: all tests pass, packaging succeeds, the bundled icon exists, and
diff whitespace checks pass.

### Task 4: Extend and run Gate H1

**Files:**

- Modify: `docs/qualification/text-alpha-host-check.md`

- [ ] **Step 1: Add the icon observation**

Add `menu_bar_icon=NOT_RUN` to the result vocabulary and require direct
confirmation that the intact silhouette is recognizable, uses the system
template color, consumes one square slot, and opens the existing menu.

- [ ] **Step 2: Clean the visual-design scratch session**

Stop the visual-companion server and remove `.superpowers/` through the
repository's ignored scratch boundary after retaining the approved design
document.

- [ ] **Step 3: Run H1**

Run:

```bash
./scripts/run-host-check.sh
```

Use Computer Use for visible menu, panel, focus, keyboard, conversation,
relaunch, Settings, and Keychain-probe checks. The operator must physically
press the selected global shortcut because the Computer Use key API cannot produce a
true global shortcut. Record `NOT_RUN` rather than infer any check that cannot
be observed directly.

- [ ] **Step 4: Clean generated artifacts**

The H1 runner must remove its application, database, cache, helper, and status
roots. Then run:

```bash
./scripts/clean.sh --dependencies
test ! -e .artifacts
test ! -e .build
test ! -e .cache
test ! -e Gateway/node_modules
```

Expected: no generated root or dependency cache remains.
