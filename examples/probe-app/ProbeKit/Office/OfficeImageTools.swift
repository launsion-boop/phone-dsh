// SPDX-License-Identifier: MIT

import Foundation
import UIKit
import Vision

public actor OfficeImageTools {
    private let store: OfficeArtifactStore

    public init(store: OfficeArtifactStore) {
        self.store = store
    }

    public func ocr(artifactID: String, languages: [String]) async throws -> [String: Any] {
        let ref = try await store.metadata(for: artifactID)
        guard ref.mediaType.hasPrefix("image/"), ref.byteCount <= 8 * 1024 * 1024 else {
            throw OfficeToolError.unsupported("OCR 只接受不超过 8 MiB 的图片 Artifact")
        }
        let data = try await store.read(artifactID, range: 0..<ref.byteCount)
        guard let source = UIImage(data: data), let image = source.cgImage else {
            throw OfficeToolError.unsupported("无法解码图片")
        }
        let observations = try await Self.recognize(image: image, languages: languages)
        let lines: [[String: Any]] = observations.enumerated().map { index, observation in
            let box = observation.boundingBox
            return [
                "locator": "image[0].line[\(index)]",
                "text": observation.topCandidates(1).first?.string ?? "",
                "confidence": observation.confidence,
                "boundingBox": [box.origin.x, box.origin.y, box.size.width, box.size.height],
            ]
        }
        return [
            "fileId": artifactID,
            "sourceHash": ref.sha256,
            "engine": "Apple Vision",
            "mode": "optional-ocr",
            "lines": lines,
            "notFound": lines.isEmpty,
        ]
    }

    public func chart(object: [String: Any]) async throws -> OfficeArtifactRef {
        let ir = try OfficeIR.decode(OfficeChartIR.self, object: object)
        try ir.validated()
        let numbers = try ir.values.map { try OfficeIR.number($0) }
        let doubles = numbers.map { NSDecimalNumber(decimal: $0).doubleValue }
        let minimum = min(0, doubles.min() ?? 0)
        let maximum = max(0, doubles.max() ?? 0)
        let range = maximum == minimum ? 1.0 : maximum - minimum
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 640), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 960, height: 640))
            let title = ir.title as NSString
            title.draw(in: CGRect(x: 36, y: 24, width: 888, height: 42),
                       withAttributes: [.font: UIFont.systemFont(ofSize: 25, weight: .semibold),
                                        .foregroundColor: UIColor.black])
            let plot = CGRect(x: 56, y: 92, width: 848, height: 390)
            UIColor(white: 0.82, alpha: 1).setStroke()
            let baseline = plot.maxY - CGFloat((0 - minimum) / range) * plot.height
            context.cgContext.setLineWidth(1)
            context.cgContext.move(to: CGPoint(x: plot.minX, y: baseline))
            context.cgContext.addLine(to: CGPoint(x: plot.maxX, y: baseline))
            context.cgContext.strokePath()
            let column = plot.width / CGFloat(doubles.count)
            for (index, value) in doubles.enumerated() {
                let x = plot.minX + CGFloat(index) * column
                let end = plot.maxY - CGFloat((value - minimum) / range) * plot.height
                let rect = CGRect(x: x + column * 0.18, y: min(baseline, end),
                                  width: column * 0.64, height: max(2, abs(end - baseline)))
                (value < 0 ? UIColor.systemOrange : UIColor.systemBlue).setFill()
                context.fill(rect)
                let valueText = NSDecimalNumber(decimal: numbers[index]).stringValue as NSString
                valueText.draw(in: CGRect(x: x, y: min(baseline, end) - 24, width: column, height: 22),
                               withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                                                .foregroundColor: UIColor.darkGray,
                                                .paragraphStyle: Self.centered])
                let label = ir.labels[index] as NSString
                label.draw(in: CGRect(x: x, y: plot.maxY + 14, width: column, height: 72),
                           withAttributes: [.font: UIFont.systemFont(ofSize: 12),
                                            .foregroundColor: UIColor.darkGray,
                                            .paragraphStyle: Self.centered])
            }
            let note = "Phone DSH · native code rendering · preview image" as NSString
            note.draw(in: CGRect(x: 36, y: 596, width: 888, height: 22),
                      withAttributes: [.font: UIFont.systemFont(ofSize: 11),
                                       .foregroundColor: UIColor.gray])
        }
        guard let data = image.pngData() else { throw OfficeToolError.unavailable("图表 PNG 编码失败") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(ir.fileName)
        try data.write(to: url, options: .atomic)
        return try await store.importFile(at: url)
    }

    private static let centered: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()

    private static func recognize(image: CGImage, languages: [String]) async throws -> [VNRecognizedTextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OfficeToolError.unavailable("Vision OCR 失败：\(error.localizedDescription)"))
                } else {
                    continuation.resume(returning: request.results as? [VNRecognizedTextObservation] ?? [])
                }
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if #available(iOS 16.0, *) { request.automaticallyDetectsLanguage = languages.isEmpty }
            if !languages.isEmpty { request.recognitionLanguages = languages }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: OfficeToolError.unavailable("Vision OCR 失败：\(error.localizedDescription)"))
                }
            }
        }
    }
}
