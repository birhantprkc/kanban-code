import XCTest

/// Two masters at once, a Mac and an always-on box, as two demo servers
/// sharing one devices file:
///
///     .build/debug/kanban-code-remote-demo --port 7790 --machine "machine_mac:Rogerio's MacBook Pro" --pair iPhone
///     .build/debug/kanban-code-remote-demo --port 7791 --machine machine_box:rchaves-platform --cards box \
///         --foreign "machine_mac:Rogerio's MacBook Pro" --exit-when .claude/tmp/multi-master/ios/kill-box
///
/// KC_PAIR_LINK pairs the Mac (primary), KC_BOX_PAIR_LINK the box with the
/// same token, KC_BOX_EXIT_FILE is the box's --exit-when file. The box
/// lists a synced copy of the Mac's card_wait, which the phone must show
/// once, as the Mac's. The last test takes the box offline, so restart it
/// before running the class again.
final class MultiMasterTests: KanbanUITestCase {
    /// The Mac demo's machine name: as long as a real Mac's.
    static let mac = "Rogerio's MacBook Pro"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try launch(linkKey: "KC_PAIR_LINK", moreLinkKeys: ["KC_BOX_PAIR_LINK"])
    }

    func test1MergedBoardTagsEachCardWithItsMachine() throws {
        let boxCard = app.buttons["card-box_deploy"]
        let macCard = app.buttons["card-card_wait"]
        XCTAssertTrue(boxCard.waitForExistence(timeout: 15))
        XCTAssertTrue(macCard.waitForExistence(timeout: 15))
        sleep(1)
        shot("mm-01-merged-board")
        XCTAssertTrue(boxCard.label.contains("rchaves-platform"), boxCard.label)
        XCTAssertTrue(macCard.label.contains(Self.mac), macCard.label)
        // The box's synced copy of the Mac's card is not listed twice.
        XCTAssertEqual(app.buttons.matching(identifier: "card-card_wait").count, 1)

        app.buttons["machinesMenu"].tap()
        let studio = app.buttons["machine-\(Self.mac)"]
        let box = app.buttons["machine-rchaves-platform"]
        XCTAssertTrue(studio.waitForExistence(timeout: 5))
        XCTAssertTrue(studio.label.contains("Primary"), studio.label)
        XCTAssertTrue(studio.label.contains("Online") && box.label.contains("Online"), "\(studio.label) / \(box.label)")
        shot("mm-02-machines")
        box.tap()
        XCTAssertTrue(waitFor(5) { box.label.contains("Primary") && !studio.label.contains("Primary") }, box.label)
        shot("mm-03-machines-box-primary")
        studio.tap()
        XCTAssertTrue(waitFor(5) { studio.label.contains("Primary") })
        app.buttons["machinesDone"].tap()
    }

    /// card_busy has the long machine name, its column and seven PRs: the
    /// chips collapse or truncate, and nothing leaves the screen.
    func test1bRowsStayInsideTheScreen() throws {
        let busy = app.buttons["card-card_busy"]
        // The first launch after the simulator boots can take a while.
        XCTAssertTrue(busy.waitForExistence(timeout: 40))
        XCTAssertTrue(app.buttons["card-box_deploy"].waitForExistence(timeout: 15))
        sleep(1)
        shot("mm-01b-rows-fit")
        let screen = app.windows.firstMatch.frame
        for id in ["card_busy", "card_wait", "box_deploy", "box_backfill"] {
            let row = app.buttons["card-\(id)"]
            XCTAssertTrue(row.exists, id)
            for element in [row] + row.descendants(matching: .any).allElementsBoundByIndex {
                let frame = element.frame
                guard !frame.isEmpty else { continue }
                XCTAssertGreaterThanOrEqual(frame.minX, screen.minX - 0.5, "\(id): \(element.label) starts off screen: \(frame)")
                XCTAssertLessThanOrEqual(frame.maxX, screen.maxX + 0.5, "\(id): \(element.label) ends off screen: \(frame)")
            }
        }
        XCTAssertTrue(busy.label.contains("+"), "the PR chips did not collapse: \(busy.label)")
    }

    func test2PromptsGoToTheCardsOwnMachine() throws {
        openCard("box_deploy")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "cardMachine").firstMatch.waitForExistence(timeout: 5))
        send("Routed to the box")
        XCTAssertTrue(message(containing: "Got it: Routed to the box").waitForExistence(timeout: 15))
        shot("mm-04-box-card-chat")
        let box = try server("KC_BOX_PAIR_LINK"), mac = try server("KC_PAIR_LINK")
        XCTAssertTrue(try get(box, "v1/cards/box_deploy/transcript?limit=10").body.contains("Routed to the box"))
        XCTAssertEqual(try get(mac, "v1/cards/box_deploy").status, 404)

        goBack()
        openCard("card_wait")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "cardMachine").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "cardMachine").firstMatch.label.contains(Self.mac))
        send("Routed to the Mac")
        XCTAssertTrue(message(containing: "Got it: Routed to the Mac").waitForExistence(timeout: 15))
        shot("mm-05-mac-card-chat")
        XCTAssertTrue(try get(mac, "v1/cards/card_wait/transcript?limit=10").body.contains("Routed to the Mac"))
        XCTAssertFalse(try get(box, "v1/cards/card_wait/transcript?limit=10").body.contains("Routed to the Mac"))
    }

    func test3NewTaskRunsOnTheChosenMachine() throws {
        let newTask = app.buttons["newTask"]
        XCTAssertTrue(newTask.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["card-box_deploy"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitEnabled(newTask))
        newTask.tap()
        let picker = app.buttons["machinePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains(Self.mac), "the primary is the default: \(picker.label)")
        picker.tap()
        app.buttons["rchaves-platform"].firstMatch.tap()
        XCTAssertTrue(waitFor(5) { picker.label.contains("rchaves-platform") }, picker.label)
        let prompt = app.textViews["taskPrompt"].exists ? app.textViews["taskPrompt"] : app.textFields["taskPrompt"]
        prompt.tap()
        prompt.typeText("Back up the database")
        shot("mm-06-new-task-on-box")
        app.buttons["launchTask"].tap()
        let tag = app.descendants(matching: .any).matching(identifier: "cardMachine").firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 10))
        XCTAssertTrue(tag.label.contains("rchaves-platform"), tag.label)
        sleep(2)
        shot("mm-07-new-task-card")
        let box = try server("KC_BOX_PAIR_LINK"), mac = try server("KC_PAIR_LINK")
        XCTAssertTrue(try get(box, "v1/board").body.contains("Back up the database"))
        XCTAssertFalse(try get(mac, "v1/board").body.contains("Back up the database"))
    }

    func test4OfflineMachineKeepsItsCards() throws {
        XCTAssertTrue(app.buttons["card-box_deploy"].waitForExistence(timeout: 15))
        sleep(6) // the board cache writes at most every 5 s
        let exitFile = try XCTUnwrap(ProcessInfo.processInfo.environment["KC_BOX_EXIT_FILE"])
        FileManager.default.createFile(atPath: exitFile, contents: Data())

        let down = app.buttons["machineDown-rchaves-platform"]
        XCTAssertTrue(down.waitForExistence(timeout: 20), "the box never showed as offline")
        XCTAssertTrue(down.label.contains("Offline since"), down.label)
        // Off, the box's cards leave Live for their columns further down.
        let boxCard = app.buttons["card-box_deploy"]
        XCTAssertTrue(scrollTo(boxCard))
        XCTAssertTrue(boxCard.label.contains("offline"), boxCard.label)
        XCTAssertTrue(boxCard.label.contains("Machine offline"), "an offline machine's card still shows as live: \(boxCard.label)")
        XCTAssertFalse(app.buttons["card-card_wait"].label.contains("offline"))
        shot("mm-08-box-offline-board")

        boxCard.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "machineOffline").firstMatch.waitForExistence(timeout: 5))
        shot("mm-09-box-offline-card")
        goBack()

        app.buttons["newTask"].tap()
        let picker = app.buttons["machinePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        XCTAssertFalse(app.buttons["rchaves-platform"].exists, "an offline machine is offered for a new task")
        shot("mm-10-new-task-box-offline")
        app.buttons[Self.mac].firstMatch.tap()
        app.buttons["Cancel"].tap()

        // Relaunched with the box still off: its cards come from the cache.
        app.terminate()
        try launch(linkKey: "KC_PAIR_LINK", extraEnv: ["KANBANCODE_PAIR_ONLY": "0"])
        XCTAssertTrue(app.buttons["machineDown-rchaves-platform"].waitForExistence(timeout: 20))
        XCTAssertTrue(scrollTo(app.buttons["card-box_deploy"]))
        sleep(1)
        shot("mm-11-relaunch-box-cached")
    }

    // MARK: Helpers

    /// Scrolls the board down until `element` shows.
    private func scrollTo(_ element: XCUIElement) -> Bool {
        for _ in 0..<6 {
            if element.waitForExistence(timeout: 2), element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists
    }

    private func send(_ text: String) {
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText(text)
        app.buttons["send"].tap()
    }

    private struct Server {
        let base: String
        let token: String
    }

    /// The url and token of a pairing link.
    private func server(_ key: String) throws -> Server {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment[key])
        let items = try XCTUnwrap(URLComponents(string: link)?.queryItems)
        return Server(base: try XCTUnwrap(items.first { $0.name == "url" }?.value),
                      token: try XCTUnwrap(items.first { $0.name == "token" }?.value))
    }

    private func get(_ server: Server, _ path: String) throws -> (status: Int, body: String) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(server.base)/\(path)")))
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        var out: (Int, String) = (0, "")
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            out = ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data ?? Data(), as: UTF8.self))
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return out
    }
}
