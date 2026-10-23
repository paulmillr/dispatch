import XCTest

/// The terminal mockups (T1 search, T2 the key bar's menu) in dark and light, from the Spaces sample's dev tab on
/// their screen (`-DispatchTerminalSample theme`), with a hardware keyboard pinned so no software keyboard covers
/// them, as in the renders. Each screenshot is attached and written to `build/mockup-review/<ID>-<scheme>.png`
/// beside the renders (`FidelityUITests.mockups`), to be looked at beside `mockups/shots/<ID>-*-<scheme>.png`.
extension FidelityUITests {
    func testTerminalScreens() throws {
        try FileManager.default.createDirectory(at: Self.mockups, withIntermediateDirectories: true)
        for scheme in ["dark", "light"] {
            for id in ["T1", "T2"] {
                let app = XCUIApplication()
                app.launchArguments = TerminalSearchUITests.arguments(hardwareKeyboard: true, scheme: scheme)
                app.launch()
                XCTAssertTrue(app.textViews["Terminal"].waitForExistence(timeout: 10))
                Thread.sleep(forTimeInterval: 1.5)
                TerminalSearchUITests.openMenu(app)
                if id == "T1" {
                    app.buttons["Search"].tap()
                    let field = app.textFields["Search terminal"]
                    XCTAssertTrue(field.waitForExistence(timeout: 5))
                    field.typeText("theme.ts")
                    app.buttons["Older match"].tap()
                }
                Thread.sleep(forTimeInterval: 1.5)
                let shot = XCUIScreen.main.screenshot()
                let data = try XCTUnwrap(shot.image.pngData())
                try data.write(to: Self.mockups.appendingPathComponent("\(id)-\(scheme).png"))
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "\(id)-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }
}
