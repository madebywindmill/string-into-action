import Foundation
import Testing
@testable import StringIntoAction

struct StringScannerTests {
    @Test func findsSwiftAndStringsFileCopy() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appending(path: "Sources"), withIntermediateDirectories: true)
        try #"""
        Text("Welcome back")
        Image(systemName: "star.fill")
        Button("Continue") {}
        """#.write(to: root.appending(path: "Sources/View.swift"), atomically: true, encoding: .utf8)
        try #""account.title" = "Your account";"#.write(
            to: root.appending(path: "Localizable.strings"), atomically: true, encoding: .utf8
        )

        let result = StringScanner().scan(projectURL: root)

        #expect(result.occurrences.map(\.value).contains("Welcome back"))
        #expect(!result.occurrences.map(\.value).contains("Continue"))
        #expect(result.occurrences.map(\.value).contains("Your account"))
        #expect(!result.occurrences.map(\.value).contains("star.fill"))
    }

    @Test func requiresWhitespaceInEveryReviewableString() throws {
        let root = try temporaryDirectory()
        try #"""
        Text("Continue")
        Text("Continue setup")
        """#.write(to: root.appending(path: "View.swift"), atomically: true, encoding: .utf8)
        try #"""
        "retry" = "Retry";
        "retry.message" = "Please retry";
        """#.write(to: root.appending(path: "Localizable.strings"), atomically: true, encoding: .utf8)
        try #"{"sourceLanguage":"en","strings":{"Settings":{},"Account settings":{}}}"#.write(
            to: root.appending(path: "Localizable.xcstrings"), atomically: true, encoding: .utf8
        )

        let values = StringScanner().scan(projectURL: root).occurrences.map(\.value)

        #expect(!values.contains("Continue"))
        #expect(!values.contains("Retry"))
        #expect(!values.contains("Settings"))
        #expect(values.contains("Continue setup"))
        #expect(values.contains("Please retry"))
        #expect(values.contains("Account settings"))
    }

    @Test func remembersMultipleProjectsAndSidebarPreference() throws {
        let suiteName = "StringIntoActionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = try temporaryDirectory()
        let first = root.appending(path: "First", directoryHint: .isDirectory)
        let second = root.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let history = ProjectHistory(defaults: defaults)

        history.remember(first)
        history.remember(second)
        history.remember(first)
        history.showsProjectsSidebar = false

        #expect(history.projectURLs == [first.standardizedFileURL, second.standardizedFileURL])
        #expect(history.lastProjectURL == first.standardizedFileURL)
        #expect(!ProjectHistory(defaults: defaults).showsProjectsSidebar)

        history.setProjectOrder([second, first])
        #expect(history.projectURLs == [second.standardizedFileURL, first.standardizedFileURL])

        history.forget(first)
        #expect(history.projectURLs == [second.standardizedFileURL])
        #expect(history.lastProjectURL == second.standardizedFileURL)
    }

    @Test @MainActor func droppedXcodeProjectOpensItsContainingFolderAndRejectsFiles() async throws {
        let root = try temporaryDirectory()
        let xcodeProject = root.appending(path: "Example.xcodeproj", directoryHint: .isDirectory)
        let ordinaryFile = root.appending(path: "notes.txt")
        try FileManager.default.createDirectory(at: xcodeProject, withIntermediateDirectories: true)
        try "notes".write(to: ordinaryFile, atomically: true, encoding: .utf8)
        let model = AppModel(
            reviewStore: ReviewStore(rootURL: root.appending(path: "reviews")),
            remembersProject: false
        )

        #expect(!model.addDroppedProjects([ordinaryFile]))
        #expect(model.addDroppedProjects([xcodeProject]))
        while model.projectURL == nil || model.isScanning { await Task.yield() }
        #expect(model.projectURL == root.standardizedFileURL)
    }

    @Test func resolvesConfiguredXcodeAppIconAndLargestRendition() throws {
        let root = try temporaryDirectory()
        let xcodeProject = root.appending(path: "Example.xcodeproj", directoryHint: .isDirectory)
        let assets = root.appending(path: "Assets.xcassets", directoryHint: .isDirectory)
        let defaultSet = assets.appending(path: "AppIcon.appiconset", directoryHint: .isDirectory)
        let brandSet = assets.appending(path: "BrandIcon.appiconset", directoryHint: .isDirectory)
        for directory in [xcodeProject, defaultSet, brandSet] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "ASSETCATALOG_COMPILER_APPICON_NAME = BrandIcon;".write(
            to: xcodeProject.appending(path: "project.pbxproj"), atomically: true, encoding: .utf8
        )
        try #"{"images":[{"filename":"default.png","size":"1024x1024","scale":"1x"}]}"#.write(
            to: defaultSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8
        )
        try Data("default".utf8).write(to: defaultSet.appending(path: "default.png"))
        try #"{"images":[{"filename":"small.png","size":"20x20","scale":"2x"},{"filename":"large.png","size":"512x512","scale":"2x"}]}"#.write(
            to: brandSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8
        )
        try Data("small".utf8).write(to: brandSet.appending(path: "small.png"))
        try Data("large".utf8).write(to: brandSet.appending(path: "large.png"))

        let iconURL = ProjectIconResolver().iconURL(for: root)

        #expect(iconURL == brandSet.appending(path: "large.png"))
    }

    @Test func skipsEmptySiblingIconSetsAndPrefersMainProjectFolder() throws {
        let fixtures = try temporaryDirectory()
        let root = fixtures.appending(path: "rise-ios", directoryHint: .isDirectory)
        let xcodeProject = root.appending(path: "Rise/Rise.xcodeproj", directoryHint: .isDirectory)
        let emptyMacSet = root.appending(
            path: "Rise/RiseMac/Assets-mac.xcassets/AppIcon.appiconset", directoryHint: .isDirectory
        )
        let adminSet = root.appending(
            path: "Rise/RiseAdmin/Assets-admin.xcassets/AppIcon.appiconset", directoryHint: .isDirectory
        )
        let mainSet = root.appending(
            path: "Rise/Rise/Assets.xcassets/AppIcon.appiconset", directoryHint: .isDirectory
        )
        for directory in [xcodeProject, emptyMacSet, adminSet, mainSet] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;".write(
            to: xcodeProject.appending(path: "project.pbxproj"), atomically: true, encoding: .utf8
        )
        try #"{"images":[{"idiom":"mac","size":"512x512","scale":"2x"}]}"#.write(
            to: emptyMacSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8
        )
        for (iconSet, filename) in [(adminSet, "admin.png"), (mainSet, "rise.png")] {
            try #"{"images":[{"filename":"\#(filename)","size":"1024x1024","scale":"1x"}]}"#.write(
                to: iconSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8
            )
            try Data(filename.utf8).write(to: iconSet.appending(path: filename))
        }

        #expect(ProjectIconResolver().iconURL(for: root) == mainSet.appending(path: "rise.png"))
    }

    @Test func skipsDependencyDirectories() throws {
        let root = try temporaryDirectory()
        let dependency = root.appending(path: "node_modules/package", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        try #"export const text = "Do not review me""#.write(
            to: dependency.appending(path: "index.js"), atomically: true, encoding: .utf8
        )

        let result = StringScanner().scan(projectURL: root)

        #expect(result.filesScanned == 0)
        #expect(result.occurrences.isEmpty)
    }

    @Test func readsStringCatalogKeysButIgnoresPackageMetadata() throws {
        let root = try temporaryDirectory()
        try #"{"name":"sample-app","license":"MIT"}"#.write(
            to: root.appending(path: "package.json"), atomically: true, encoding: .utf8
        )
        try #"{"sourceLanguage":"en","strings":{"Welcome home":{"extractionState":"manual"}}}"#.write(
            to: root.appending(path: "Localizable.xcstrings"), atomically: true, encoding: .utf8
        )

        let result = StringScanner().scan(projectURL: root)

        #expect(result.occurrences.map(\.value) == ["Welcome home"])
        #expect(result.occurrences.first?.isEditable == false)
    }

    @Test func excludesStructuralIdentifiersAndSeparatesAmbiguousCopy() throws {
        let root = try temporaryDirectory()
        try #"""
        TimelineColumns.migrateAddColumn(
            id: "totalDownloads",
            flag: "didAddTotalDownloadsColumn",
            before: "firstTimeDownloads"
        )
        let stateName = "readyState"
        Text("Ready to ship")
        """#.write(to: root.appending(path: "Migration.swift"), atomically: true, encoding: .utf8)

        let result = StringScanner().scan(projectURL: root)

        #expect(!result.occurrences.map(\.value).contains("firstTimeDownloads"))
        #expect(!result.occurrences.map(\.value).contains("totalDownloads"))
        #expect(!result.occurrences.map(\.value).contains("readyState"))
        #expect(result.occurrences.first(where: { $0.value == "Ready to ship" })?.confidence == .review)
    }

    @Test func excludesLoggingAndPrintingCalls() throws {
        let root = try temporaryDirectory()
        try #"""
        statusLog("APP-STATUS launch dump")
        print("Debug output")
        debugPrint("Detailed output")
        NSLog("Objective-C style log")
        DDLogInfo("Third-party logger output")
        logger.info(
            "A multiline structured log"
        )
        Text("Log in")
        """#.write(to: root.appending(path: "Logging.swift"), atomically: true, encoding: .utf8)
        try #"""
        console.log("Browser log")
        console.warn("Browser warning")
        renderText("Ambiguous browser copy")
        """#.write(to: root.appending(path: "logging.js"), atomically: true, encoding: .utf8)

        let result = StringScanner().scan(projectURL: root)
        let values = result.occurrences.map(\.value)

        #expect(!values.contains("APP-STATUS launch dump"))
        #expect(!values.contains("Debug output"))
        #expect(!values.contains("Detailed output"))
        #expect(!values.contains("Objective-C style log"))
        #expect(!values.contains("Third-party logger output"))
        #expect(!values.contains("A multiline structured log"))
        #expect(!values.contains("Browser log"))
        #expect(!values.contains("Browser warning"))
        #expect(values.contains("Log in"))
        #expect(values.contains("Ambiguous browser copy"))
    }

    @Test func excludesMainStoryboardMenusButKeepsOtherControls() throws {
        let root = try temporaryDirectory()
        try #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <document>
          <application>
            <menu key="mainMenu" title="Main Menu">
              <items>
                <menuItem title="Edit">
                  <menu key="submenu" title="Find">
                    <items>
                      <menuItem title="Use Selection for Find"/>
                    </items>
                  </menu>
                </menuItem>
              </items>
            </menu>
          </application>
          <window title="Account Settings">
            <button title="Save Changes"/>
          </window>
        </document>
        """#.write(to: root.appending(path: "Main.storyboard"), atomically: true, encoding: .utf8)

        let values = StringScanner().scan(projectURL: root).occurrences.map(\.value)

        #expect(!values.contains("Main Menu"))
        #expect(!values.contains("Edit"))
        #expect(!values.contains("Find"))
        #expect(!values.contains("Use Selection for Find"))
        #expect(values.contains("Account Settings"))
        #expect(values.contains("Save Changes"))
    }

    @Test func separatesImageNamesFromAccessibilityCopyOnTheSameLine() throws {
        let root = try temporaryDirectory()
        try #"item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI Chat")"#
            .write(to: root.appending(path: "Toolbar.swift"), atomically: true, encoding: .utf8)

        let occurrences = StringScanner().scan(projectURL: root).occurrences

        #expect(!occurrences.map(\.value).contains("sparkles"))
        #expect(occurrences.first(where: { $0.value == "AI Chat" })?.confidence == .review)
        #expect(
            occurrences.first(where: { $0.value == "AI Chat" })?.detectionReason
                == "Passed directly to a UI API"
        )
    }

    @Test func sidebarTreeGroupsStringsByFolderAndFile() throws {
        let occurrences = [
            occurrence(path: "Sources/Views/Home.swift", line: 4, value: "Welcome"),
            occurrence(path: "Sources/Views/Home.swift", line: 9, value: "Continue"),
            occurrence(path: "Root.swift", line: 2, value: "Hello")
        ]

        let nodes = SidebarTreeBuilder.build(from: occurrences)
        let sources = try #require(nodes.first(where: { $0.title == "Sources" }))
        let views = try #require(sources.children?.first(where: { $0.title == "Views" }))
        let home = try #require(views.children?.first(where: { $0.title == "Home.swift" }))

        #expect(sources.kind == .folder)
        #expect(sources.stringCount == 2)
        #expect(home.kind == .file)
        #expect(home.stringCount == 2)
        #expect(home.children?.map(\.title) == ["Welcome", "Continue"])
        #expect(nodes.contains(where: { $0.title == "Root.swift" && $0.stringCount == 1 }))
    }

    @Test func sourceEditorRejectsAChangedFile() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.swift")
        try #"Text("Original copy")"#.write(to: file, atomically: true, encoding: .utf8)
        let occurrence = try #require(StringScanner().scan(projectURL: root).occurrences.first)
        try #"Text("Changed elsewhere")"#.write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: SourceEditorError.self) {
            try SourceEditor().replace(occurrence, with: "My edit")
        }
    }

    @Test func sourceEditorEscapesSwiftCopy() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.swift")
        try #"Text("Original copy")"#.write(to: file, atomically: true, encoding: .utf8)
        let occurrence = try #require(StringScanner().scan(projectURL: root).occurrences.first)

        try SourceEditor().replace(occurrence, with: "Say \"hello\"\nAgain")

        let updated = try String(contentsOf: file, encoding: .utf8)
        #expect(updated == #"Text("Say \"hello\"\nAgain")"#)
    }

    @Test func approvalPersistsExactFingerprint() throws {
        let root = try temporaryDirectory()
        let reviewRoot = root.appending(path: "reviews", directoryHint: .isDirectory)
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        let store = ReviewStore(rootURL: reviewRoot)
        let record = ApprovalRecord(fingerprint: Hashing.sha256("Hello"), approvedAt: .now)

        let ignore = IgnoreRecord(ignoredAt: .now)
        try store.save(
            ProjectReviewData(
                approvals: ["View.swift:1:7": record],
                ignores: ["View.swift:2:7:unknown": ignore]
            ),
            projectURL: project
        )
        let loaded = try store.load(projectURL: project)

        #expect(loaded.approvals["View.swift:1:7"]?.fingerprint == Hashing.sha256("Hello"))
        #expect(loaded.ignores["View.swift:2:7:unknown"] != nil)
    }

    @Test func commentsAndNestedQuotesDoNotBecomeOccurrences() throws {
        let root = try temporaryDirectory()
        try #"""
        /* Text("Commented copy") /* "Nested comment" */ */
        Text("Actual copy") // "Trailing comment"
        """#.write(to: root.appending(path: "View.swift"), atomically: true, encoding: .utf8)
        try #"""
        // "Commented JS"
        const message = 'Say "hello there" today';
        const other = "It's a 'great day'";
        """#.write(to: root.appending(path: "view.js"), atomically: true, encoding: .utf8)
        let values = StringScanner().scan(projectURL: root).occurrences.map(\.value)
        #expect(!values.contains("Commented copy"))
        #expect(!values.contains("Nested comment"))
        #expect(!values.contains("Trailing comment"))
        #expect(!values.contains("Commented JS"))
        #expect(!values.contains("great day"))
        #expect(values.contains("Say \"hello there\" today"))
        #expect(values.contains("It's a 'great day'"))
    }

    @Test func complexSwiftLiteralsAreWholeAndReadOnly() throws {
        let root = try temporaryDirectory()
        try ##"""
        Text("Hello \(name ?? "new friend")!")
        Text(#"A "quoted" raw string"#)
        Text("""
        A multiline string
        """)
        Text("Regular copy")
        """##.write(to: root.appending(path: "View.swift"), atomically: true, encoding: .utf8)
        let values = StringScanner().scan(projectURL: root).occurrences
        #expect(values.count == 4)
        #expect(values.filter(\.isEditable).map(\.value) == ["Regular copy"])
        #expect(values.first?.rawValue == #"Hello \(name ?? "new friend")!"#)
    }

    @Test func escapesRoundTripWithoutChangingLiteralBackslashes() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.swift")
        try #"Text("Show \\n literally and \u{1F600}")"#.write(to: file, atomically: true, encoding: .utf8)
        let original = try #require(StringScanner().scan(projectURL: root).occurrences.first)
        #expect(original.value == "Show \\n literally and 😀")
        try SourceEditor().replace(original, with: original.value + "\r\nDone")
        let updated = try #require(StringScanner().scan(projectURL: root).occurrences.first)
        #expect(updated.value == original.value + "\r\nDone")
    }

    @Test func templateEditsCannotIntroduceInterpolation() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "view.js")
        try "const message = `Original copy`;".write(to: file, atomically: true, encoding: .utf8)
        let original = try #require(StringScanner().scan(projectURL: root).occurrences.first)
        let replacement = "Display ${dangerous()} and `quotes`"
        try SourceEditor().replace(original, with: replacement)
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(source.contains(#"\${dangerous()}"#))
        let updated = try #require(StringScanner().scan(projectURL: root).occurrences.first)
        #expect(updated.value == replacement)
        #expect(updated.isEditable)
    }

    @Test func jsonUnicodeAndControlsStayValidJSON() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "messages.json")
        try #"{"title":"Hello \uD83D\uDE00"}"#.write(to: file, atomically: true, encoding: .utf8)
        let original = try #require(StringScanner().scan(projectURL: root).occurrences.first)
        #expect(original.value == "Hello 😀")
        try SourceEditor().replace(original, with: "Hello\r\n\t\"world\"")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String]
        #expect(json?["title"] == "Hello\r\n\t\"world\"")
    }

    @Test func markupSkipsScriptsCommentsAndPreservesBackslashes() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "index.html")
        try #"""
        <!-- <p>Commented copy</p> -->
        <script>const message = "Script text";</script>
        <style>p { color: red; }</style>
        <p>Use \n &amp; &#x1F600; &#65;</p>
        """#.write(to: file, atomically: true, encoding: .utf8)
        let values = StringScanner().scan(projectURL: root).occurrences
        #expect(values.count == 1)
        let original = try #require(values.first)
        #expect(original.value == #"Use \n & 😀 A"#)
        try SourceEditor().replace(original, with: original.value + "!")
        #expect(StringScanner().scan(projectURL: root).occurrences.first?.value == original.value + "!")
    }

    @Test func catalogMetadataWithMatchingNamesIsNotCopy() throws {
        let root = try temporaryDirectory()
        try #"{"sourceLanguage":"en","strings":{"value":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"Hello"}}}},"state":{}}}"#
            .write(to: root.appending(path: "Localizable.xcstrings"), atomically: true, encoding: .utf8)
        #expect(StringScanner().scan(projectURL: root).occurrences.isEmpty)
    }

    @Test func loggingOnPreviousLineDoesNotHideUnrelatedCopy() throws {
        let root = try temporaryDirectory()
        try #"""
        print("Log output")
        let title = "Welcome home"
        """#.write(to: root.appending(path: "View.swift"), atomically: true, encoding: .utf8)
        #expect(StringScanner().scan(projectURL: root).occurrences.map(\.value) == ["Welcome home"])
    }

    @Test func utf16StringsRemainReadableAfterEditing() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "Localizable.strings")
        try #""key" = "Hello world";"#.write(to: file, atomically: true, encoding: .utf16)
        let original = try #require(StringScanner().scan(projectURL: root).occurrences.first)
        try SourceEditor().replace(original, with: "Goodbye world")
        #expect(try String(contentsOf: file, encoding: .utf16) == #""key" = "Goodbye world";"#)
        #expect(StringScanner().scan(projectURL: root).occurrences.first?.value == "Goodbye world")
    }

    @Test func stringsCommentsAreExcluded() throws {
        let root = try temporaryDirectory()
        try #"""
        /* "old" = "Old copy"; */
        // "other" = "Other copy";
        "current" = "Current copy";
        """#.write(to: root.appending(path: "Localizable.strings"), atomically: true, encoding: .utf8)
        #expect(StringScanner().scan(projectURL: root).occurrences.map(\.value) == ["Current copy"])
    }

    @Test func malformedReviewDataIsReportedAndPreserved() throws {
        let root = try temporaryDirectory()
        let store = ReviewStore(rootURL: root)
        let records = root.appending(path: Hashing.sha256(root.standardizedFileURL.path) + ".json")
        try "broken json".write(to: records, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try store.load(projectURL: root) }
        #expect(try String(contentsOf: records, encoding: .utf8) == "broken json")
    }

    @Test @MainActor func failedPersistenceDoesNotReportApproval() async throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"Text("Hello world")"#.write(to: project.appending(path: "View.swift"), atomically: true, encoding: .utf8)
        let reviewRoot = root.appending(path: "reviews")
        let model = AppModel(reviewStore: ReviewStore(rootURL: reviewRoot), remembersProject: false)
        await model.openProject(project)
        let original = try #require(model.occurrences.first)
        try FileManager.default.moveItem(at: reviewRoot, to: root.appending(path: "saved-reviews"))
        try "not a directory".write(to: reviewRoot, atomically: true, encoding: .utf8)
        model.approve(original)
        #expect(model.approvedCount == 0)
        #expect(model.presentedError != nil)
    }

    @Test @MainActor func savingThenSwitchingProjectsCannotApproveTheOtherProject() async throws {
        let root = try temporaryDirectory()
        let first = root.appending(path: "first")
        let second = root.appending(path: "second")
        for project in [first, second] {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try #"Text("Original copy")"#.write(to: project.appending(path: "View.swift"), atomically: true, encoding: .utf8)
        }
        let store = ReviewStore(rootURL: root.appending(path: "reviews"))
        let model = AppModel(reviewStore: store, remembersProject: false)
        await model.openProject(first)
        let original = try #require(model.occurrences.first)
        model.saveAndApprove("Edited copy", for: original)
        await model.openProject(second)
        #expect(model.projectURL == second)
        #expect(model.approvedCount == 0)
        #expect(try store.load(projectURL: second).approvals.isEmpty)
        #expect(try store.load(projectURL: first).approvals[original.id]?.fingerprint == Hashing.sha256("Edited copy"))
        model.approve(original)
        #expect(model.approvedCount == 0)
    }

    @Test @MainActor func singleCharacterUIEditsStillSaveSuccessfully() async throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.swift")
        try #"Text("Hello world")"#.write(to: file, atomically: true, encoding: .utf8)
        let model = AppModel(reviewStore: ReviewStore(rootURL: root.appending(path: "reviews")), remembersProject: false)
        await model.openProject(root)
        let original = try #require(model.occurrences.first)
        model.saveAndApprove("A", for: original)
        while model.isScanning { await Task.yield() }
        #expect(model.presentedError == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == #"Text("A")"#)
    }

    @Test @MainActor func editCommandOnlyRequestsFocusForAnEditableSelection() async throws {
        let root = try temporaryDirectory()
        try #"Text("Hello world")"#.write(
            to: root.appending(path: "View.swift"), atomically: true, encoding: .utf8
        )
        let model = AppModel(
            reviewStore: ReviewStore(rootURL: root.appending(path: "reviews")),
            remembersProject: false
        )
        await model.openProject(root)
        let initialRequest = model.stringEditorFocusRequest

        #expect(model.canEditSelectedString)
        model.focusStringEditor()
        #expect(model.stringEditorFocusRequest == initialRequest + 1)

        model.selectedID = nil
        #expect(!model.canEditSelectedString)
        model.focusStringEditor()
        #expect(model.stringEditorFocusRequest == initialRequest + 1)
    }

    @Test @MainActor func notUserFacingCommandIgnoresTheSelectedString() async throws {
        let root = try temporaryDirectory()
        try #"Text("Hello world")"#.write(
            to: root.appending(path: "View.swift"), atomically: true, encoding: .utf8
        )
        let model = AppModel(
            reviewStore: ReviewStore(rootURL: root.appending(path: "reviews")),
            remembersProject: false
        )
        await model.openProject(root)

        #expect(model.canIgnoreSelectedString)
        model.ignoreSelectedString()
        #expect(model.ignoredCount == 1)
        #expect(!model.canIgnoreSelectedString)
    }

    @Test @MainActor func approveAllInFileApprovesEveryQueuedStringInThatFile() async throws {
        let root = try temporaryDirectory()
        try #"""
        Text("First message")
        Text("Second message")
        let possible = "possible message"
        """#.write(to: root.appending(path: "First.swift"), atomically: true, encoding: .utf8)
        try #"Text("Other file message")"#.write(
            to: root.appending(path: "Second.swift"), atomically: true, encoding: .utf8
        )
        let model = AppModel(
            reviewStore: ReviewStore(rootURL: root.appending(path: "reviews")),
            remembersProject: false
        )
        await model.openProject(root)
        let selected = try #require(model.selectedOccurrence)

        model.approveAllQueuedInFile(containing: selected)

        #expect(model.reviewState(for: try #require(model.occurrences.first { $0.value == "First message" })) == .approved)
        #expect(model.reviewState(for: try #require(model.occurrences.first { $0.value == "Second message" })) == .approved)
        #expect(model.reviewState(for: try #require(model.occurrences.first { $0.value == "possible message" })) == .approved)
        #expect(model.reviewState(for: try #require(model.occurrences.first { $0.value == "Other file message" })) == .needsReview)
    }

    @Test @MainActor func approveAllRequiresConfirmationAndApprovesTheEntireProjectQueue() async throws {
        let root = try temporaryDirectory()
        try #"Text("First message")\nText("Second message")"#.write(
            to: root.appending(path: "First.swift"), atomically: true, encoding: .utf8
        )
        try #"Text("Other file message")"#.write(
            to: root.appending(path: "Second.swift"), atomically: true, encoding: .utf8
        )
        let model = AppModel(
            reviewStore: ReviewStore(rootURL: root.appending(path: "reviews")),
            remembersProject: false
        )
        await model.openProject(root)
        model.searchText = "First"

        model.requestApproveAllQueuedStrings()
        #expect(model.isApproveAllConfirmationPresented)
        #expect(model.approvedCount == 0)
        #expect(model.approveAllConfirmationMessage.contains("3 strings"))

        model.cancelApproveAllQueuedStrings()
        #expect(!model.isApproveAllConfirmationPresented)
        #expect(model.approvedCount == 0)

        model.requestApproveAllQueuedStrings()
        model.confirmApproveAllQueuedStrings()
        #expect(!model.isApproveAllConfirmationPresented)
        #expect(model.reviewCount == 0)
        #expect(model.approvedCount == 3)
    }

    @Test func regexesAndTaggedTemplatesAreNotEditableCopy() throws {
        let root = try temporaryDirectory()
        try #"""
        const pattern = /"Regex content"/;
        const literal = String.raw`Display \n literally`;
        const message = `Hello ${format("Nested string")}`;
        const text = "Actual copy";
        """#.write(to: root.appending(path: "view.js"), atomically: true, encoding: .utf8)
        let values = StringScanner().scan(projectURL: root).occurrences
        #expect(!values.map(\.value).contains("Regex content"))
        #expect(!values.map(\.value).contains("Nested string"))
        #expect(values.filter(\.isEditable).map(\.value) == ["Actual copy"])
    }

    @Test func unicodeOffsetsAndInvalidRangesAreSafe() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.swift")
        try #"Text("😀 Hello"); Text("Next copy")"#.write(to: file, atomically: true, encoding: .utf8)
        let original = try #require(StringScanner().scan(projectURL: root).occurrences.last)
        try SourceEditor().replace(original, with: "Edited copy")
        #expect(try String(contentsOf: file, encoding: .utf8) == #"Text("😀 Hello"); Text("Edited copy")"#)
        let updated = try #require(StringScanner().scan(projectURL: root).occurrences.last)
        let invalid = StringOccurrence(
            id: updated.id, fileURL: file, relativePath: updated.relativePath,
            line: updated.line, column: updated.column, value: updated.value, rawValue: updated.rawValue,
            contextLines: [], contentRange: NSRange(location: Int.max, length: 10),
            sourceFingerprint: updated.sourceFingerprint, language: .swift, style: .doubleQuoted,
            isEditable: true, confidence: .review, detectionReason: "Test", role: .userInterface
        )
        #expect(throws: SourceEditorError.self) { try SourceEditor().replace(invalid, with: "Edit") }
        #expect(throws: SourceEditorError.self) { try SourceEditor().replace(updated, with: "Invalid\0copy") }
    }

    @Test func scannerDoesNotFollowSourceSymlinks() throws {
        let root = try temporaryDirectory()
        let scanned = root.appending(path: "scanned")
        try FileManager.default.createDirectory(at: scanned, withIntermediateDirectories: true)
        let outside = root.appending(path: "Outside.swift")
        try #"Text("Outside copy")"#.write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: scanned.appending(path: "Linked.swift"), withDestinationURL: outside)
        #expect(StringScanner().scan(projectURL: scanned).occurrences.isEmpty)
    }

    @Test @MainActor func obsoleteScanCannotReplaceTheNewProject() async throws {
        let root = try temporaryDirectory()
        let first = root.appending(path: "first")
        let second = root.appending(path: "second")
        let gate = ScanGate()
        let model = AppModel(reviewStore: ReviewStore(rootURL: root.appending(path: "reviews")), remembersProject: false,
                             scan: { await gate.scan($0) })
        let firstOpen = Task { await model.openProject(first) }
        await gate.waitUntilStarted(first)
        let secondOpen = Task { await model.openProject(second) }
        await gate.waitUntilStarted(second)
        #expect(model.occurrences.isEmpty)
        await gate.finish(second, filesScanned: 2)
        await secondOpen.value
        await gate.finish(first, filesScanned: 1)
        await firstOpen.value
        #expect(model.projectURL == second)
        #expect(model.filesScanned == 2)
        #expect(!model.isScanning)
    }

    @Test @MainActor func refreshKeepsSelectionWithinTheActiveFilter() async throws {
        let root = try temporaryDirectory()
        try #"Text("Original copy")"#.write(to: root.appending(path: "View.swift"), atomically: true, encoding: .utf8)
        let model = AppModel(reviewStore: ReviewStore(rootURL: root.appending(path: "reviews")), remembersProject: false)
        await model.openProject(root)
        let original = try #require(model.occurrences.first)
        model.approve(original)
        model.selectedID = original.id
        model.refresh()
        while model.isScanning { await Task.yield() }
        #expect(model.selectedID == nil)
        model.filter = .approved
        model.ensureSelectionIsVisible()
        #expect(model.selectedID == original.id)
    }

    @Test @MainActor func searchOnlyMatchesTheFlaggedStringValue() async throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appending(path: "ContextMatch"), withIntermediateDirectories: true
        )
        try #"""
        // surrounding needle context
        Text("Visible message")
        """#.write(
            to: root.appending(path: "ContextMatch/View.swift"), atomically: true, encoding: .utf8
        )
        let model = AppModel(
            reviewStore: ReviewStore(rootURL: root.appending(path: "reviews")),
            remembersProject: false
        )
        await model.openProject(root)

        model.searchText = "needle"
        #expect(model.filteredOccurrences.isEmpty)
        model.searchText = "ContextMatch"
        #expect(model.filteredOccurrences.isEmpty)
        model.searchText = "visible"
        #expect(model.filteredOccurrences.map(\.value) == ["Visible message"])
    }

    @Test func largeFileKeepsAccurateLocations() throws {
        let root = try temporaryDirectory()
        let source = (1...2000).map { "Text(\"Welcome number \($0)\")" }.joined(separator: "\n")
        try source.write(to: root.appending(path: "View.swift"), atomically: true, encoding: .utf8)
        let values = StringScanner().scan(projectURL: root).occurrences
        #expect(values.count == 2000)
        #expect(values.last?.line == 2000)
        #expect(values.last?.column == 7)
    }

    @Test func sourceContextIncludesSixLinesOnEachSide() throws {
        let root = try temporaryDirectory()
        let source = (1...15).map { line in
            line == 8 ? #"Text("Center string")"# : "// Line \(line)"
        }.joined(separator: "\n")
        try source.write(to: root.appending(path: "View.swift"), atomically: true, encoding: .utf8)

        let occurrence = try #require(StringScanner().scan(projectURL: root).occurrences.first)

        #expect(occurrence.contextLines.map(\.number) == Array(2...14))
        #expect(occurrence.contextLines.count == 13)
    }

    @Test func jsxAttributesUseMarkupEscaping() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.tsx")
        try #"const view = <button title="Say &quot;hello&quot;" />;"#.write(to: file, atomically: true, encoding: .utf8)
        let original = try #require(StringScanner().scan(projectURL: root).occurrences.first)
        #expect(original.value == "Say \"hello\"")
        try SourceEditor().replace(original, with: "Say \"goodbye\" {name}")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("&quot;goodbye&quot; &#123;name&#125;"))
        #expect(StringScanner().scan(projectURL: root).occurrences.first?.value == "Say \"goodbye\" {name}")
    }

    @Test(arguments: ["jsx", "tsx"])
    func jsxAttributeBackslashesDoNotConsumeNeighboringAttributes(ext: String) throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.\(ext)")
        let source = #"const view = <button title="Choose a path\" aria-label='Open file\' />;"#
        try source.write(to: file, atomically: true, encoding: .utf8)
        let occurrences = StringScanner().scan(projectURL: root).occurrences
        #expect(occurrences.map(\.value) == ["Choose a path\\", "Open file\\"])
        #expect(occurrences.allSatisfy { $0.isEditable && $0.style == .htmlAttribute })
        let original = try #require(occurrences.first)
        try SourceEditor().replace(original, with: "Choose another path\\")
        #expect(try String(contentsOf: file, encoding: .utf8) ==
                source.replacingOccurrences(of: "Choose a path", with: "Choose another path"))
        let neighbor = try #require(StringScanner().scan(projectURL: root).occurrences.last)
        try SourceEditor().replace(neighbor, with: "Open 'another' file")
        #expect(try String(contentsOf: file, encoding: .utf8) ==
                #"const view = <button title="Choose another path\" aria-label='Open &apos;another&apos; file' />;"#)
    }

    @Test(arguments: ["jsx", "tsx"])
    func jsxChildrenAreFoundAndEditsPreserveTagsAndExpressions(ext: String) throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.\(ext)")
        let source = #"""
        const view = <><button title="Button hint">Save changes</button>
          <section>Hello {name}<strong>Welcome back</strong>
            {ready ? "Start now" : "Try later"}{/* "Hidden comment" */}
            {ready && <span>Nested child</span>}
          </section></>;
        const comparison = count < limit ? "Below limit" : "Above limit";
        const generic = <T,>(value: T) => value;
        const message = "After generic";
        """#
        try source.write(to: file, atomically: true, encoding: .utf8)
        let occurrences = StringScanner().scan(projectURL: root).occurrences
        #expect(Set(occurrences.map(\.value)) == Set([
            "Button hint", "Save changes", "Hello ", "Welcome back", "Start now", "Try later",
            "Nested child", "Below limit", "Above limit", "After generic"
        ]))
        let original = try #require(occurrences.first { $0.value == "Save changes" })
        #expect(original.isEditable && original.style == .htmlText)
        try SourceEditor().replace(original, with: "Save & confirm {changes}")
        #expect(try String(contentsOf: file, encoding: .utf8) == source.replacingOccurrences(
            of: "Save changes", with: "Save &amp; confirm &#123;changes&#125;"))
        #expect(StringScanner().scan(projectURL: root).occurrences.contains { $0.value == "Save & confirm {changes}" })
    }

    @Test func jsxSyntaxInsideCommentsStringsAndRegexesIsNotMarkup() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.tsx")
        try #"""
        // <button>Comment text</button>
        const example = "<button>Example text</button>";
        const pattern = /<button title="Regex text"/;
        const view = <button title={format("Expression value")}>
          {/<span>Regex child<\/span>/.test(value) ? "Match found" : "No match"}
          Literal // text
        </button>;
        """#.write(to: file, atomically: true, encoding: .utf8)
        let occurrences = StringScanner().scan(projectURL: root).occurrences
        #expect(occurrences.filter { $0.style == .htmlText }.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                == ["Literal // text"])
        #expect(occurrences.contains { $0.value == "Expression value" && $0.style == .doubleQuoted })
        #expect(!occurrences.contains { $0.value.contains("Regex") || $0.value == "Comment text" })
    }

    @Test(arguments: ["m", "mm"])
    func objectiveCUniversalEscapesDecodeAndSaveWithoutChangingOtherText(ext: String) throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.\(ext)")
        try #"NSString *title = @"Launch \U0001F680 and \u2605 now";"#.write(to: file, atomically: true, encoding: .utf8)
        let original = try #require(StringScanner().scan(projectURL: root).occurrences.first)
        #expect(original.value == "Launch 🚀 and ★ now")
        #expect(original.isEditable)
        try SourceEditor().replace(original, with: original.value.replacingOccurrences(of: "now", with: "soon"))
        #expect(try String(contentsOf: file, encoding: .utf8) == #"NSString *title = @"Launch 🚀 and ★ soon";"#)
        #expect(StringScanner().scan(projectURL: root).occurrences.first?.value == "Launch 🚀 and ★ soon")
    }

    @Test func unicodeEscapeWidthsRemainLanguageSpecificAndMalformedEscapesAreReadOnly() {
        let strings = LiteralCodec.decode(#"Launch \U2605 now"#, style: .doubleQuoted, language: .strings)
        #expect(strings.supported && strings.value == "Launch ★ now")
        for raw in [#"Launch \U0001"#, #"Launch \U0001 now"#, #"Launch \U00110000 now"#, #"Launch \U0000D800 now"#] {
            let decoded = LiteralCodec.decode(raw, style: .doubleQuoted, language: .objectiveC)
            #expect(!decoded.supported && decoded.value == raw)
        }
    }

    @Test @MainActor func decisionsSurviveLineShiftsAndRelaunchButTextChangesNeedReview() async throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.swift")
        let store = ReviewStore(rootURL: root.appending(path: "reviews"))
        let source = "Text(\"Welcome home\")\nButton(\"Open account\") {}"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let model = AppModel(reviewStore: store, remembersProject: false)
        await model.openProject(root)
        let welcome = try #require(model.occurrences.first)
        let account = try #require(model.occurrences.last)
        model.approve(welcome)
        model.ignore(account)
        try ("// Added above\n\n    " + source.replacingOccurrences(of: "\n", with: "\n    "))
            .write(to: file, atomically: true, encoding: .utf8)

        let reopened = AppModel(reviewStore: store, remembersProject: false)
        await reopened.openProject(root)
        #expect(reopened.occurrences.map(\.id) == [welcome.id, account.id])
        #expect(reopened.approvedCount == 1)
        #expect(reopened.ignoredCount == 1)
        try "Text(\"Welcome again\")\nButton(\"Delete account\") {}"
            .write(to: file, atomically: true, encoding: .utf8)
        reopened.refresh()
        while reopened.isScanning { await Task.yield() }
        #expect(reopened.occurrences.map(\.id) == [welcome.id, account.id])
        #expect(reopened.reviewState(for: try #require(reopened.occurrences.first)) == .changed)
        #expect(reopened.ignoredCount == 0)
        #expect(reopened.reviewCount == 2)
    }

    @Test func ambiguousDuplicatesNeverInheritDecisionsAfterAnEdit() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.swift")
        let source = Array(repeating: "Text(\"Same message\")", count: 15).joined(separator: "\n")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let matcher = OccurrenceMatcher()
        let initial = matcher.reconcile(StringScanner().scan(projectURL: root).occurrences, with: ProjectReviewData())
        let state = ProjectReviewData(snapshots: initial.occurrences.map(OccurrenceSnapshot.init))
        let unchanged = matcher.reconcile(StringScanner().scan(projectURL: root).occurrences, with: state)
        #expect(unchanged.occurrences.map(\.id) == initial.occurrences.map(\.id))
        try ("// shift\n" + source).write(to: file, atomically: true, encoding: .utf8)
        let shifted = matcher.reconcile(StringScanner().scan(projectURL: root).occurrences, with: state)
        #expect(shifted.occurrences[7].id != initial.occurrences[7].id)
        try (source + "\nText(\"Same message\")").write(to: file, atomically: true, encoding: .utf8)
        let duplicated = matcher.reconcile(StringScanner().scan(projectURL: root).occurrences, with: state)
        #expect(Set(duplicated.occurrences.map(\.id)).isDisjoint(with: initial.occurrences.map(\.id)))
    }

    @Test func uniqueNeighborsDisambiguateDuplicatesAndMovesPreserveUniqueMatches() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.swift")
        let source = "// Header\nText(\"Same message\")\n// Footer\nText(\"Same message\")\nButton(\"Next screen\") {}"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let matcher = OccurrenceMatcher()
        let initial = matcher.reconcile(StringScanner().scan(projectURL: root).occurrences, with: ProjectReviewData())
        let state = ProjectReviewData(snapshots: initial.occurrences.map(OccurrenceSnapshot.init))
        // Whole-file shifts preserve the full nearby context for interior matches.
        try ("\n" + source + "\n").write(to: file, atomically: true, encoding: .utf8)
        let shifted = matcher.reconcile(StringScanner().scan(projectURL: root).occurrences, with: state)
        #expect(shifted.occurrences[1].id == initial.occurrences[1].id)
        try ("Button(\"Next screen\") {}\n" + source.replacingOccurrences(of: "\nButton(\"Next screen\") {}", with: ""))
            .write(to: file, atomically: true, encoding: .utf8)
        let moved = matcher.reconcile(StringScanner().scan(projectURL: root).occurrences, with: state)
        #expect(moved.occurrences.first?.id == initial.occurrences.last?.id)
    }

    @Test func fileAndStructuralChangesDoNotTransferIdentities() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.swift")
        try "Text(\"Same message\")".write(to: file, atomically: true, encoding: .utf8)
        let matcher = OccurrenceMatcher()
        let initial = matcher.reconcile(StringScanner().scan(projectURL: root).occurrences, with: ProjectReviewData())
        let state = ProjectReviewData(snapshots: initial.occurrences.map(OccurrenceSnapshot.init))
        try "Button(\"Same message\") {}".write(to: file, atomically: true, encoding: .utf8)
        let changedUse = matcher.reconcile(StringScanner().scan(projectURL: root).occurrences, with: state)
        #expect(changedUse.occurrences.first?.id != initial.occurrences.first?.id)
        try FileManager.default.moveItem(at: file, to: root.appending(path: "Other.swift"))
        let renamed = matcher.reconcile(StringScanner().scan(projectURL: root).occurrences, with: state)
        #expect(renamed.occurrences.first?.id != initial.occurrences.first?.id)
    }

    @Test @MainActor func savingAnEditKeepsItsApprovalAndOtherFileDecisions() async throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.swift")
        try "Text(\"First message\")\nText(\"Second message\")".write(to: file, atomically: true, encoding: .utf8)
        let store = ReviewStore(rootURL: root.appending(path: "reviews"))
        let model = AppModel(reviewStore: store, remembersProject: false)
        await model.openProject(root)
        let first = try #require(model.occurrences.first)
        let second = try #require(model.occurrences.last)
        model.approve(second)
        model.saveAndApprove("Edited message", for: first)
        while model.isScanning { await Task.yield() }
        #expect(model.presentedError == nil)
        #expect(model.approvedCount == 2)
        #expect(model.occurrences.map(\.id) == [first.id, second.id])
        let reopened = AppModel(reviewStore: store, remembersProject: false)
        await reopened.openProject(root)
        #expect(reopened.approvedCount == 2)
    }

    @Test func legacyMigrationKeepsOnlyUniqueExactApprovalsAndBacksUpOriginalData() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.swift")
        try "Text(\"First message\")\nText(\"Repeated message\")\nText(\"Repeated message\")"
            .write(to: file, atomically: true, encoding: .utf8)
        let scanned = StringScanner().scan(projectURL: root).occurrences
        let first = try #require(scanned.first)
        let old = ProjectReviewData(
            approvals: Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, ApprovalRecord(fingerprint: Hashing.sha256($0.rawValue), approvedAt: .now)) }),
            ignores: [first.ignoreID: IgnoreRecord(ignoredAt: .now)], schemaVersion: 1
        )
        let store = ReviewStore(rootURL: root.appending(path: "reviews"))
        try store.save(old, projectURL: root)
        let recordURL = root.appending(path: "reviews/" + Hashing.sha256(root.standardizedFileURL.path) + ".json")
        let original = try Data(contentsOf: recordURL)
        let migrated = OccurrenceMatcher().reconcile(scanned, with: try store.load(projectURL: root))
        #expect(migrated.approvals[migrated.occurrences[0].id] != nil)
        #expect(migrated.approvals[migrated.occurrences[1].id] == nil)
        #expect(migrated.ignores[migrated.occurrences[0].ignoreID] == nil)
        try store.save(ProjectReviewData(approvals: migrated.approvals, ignores: migrated.ignores,
                                        snapshots: migrated.occurrences.map(OccurrenceSnapshot.init)), projectURL: root)
        #expect(try Data(contentsOf: recordURL.appendingPathExtension("v1-backup")) == original)
        #expect(try store.load(projectURL: root).schemaVersion == 2)
    }

    @Test func unsupportedReviewVersionsCannotBeOverwritten() throws {
        let root = try temporaryDirectory()
        let store = ReviewStore(rootURL: root)
        let url = root.appending(path: Hashing.sha256(root.standardizedFileURL.path) + ".json")
        let json = #"{"schemaVersion":99,"approvals":{},"ignores":{},"snapshots":[]}"#
        try json.write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try store.load(projectURL: root) }
        #expect(throws: (any Error).self) { try store.save(ProjectReviewData(), projectURL: root) }
        #expect(try String(contentsOf: url, encoding: .utf8) == json)
    }

    @Test(arguments: [
        ("Localizable.strings", #""welcome" = "Welcome home";"#),
        ("Localizable.xcstrings", #"{"strings":{"Welcome home":{}}}"#),
        ("messages.json", #"{"welcome":"Welcome home"}"#),
        ("View.tsx", #"const view = <button title="Welcome home" />;"#),
        ("View.swift", "Text(\"\"\"\nWelcome home\n\"\"\")"),
        ("View.m", #"self.title = @"Welcome home";"#),
        ("View.xib", #"<button title="Welcome home"/>"#),
        ("index.html", "<p>Welcome home</p>")
    ])
    func identitiesSurviveBlankLinesAcrossSupportedFormats(filename: String, source: String) throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: filename)
        try source.write(to: file, atomically: true, encoding: .utf8)
        let matcher = OccurrenceMatcher()
        let initial = matcher.reconcile(StringScanner().scan(projectURL: root).occurrences, with: ProjectReviewData())
        #expect(!initial.occurrences.isEmpty)
        try ("\n\n" + source + "\n").write(to: file, atomically: true, encoding: .utf8)
        let shifted = matcher.reconcile(StringScanner().scan(projectURL: root).occurrences,
                                        with: ProjectReviewData(snapshots: initial.occurrences.map(OccurrenceSnapshot.init)))
        #expect(shifted.occurrences.map(\.id) == initial.occurrences.map(\.id))
    }

    @Test @MainActor func removedStringsDoNotResurrectOldApprovals() async throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "View.swift")
        let source = "Text(\"Welcome home\")"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let model = AppModel(reviewStore: ReviewStore(rootURL: root.appending(path: "reviews")), remembersProject: false)
        await model.openProject(root)
        let original = try #require(model.occurrences.first)
        model.approve(original)
        try "// Removed".write(to: file, atomically: true, encoding: .utf8)
        model.refresh()
        while model.isScanning { await Task.yield() }
        #expect(model.occurrences.isEmpty)
        try source.write(to: file, atomically: true, encoding: .utf8)
        model.refresh()
        while model.isScanning { await Task.yield() }
        #expect(model.occurrences.first?.id != original.id)
        #expect(model.reviewCount == 1)
    }

    @Test func readsBothLegacyReviewFormatsWithoutInventingSnapshots() throws {
        let root = try temporaryDirectory()
        let store = ReviewStore(rootURL: root)
        let url = root.appending(path: Hashing.sha256(root.standardizedFileURL.path) + ".json")
        let approval = #"{"View.swift:1:7":{"fingerprint":"test","approvedAt":"2026-01-01T00:00:00Z"}}"#
        for json in [approval, "{\"approvals\":\(approval),\"ignores\":{}}"] {
            try json.write(to: url, atomically: true, encoding: .utf8)
            let loaded = try store.load(projectURL: root)
            #expect(loaded.schemaVersion == 1)
            #expect(loaded.snapshots.isEmpty)
            #expect(loaded.approvals["View.swift:1:7"]?.fingerprint == "test")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = project.appending(path: ".build/test-fixtures", directoryHint: .isDirectory)
            .appending(path: "StringIntoActionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func occurrence(path: String, line: Int, value: String) -> StringOccurrence {
        StringOccurrence(
            id: "\(path):\(line):1",
            fileURL: URL(fileURLWithPath: "/tmp").appending(path: path),
            relativePath: path,
            line: line,
            column: 1,
            value: value,
            rawValue: value,
            contextLines: [],
            contentRange: NSRange(location: 0, length: value.utf16.count),
            sourceFingerprint: "source",
            language: .swift,
            style: .doubleQuoted,
            isEditable: true,
            confidence: .review,
            detectionReason: "Test",
            role: .userInterface
        )
    }
}

private actor ScanGate {
    private var pending: [URL: CheckedContinuation<ScanResult, Never>] = [:]
    private var started: [URL: CheckedContinuation<Void, Never>] = [:]

    func scan(_ url: URL) async -> ScanResult {
        await withCheckedContinuation { continuation in
            pending[url] = continuation
            started.removeValue(forKey: url)?.resume()
        }
    }

    func waitUntilStarted(_ url: URL) async {
        if pending[url] != nil { return }
        await withCheckedContinuation { started[url] = $0 }
    }

    func finish(_ url: URL, filesScanned: Int) {
        pending.removeValue(forKey: url)?.resume(returning: ScanResult(occurrences: [], filesScanned: filesScanned))
    }
}
