// SPDX-License-Identifier: MIT

import UIKit
import VisionKit

public enum PhoneCapabilityViewPresenter {
    @MainActor
    public static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        func descend(_ base: UIViewController?) -> UIViewController? {
            guard let base else { return nil }
            if let navigation = base as? UINavigationController { return descend(navigation.visibleViewController) }
            if let tab = base as? UITabBarController { return descend(tab.selectedViewController) }
            if let presented = base.presentedViewController { return descend(presented) }
            return base
        }
        return descend(window?.rootViewController)
    }
}

@MainActor
public final class PhoneCapabilityPresenter {
    public static let shared = PhoneCapabilityPresenter()

    private var photoContinuation: CheckedContinuation<Data, Error>?
    private var photoDelegate: PhoneCameraPickerDelegate?
    private var scanContinuation: CheckedContinuation<[Data], Error>?
    private var scanDelegate: PhoneDocumentScannerDelegate?

    public init() {}

    public func capturePhoto() async throws -> Data {
        guard photoContinuation == nil, scanContinuation == nil else {
            throw PhoneToolError.unavailable(.camera, "已有相机操作在进行")
        }
        guard UIImagePickerController.isSourceTypeAvailable(.camera),
              let presenter = PhoneCapabilityViewPresenter.topViewController() else {
            throw PhoneToolError.unavailable(.camera, "当前设备相机或展示页面不可用")
        }
        return try await withCheckedThrowingContinuation { continuation in
            photoContinuation = continuation
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
            let delegate = PhoneCameraPickerDelegate(
                picked: { [weak self] image in
                    guard let data = image?.jpegData(compressionQuality: 0.85) else {
                        self?.finishPhoto(.failure(PhoneToolError.unavailable(.camera, "无法编码拍摄照片")))
                        return
                    }
                    self?.finishPhoto(.success(data))
                },
                cancelled: { [weak self] in self?.finishPhoto(.failure(PhoneToolError.cancelled)) })
            photoDelegate = delegate
            picker.delegate = delegate
            presenter.present(picker, animated: true)
        }
    }

    public func scanDocument() async throws -> [Data] {
        guard photoContinuation == nil, scanContinuation == nil else {
            throw PhoneToolError.unavailable(.camera, "已有相机操作在进行")
        }
        guard VNDocumentCameraViewController.isSupported,
              let presenter = PhoneCapabilityViewPresenter.topViewController() else {
            throw PhoneToolError.unavailable(.camera, "当前设备不支持系统文稿扫描")
        }
        return try await withCheckedThrowingContinuation { continuation in
            scanContinuation = continuation
            let scanner = VNDocumentCameraViewController()
            let delegate = PhoneDocumentScannerDelegate(
                scanned: { [weak self] images in
                    let pages = images.compactMap { $0.jpegData(compressionQuality: 0.85) }
                    guard pages.count == images.count, !pages.isEmpty else {
                        self?.finishScan(.failure(PhoneToolError.unavailable(.camera, "无法编码扫描页面")))
                        return
                    }
                    self?.finishScan(.success(pages))
                },
                cancelled: { [weak self] in self?.finishScan(.failure(PhoneToolError.cancelled)) },
                failed: { [weak self] message in
                    self?.finishScan(.failure(PhoneToolError.unavailable(.camera, message)))
                })
            scanDelegate = delegate
            scanner.delegate = delegate
            presenter.present(scanner, animated: true)
        }
    }

    private func finishPhoto(_ result: Result<Data, Error>) {
        guard let photoContinuation else { return }
        self.photoContinuation = nil
        photoDelegate = nil
        photoContinuation.resume(with: result)
    }

    private func finishScan(_ result: Result<[Data], Error>) {
        guard let scanContinuation else { return }
        self.scanContinuation = nil
        scanDelegate = nil
        scanContinuation.resume(with: result)
    }
}

private final class PhoneCameraPickerDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let picked: (UIImage?) -> Void
    private let cancelled: () -> Void

    init(picked: @escaping (UIImage?) -> Void, cancelled: @escaping () -> Void) {
        self.picked = picked
        self.cancelled = cancelled
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picked(info[.originalImage] as? UIImage)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        cancelled()
    }
}

private final class PhoneDocumentScannerDelegate: NSObject, VNDocumentCameraViewControllerDelegate {
    private let scanned: ([UIImage]) -> Void
    private let cancelled: () -> Void
    private let failed: (String) -> Void

    init(scanned: @escaping ([UIImage]) -> Void, cancelled: @escaping () -> Void,
         failed: @escaping (String) -> Void) {
        self.scanned = scanned
        self.cancelled = cancelled
        self.failed = failed
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                      didFinishWith scan: VNDocumentCameraScan) {
        scanned((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        cancelled()
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                      didFailWithError error: Error) {
        failed(error.localizedDescription)
    }
}
