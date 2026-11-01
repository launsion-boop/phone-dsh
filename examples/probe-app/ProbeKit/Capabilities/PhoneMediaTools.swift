// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import Speech
import UIKit

@MainActor
public struct PhoneMediaTools {
    private let store: OfficeArtifactStore
    private let presenter: PhoneCapabilityPresenter

    public init(store: OfficeArtifactStore = .shared,
                presenter: PhoneCapabilityPresenter = .shared) {
        self.store = store
        self.presenter = presenter
    }

    public func capture(object: [String: Any]) async throws -> PhoneToolPayload {
        _ = try PhoneToolEnvelope.text(object, "purpose", limit: 200)
        let data = try await presenter.capturePhoto()
        let ref = try await importData(data, fileName: "camera-\(UUID().uuidString).jpg")
        return PhoneToolPayload(data: [
            "fileId": ref.artifactID, "file": Self.reference(ref), "status": "captured",
        ])
    }

    public func scanDocument(object: [String: Any]) async throws -> PhoneToolPayload {
        let pages = try await presenter.scanDocument()
        guard !pages.isEmpty else { throw PhoneToolError.noData("没有扫描到文稿页面") }
        guard pages.count <= 8 else { throw PhoneToolError.invalidArguments("一次最多扫描 8 页") }
        let data = Self.pdf(images: pages)
        let ref = try await importData(data, fileName: "scan-\(UUID().uuidString).pdf")
        return PhoneToolPayload(data: [
            "fileId": ref.artifactID, "file": Self.reference(ref), "status": "scanned",
            "pages": pages.count, "pageCount": pages.count,
        ])
    }

    public func record(object: [String: Any]) async throws -> PhoneToolPayload {
        try PhoneToolEnvelope.requireConfirmation(object)
        _ = try PhoneToolEnvelope.text(object, "purpose", limit: 200)
        let duration = try PhoneToolEnvelope.integer(object, "maxSeconds", default: 5,
                                                     minimum: 1, maximum: 600)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-dsh-audio-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        guard recorder.record(forDuration: TimeInterval(duration)) else {
            throw PhoneToolError.unavailable(.microphone, "系统录音器无法开始录音")
        }
        do {
            try await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
            recorder.stop()
        } catch {
            recorder.stop()
            throw PhoneToolError.cancelled
        }
        let ref = try await store.importFile(at: url)
        return PhoneToolPayload(data: [
            "fileId": ref.artifactID, "file": Self.reference(ref), "status": "recorded",
            "durationSeconds": duration,
        ])
    }

    public func transcribe(object: [String: Any]) async throws -> PhoneToolPayload {
        let fileID = try PhoneToolEnvelope.text(object, "fileId", limit: 128) ?? ""
        guard fileID.hasPrefix("art_") else { throw PhoneToolError.invalidArguments("fileId 格式无效") }
        let locale: String
        if object["language"] != nil {
            locale = try PhoneToolEnvelope.text(object, "language", limit: 20) ?? "zh-CN"
        } else {
            locale = try PhoneToolEnvelope.text(object, "locale", required: false, limit: 20) ?? "zh-CN"
        }
        _ = try await store.metadata(for: fileID)
        let url = try await store.fileURL(for: fileID)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            throw PhoneToolError.unavailable(.speech, "系统语音识别器当前不可用")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw PhoneToolError.unavailable(.speech, "该语言不支持设备端语音识别；不会上传音频")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let rawText = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let lock = NSLock()
            var resumed = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                lock.lock()
                guard !resumed else {
                    lock.unlock()
                    return
                }
                if let error {
                    resumed = true
                    lock.unlock()
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    lock.unlock()
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else {
                    lock.unlock()
                }
            }
        }
        guard !rawText.isEmpty else { throw PhoneToolError.noData("没有识别到语音内容") }
        return PhoneToolPayload(data: [
            "fileId": fileID, "text": String(rawText.prefix(5000)),
            "language": locale, "locale": locale,
            "engine": "Apple Speech", "onDevice": true,
        ], truncated: rawText.count > 5000)
    }

    private func importData(_ data: Data, fileName: String) async throws -> OfficeArtifactRef {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
        return try await store.importFile(at: url)
    }

    private static func reference(_ ref: OfficeArtifactRef) -> [String: Any] {
        [
            "fileId": ref.artifactID, "name": ref.name, "mediaType": ref.mediaType,
            "byteCount": ref.byteCount, "sha256": ref.sha256,
        ]
    }

    private static func pdf(images: [Data]) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            for data in images {
                context.beginPage()
                guard let image = UIImage(data: data) else { continue }
                let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: (bounds.width - size.width) / 2,
                                      y: (bounds.height - size.height) / 2,
                                      width: size.width, height: size.height))
            }
        }
    }
}
