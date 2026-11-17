// DownloadResolutionTests.swift
// ZiroEdgeTests
//
// CDN resolution is the gap between "the user tapped Download" and "bytes are
// moving". Every outcome has to leave the task's resolution handle cleared: a
// handle that outlives its request makes the transfer look like it is still
// resolving, which pins the stuck watchdog for the life of the process.

import XCTest
@testable import ZiroEdge

@MainActor
final class DownloadResolutionTests: XCTestCase {

    private var manager: DownloadManager!
    private var model: AIModel!
    private var key: String!
    private var canonicalURL: URL!

    override func setUp() {
        super.setUp()
        manager = DownloadManager()
        model = ModelRegistry.llama32_3B
        key = manager.artifactTaskKey(model: model, artifact: .base)
        canonicalURL = model.baseURL
    }

    override func tearDown() {
        for catalogModel in ModelRegistry.allModels {
            ModelManagerService.deleteModel(catalogModel)
        }
        manager = nil
        super.tearDown()
    }

    /// A resolution request that was handed to the session but never started, so
    /// it can stand in for "resolution still in flight" without touching the network.
    private func pendingResolutionTask() -> URLSessionDataTask {
        URLSession.shared.dataTask(with: URL(string: "https://example.invalid/model.gguf")!)
    }

    func testPausedResolutionClearsItsHandleAndStartsNoBytes() {
        let task = DownloadTask(model: model, artifact: .base)
        task.isPaused = true
        task.state = .paused(progress: 0.0)
        task.resolutionTask = pendingResolutionTask()
        manager.activeTasks[key] = task
        manager.updateStatus(model: model)

        manager.finishCDNResolution(
            task: task,
            key: key,
            resolvedURL: URL(string: "https://cdn.example.com/model.gguf"),
            canonicalURL: canonicalURL
        )

        XCTAssertNil(task.resolutionTask, "a finished resolution must not stay attached")
        XCTAssertNil(task.task, "a paused task must not start a URLSession transfer")
        XCTAssertFalse(task.isChunked, "a paused task must not enter the chunked path")
        XCTAssertEqual(task.state, .paused(progress: 0.0))
    }

    func testPausedResolutionDoesNotPinTheStuckWatchdog() {
        let task = DownloadTask(model: model, artifact: .base)
        task.isPaused = true
        task.state = .paused(progress: 0.0)
        task.resolutionTask = pendingResolutionTask()
        manager.activeTasks[key] = task

        manager.finishCDNResolution(
            task: task,
            key: key,
            resolvedURL: nil,
            canonicalURL: canonicalURL
        )

        // A task left holding a resolution handle is a watchdog candidate forever,
        // which is what kept the 30 s timer alive after every paused download.
        XCTAssertFalse(
            manager.hasWatchdogCandidates,
            "a parked task must not keep the stuck watchdog scheduled"
        )
    }

    func testSupersededResolutionClearsItsHandleAndLeavesTheReplacementAlone() {
        let superseded = DownloadTask(model: model, artifact: .base)
        superseded.resolutionTask = pendingResolutionTask()
        let replacement = DownloadTask(model: model, artifact: .base)
        manager.activeTasks[key] = replacement

        manager.finishCDNResolution(
            task: superseded,
            key: key,
            resolvedURL: URL(string: "https://cdn.example.com/model.gguf"),
            canonicalURL: canonicalURL
        )

        XCTAssertNil(superseded.resolutionTask)
        XCTAssertNil(superseded.task, "the superseded task must not start bytes")
        XCTAssertIdentical(manager.activeTasks[key], replacement)
        XCTAssertNil(replacement.task, "the replacement owns its own start")
    }

    func testCancelledResolutionClearsItsHandleAndStartsNoBytes() {
        let task = DownloadTask(model: model, artifact: .base)
        task.isCancelled = true
        task.resolutionTask = pendingResolutionTask()
        manager.activeTasks[key] = task

        manager.finishCDNResolution(
            task: task,
            key: key,
            resolvedURL: URL(string: "https://cdn.example.com/model.gguf"),
            canonicalURL: canonicalURL
        )

        XCTAssertNil(task.resolutionTask)
        XCTAssertNil(task.task, "a cancelled task must not start bytes")
    }

    func testResolutionFallsBackToTheCanonicalURLWhenNoRedirectCameBack() {
        // The fallback URL is the catalogue URL, never a nil or an empty host:
        // that is what keeps an offline HEAD failure from stranding the task.
        let task = DownloadTask(model: model, artifact: .base)
        task.isCancelled = true
        task.resolutionTask = pendingResolutionTask()
        manager.activeTasks[key] = task

        manager.finishCDNResolution(task: task, key: key, resolvedURL: nil, canonicalURL: canonicalURL)

        XCTAssertNil(task.task)
        XCTAssertNil(task.resolutionTask)
        XCTAssertEqual(canonicalURL.host(), "huggingface.co")
    }
}
