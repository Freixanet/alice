import XCTest
@testable import Alice

final class LocalModelsTests: XCTestCase {
    func testStatusPreservesRuntimeModelsLoadingAndPlacement() throws {
        let status = try DashboardClient.localModelsStatus(from: [
            "enabled": true,
            "tag": "b10679",
            "configured_tag": "b10680",
            "update_available": true,
            "runtime_installed": true,
            "runtime_backend": "metal",
            "server_running": true,
            "server_base_url": "http://127.0.0.1:8080/v1",
            "active_model_id": "Qwen-Q4",
            "loaded_models": ["Qwen-Q4": "loaded", "Vision-Q4": "loading"],
            "loading": ["Vision-Q4": ["stage": "loading", "value": 0.4, "percent": 40]],
            "placement": [
                "Qwen-Q4": [
                    "window": 65_536, "window_label": "64K", "spilled": true,
                    "granted_window": 32_768, "granted_window_label": "32K",
                ],
            ],
            "models": [["id": "Qwen-Q4", "size_bytes": 8_000_000_000, "size_label": "7.5 GB"]],
            "models_dir": "/Users/test/.hermes/models",
        ])

        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.runtimeBackend, "metal")
        XCTAssertEqual(status.loadedModels["Qwen-Q4"], "loaded")
        XCTAssertEqual(status.loading["Vision-Q4"]?.percent, 40)
        XCTAssertEqual(status.placement["Qwen-Q4"]?.grantedWindow, 32_768)
        XCTAssertEqual(status.placement["Qwen-Q4"]?.spilled, true)
        XCTAssertEqual(status.models.first?.id, "Qwen-Q4")
        XCTAssertEqual(status.activeModelID, "Qwen-Q4")
    }

    func testMalformedStatusNeverBecomesEmptyStoppedRuntime() {
        XCTAssertThrowsError(try DashboardClient.localModelsStatus(from: [
            "enabled": false, "tag": "b10679",
        ]))
    }

    func testHardwarePreservesUnifiedMemoryBudgetAndNullableGPUFacts() throws {
        let hardware = try DashboardClient.localModelHardware(from: [
            "uma": true,
            "vram_total_bytes": NSNumber(value: 17_179_869_184 as Int64),
            "vram_usable_bytes": NSNumber(value: 4_018_847_744 as Int64),
            "ram_total_bytes": NSNumber(value: 17_179_869_184 as Int64),
            "ram_available_bytes": NSNumber(value: 5_016_653_824 as Int64),
            "vram_label": "16.0 GB",
            "gpu_name": NSNull(), "gpu_util_percent": NSNull(), "vram_used_bytes": NSNull(),
        ])

        XCTAssertTrue(hardware.uma)
        XCTAssertEqual(hardware.vramUsableBytes, 4_018_847_744)
        XCTAssertNil(hardware.gpuName)
        XCTAssertNil(hardware.gpuUtilPercent)
    }

    func testCatalogPreservesFitAndRefusalReasons() throws {
        let catalog = try DashboardClient.localModelCatalog(from: [
            "models": [
                [
                    "id": "small", "display_name": "Small", "description": "Fits",
                    "native_context": 131_072, "native_context_label": "128K",
                    "recommended": true, "recommended_reason": "best fit",
                    "downloaded": false, "downloaded_model_id": NSNull(), "downloaded_quant": NSNull(),
                    "mtp": false, "vision": false, "needs_engine": false, "min_engine": NSNull(),
                    "fits": true, "model_id": "Small-Q4", "quant": "Q4_K_M", "quant_validated": true,
                    "size_bytes": 4_000_000_000, "size_label": "3.7 GB", "variant_count": 3,
                    "quant_reason": "recommended", "fit_summary": "starts at 64K",
                    "start_window": 65_536, "start_window_label": "64K", "spilled": false,
                ],
                [
                    "id": "huge", "display_name": "Huge", "description": "Too big",
                    "native_context": 262_144, "native_context_label": "256K",
                    "recommended": false, "recommended_reason": NSNull(),
                    "downloaded": false, "downloaded_model_id": NSNull(), "downloaded_quant": NSNull(),
                    "mtp": true, "vision": true, "needs_engine": false, "min_engine": NSNull(),
                    "fits": false, "size_bytes": 112_000_000_000, "size_label": "104.3 GB",
                    "fit_summary": "Needs more memory than this machine has",
                    "fit_detail": "even the compact build exceeds GPU + system memory",
                ],
            ],
        ])

        XCTAssertEqual(catalog.count, 2)
        XCTAssertTrue(catalog[0].recommended)
        XCTAssertEqual(catalog[0].modelID, "Small-Q4")
        XCTAssertEqual(catalog[0].startWindow, 65_536)
        XCTAssertFalse(catalog[1].fits)
        XCTAssertTrue(catalog[1].fitDetail?.contains("exceeds") == true)
        XCTAssertNil(catalog[1].modelID)
    }

    func testJobsPreserveByteProgressAndErrors() throws {
        let jobs = try DashboardClient.localModelJobs(from: [
            "jobs": [
                [
                    "job_id": "abc123", "kind": "model-download", "target": "Qwen",
                    "model_id": "qwen", "status": "running", "phase": "downloading",
                    "detail": "Connecting", "total_bytes": 10_000, "done_bytes": 4_000,
                    "started_at": 1234.5, "error": NSNull(), "percent": 40,
                ],
                [
                    "job_id": "failed", "kind": "runtime-install", "target": "llama.cpp",
                    "model_id": NSNull(), "status": "error", "phase": "verifying-runtime",
                    "detail": "", "total_bytes": NSNull(), "done_bytes": 0,
                    "started_at": 1200.0, "error": "checksum failed",
                ],
            ],
        ])

        XCTAssertTrue(jobs[0].running)
        XCTAssertEqual(jobs[0].percent, 40)
        XCTAssertEqual(jobs[0].doneBytes, 4_000)
        XCTAssertFalse(jobs[1].running)
        XCTAssertEqual(jobs[1].error, "checksum failed")
    }

    func testAlreadyDownloadedResponseAllowsNullJobID() throws {
        let result = try DashboardClient.localModelDownloadStart(from: [
            "job_id": NSNull(), "already_downloaded": true, "model_id": "Qwen-Q4",
        ])
        XCTAssertNil(result.jobID)
        XCTAssertTrue(result.alreadyDownloaded)
        XCTAssertEqual(result.modelID, "Qwen-Q4")
    }

    func testHuggingFaceSearchAndFileGroupsPreserveGateAndFit() throws {
        let hits = try DashboardClient.localModelSearch(from: [
            "hits": [[
                "repo": "author/model-GGUF", "downloads": 1234, "likes": 56,
                "updated": "2026-09-07T00:00:00Z", "gated": true,
            ]],
        ])
        let files = try DashboardClient.localModelRepoFiles(from: [
            "files": [[
                "label": "Q4_K_M", "paths": ["model-00001-of-00002.gguf", "model-00002-of-00002.gguf"],
                "total_bytes": 9_000_000_000, "fit": "needs-ram",
            ]],
        ])

        XCTAssertTrue(hits[0].gated)
        XCTAssertEqual(hits[0].downloads, 1234)
        XCTAssertEqual(files[0].paths.count, 2)
        XCTAssertEqual(files[0].fit, "needs-ram")
    }

    func testRepoFileParserRejectsEmptyGGUFGroup() {
        XCTAssertThrowsError(try DashboardClient.localModelRepoFiles(from: [
            "files": [["label": "Q4", "paths": [String](), "total_bytes": 1, "fit": "unknown"]],
        ]))
    }
}
