import XCTest
@testable import parrot

private actor WarmupCallCounter {
    private(set) var count = 0

    func record() -> Bool {
        count += 1
        return count == 1
    }
}

final class RuntimeWarmupTests: XCTestCase {
    func testModelWarmupSchedulerRunsAndStops() async {
        let firstWarmup = expectation(description: "scheduled warm-up")
        let counter = WarmupCallCounter()
        let scheduler = ModelWarmupScheduler(interval: 0.01) {
            if await counter.record() { firstWarmup.fulfill() }
            return true
        }

        scheduler.start()
        await fulfillment(of: [firstWarmup], timeout: 1)
        scheduler.stop()

        let observedCalls = await counter.count
        XCTAssertGreaterThanOrEqual(observedCalls, 1)
    }

    func testDefaultWarmupIntervalIsLongEnoughToAvoidBusyPolling() {
        XCTAssertEqual(ModelWarmupScheduler.defaultInterval, 5 * 60)
    }
}
