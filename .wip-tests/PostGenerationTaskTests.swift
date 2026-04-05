import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

// MARK: - PostGenerationTask Tests

/// Tests for ``ChatViewModel/postGenerationTasks`` lifecycle:
/// invocation, execution order, error isolation, and cancellation on session reset.
@MainActor
final class PostGenerationTaskTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var mock: MockInferenceBackend!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        let schema = Schema(BaseChatSchema.allModelTypes)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Hello", " world"]

        let service = InferenceService(backend: mock, name: "MockPost")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(modelContext: context)

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(modelContext: context)
    }

    override func tearDown() async throws {
        vm = nil
        sessionManager = nil
        mock = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func createAndActivateSession(title: String = "Test") -> ChatSessionRecord {
        let session = try! sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        vm.switchToSession(session)
        return session
    }

    /// Waits until `backgroundTask` is nil or has completed, up to `timeout`.
    private func awaitBackgroundTaskCompletion(timeout: TimeInterval = 2.0) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if vm.backgroundTask == nil { return }
            // Check if the task value is available (task finished)
            let task = vm.backgroundTask
            if await withTaskGroup(of: Bool.self, returning: Bool.self, body: { group in
                group.addTask {
                    await task?.value
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(10))
                    return false
                }
                return await group.next() ?? false
            }) { return }
        }
    }

    // MARK: - Basic Invocation

    func test_postGenerationTask_calledAfterGeneration() async throws {
        createAndActivateSession()
        let task = MockPostGenerationTask()
        vm.postGenerationTasks = [task]

        mock.tokensToYield = ["Hello", " world"]
        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        XCTAssertEqual(task.callCount, 1, "Task should be called once after generation")
    }

    func test_postGenerationTask_receivesCompletedMessage() async {
        createAndActivateSession()
        let task = MockPostGenerationTask()
        vm.postGenerationTasks = [task]

        mock.tokensToYield = ["Hello", " world"]
        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        XCTAssertEqual(task.receivedMessages.first?.content, "Hello world")
        XCTAssertEqual(task.receivedMessages.first?.role, .assistant)
    }

    func test_postGenerationTask_receivesActiveSession() async {
        let session = createAndActivateSession(title: "My Session")
        let task = MockPostGenerationTask()
        vm.postGenerationTasks = [task]

        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        XCTAssertEqual(task.receivedSessions.first?.id, session.id)
    }

    // MARK: - Execution Order

    func test_multiplePostGenerationTasks_runInRegistrationOrder() async {
        createAndActivateSession()

        var callOrder: [Int] = []
        // Use actors to safely capture call order from the detached context.
        let order = ActorBox<[Int]>([])

        let task1 = OrderCapturingTask(index: 1, box: order)
        let task2 = OrderCapturingTask(index: 2, box: order)
        let task3 = OrderCapturingTask(index: 3, box: order)

        vm.postGenerationTasks = [task1, task2, task3]

        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        callOrder = await order.value
        XCTAssertEqual(callOrder, [1, 2, 3], "Tasks must run in registration order")
    }

    // MARK: - Error Isolation

    func test_throwingTask_doesNotCancelSubsequentTasks() async {
        createAndActivateSession()

        struct TestError: Error {}
        let failingTask = MockPostGenerationTask()
        failingTask.errorToThrow = TestError()
        let followingTask = MockPostGenerationTask()

        vm.postGenerationTasks = [failingTask, followingTask]

        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        XCTAssertEqual(failingTask.callCount, 1, "Throwing task should still be called")
        XCTAssertEqual(followingTask.callCount, 1, "Task after a throwing task should still run")
    }

    func test_throwingTask_surfacesErrorInBackgroundTaskError() async {
        createAndActivateSession()

        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "Background error" }
        }

        let failingTask = MockPostGenerationTask()
        failingTask.errorToThrow = TestError()
        vm.postGenerationTasks = [failingTask]

        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        XCTAssertNotNil(vm.backgroundTaskError, "backgroundTaskError should be set when a task throws")
    }

    func test_successfulTask_doesNotSetBackgroundTaskError() async {
        createAndActivateSession()

        let task = MockPostGenerationTask()
        vm.postGenerationTasks = [task]

        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        XCTAssertNil(vm.backgroundTaskError, "backgroundTaskError should remain nil when tasks succeed")
    }

    // MARK: - Cancellation on Session Reset

    func test_postGenerationTask_cancelledOnSessionReset() async throws {
        createAndActivateSession(title: "Session A")
        let sessionB = createAndActivateSession(title: "Session B")

        // Switch back to A so we can switch to B during background task execution.
        let sessionA = try! sessionManager.createSession(title: "Session A2")
        vm.switchToSession(sessionA)

        let slowTask = MockPostGenerationTask()
        slowTask.runDelay = .seconds(10)  // Long enough to be in-flight on session switch.
        let quickTask = MockPostGenerationTask()
        vm.postGenerationTasks = [slowTask, quickTask]

        mock.tokensToYield = ["Hi"]
        vm.inputText = "Hello"
        await vm.sendMessage()

        // Background task is now running (slowTask sleeping for 10 s).
        // Immediately switch session — this should cancel the background task.
        vm.switchToSession(sessionB)

        // Give cooperative cancellation a moment to propagate.
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(quickTask.callCount, 0, "Task after cancelled task should not run")
    }

    // MARK: - No Task Fired for Empty Response

    func test_postGenerationTask_notCalledForEmptyResponse() async {
        createAndActivateSession()

        let task = MockPostGenerationTask()
        vm.postGenerationTasks = [task]

        mock.tokensToYield = []  // Empty stream — no content.
        vm.inputText = "Hi"
        await vm.sendMessage()

        // backgroundTask is nil (never scheduled) or finishes instantly with no calls.
        await vm.backgroundTask?.value

        XCTAssertEqual(task.callCount, 0, "Task should not be called when the assistant message is empty")
    }
}

// MARK: - Test Support

/// Sendable actor box for capturing ordered call indices across concurrency boundaries.
private actor ActorBox<T: Sendable> {
    var value: T
    init(_ initial: T) { value = initial }
    func set(_ newValue: T) { value = newValue }
}

private final class OrderCapturingTask: PostGenerationTask, @unchecked Sendable {
    let index: Int
    let box: ActorBox<[Int]>
    init(index: Int, box: ActorBox<[Int]>) {
        self.index = index
        self.box = box
    }
    func run(message: ChatMessageRecord, session: ChatSessionRecord) async throws {
        await box.set(await box.value + [index])
    }
}
