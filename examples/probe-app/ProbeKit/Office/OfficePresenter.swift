// SPDX-License-Identifier: MIT

import Foundation
import QuickLook
import UIKit
import UniformTypeIdentifiers

public protocol OfficePresenting: Sendable {
    func pickDocuments() async throws -> [URL]
    func preview(_ url: URL) async throws
    func share(_ url: URL) async throws -> String
    func composeMail(to recipients: [String], subject: String, body: String) async throws -> String
    func translate(text: String, source: String?, target: String) async throws -> String
    func confirmCalendarEvent(title: String, start: String, end: String) async -> Bool
}

@MainActor
public final class OfficePresenter: OfficePresenting {
    private var pickerContinuation: CheckedContinuation<[URL], Error>?
    private var pickerDelegate: PickerDelegate?
    private var pickerController: UIDocumentPickerViewController?
    private var shareContinuation: CheckedContinuation<String, Never>?
    private var shareController: UIActivityViewController?
    private var previewController: QLPreviewController?
    private var previewDataSource: PreviewDataSource?
    private var previewContinuation: CheckedContinuation<Void, Never>?
    private var previewDelegate: PreviewDelegate?
    private var calendarConfirmation: CheckedContinuation<Bool, Never>?
    var translationContinuation: CheckedContinuation<String, Error>?
    var translationController: UIViewController?

    public init() {}

    public func pickDocuments() async throws -> [URL] {
        guard pickerContinuation == nil else { throw OfficeToolError.unavailable("已有文件选择操作在进行") }
        guard let presenter = Self.topViewController() else {
            throw OfficeToolError.unavailable("找不到文件选择器展示页面")
        }
        return try await withTaskCancellationHandler {
            let deadline = interactionDeadline { [weak self] in
                self?.finishPicker(with: .failure(OfficeToolError.unavailable("文件选择等待超时")),
                                   dismissing: true)
            }
            defer { deadline.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                pickerContinuation = continuation
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
                picker.allowsMultipleSelection = false
                let delegate = PickerDelegate(
                    didPick: { [weak self] urls in
                        self?.finishPicker(with: .success(urls))
                    },
                    didCancel: { [weak self] in
                        self?.finishPicker(with: .failure(OfficeToolError.cancelled))
                    })
                pickerController = picker
                pickerDelegate = delegate
                picker.delegate = delegate
                picker.presentationController?.delegate = delegate
                presenter.present(picker, animated: true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishPicker(with: .failure(OfficeToolError.cancelled), dismissing: true)
            }
        }
    }

    private func finishPicker(with result: Result<[URL], Error>, dismissing: Bool = false) {
        guard let continuation = pickerContinuation else { return }
        pickerContinuation = nil
        pickerDelegate = nil
        let controller = pickerController
        pickerController = nil
        if dismissing, controller?.presentingViewController != nil {
            controller?.dismiss(animated: true) { continuation.resume(with: result) }
        } else {
            continuation.resume(with: result)
        }
    }

    func interactionDeadline(_ action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ChatHostConfiguration.defaultOfficeInteractionTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    public func preview(_ url: URL) async throws {
        guard previewContinuation == nil else { throw OfficeToolError.unavailable("已有预览操作在进行") }
        guard let presenter = Self.topViewController() else {
            throw OfficeToolError.unavailable("找不到预览展示页面")
        }
        return await withTaskCancellationHandler {
            let deadline = interactionDeadline { [weak self] in
                self?.finishPreview()
            }
            defer { deadline.cancel() }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                previewContinuation = continuation
                let dataSource = PreviewDataSource(url: url)
                if let controller = previewController, controller.presentingViewController != nil {
                    previewDataSource = dataSource
                    controller.dataSource = dataSource
                    controller.reloadData()
                    return
                }
                let controller = QLPreviewController()
                previewController = controller
                previewDataSource = dataSource
                controller.dataSource = dataSource
                controller.reloadData()
                let close = UIBarButtonItem(title: "关闭预览", style: .plain,
                                            target: self, action: #selector(dismissPreview))
                close.accessibilityLabel = "关闭预览"
                close.accessibilityIdentifier = "关闭预览"
                controller.navigationItem.rightBarButtonItem = close
                let navigation = UINavigationController(rootViewController: controller)
                navigation.modalPresentationStyle = .fullScreen
                let delegate = PreviewDelegate { [weak self] in
                    self?.finishPreview()
                }
                previewDelegate = delegate
                navigation.presentationController?.delegate = delegate
                presenter.present(navigation, animated: true) {
                    navigation.presentationController?.delegate = delegate
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishPreview()
            }
        }
    }

    @objc private func dismissPreview() {
        finishPreview()
    }

    private func finishPreview() {
        guard let continuation = previewContinuation else { return }
        previewContinuation = nil
        previewDelegate = nil
        let controller = previewController
        previewController = nil
        previewDataSource = nil
        if controller?.presentingViewController != nil {
            controller?.dismiss(animated: true) { continuation.resume() }
        } else {
            continuation.resume()
        }
    }

    public func confirmCalendarEvent(title: String, start: String, end: String) async -> Bool {
        guard calendarConfirmation == nil, let presenter = Self.topViewController() else { return false }
        return await withCheckedContinuation { continuation in
            calendarConfirmation = continuation
            let alert = UIAlertController(title: "创建日历事件？",
                                          message: "\(title)\n\(start) 至 \(end)\n仅此事件，不修改其它日程。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
                self?.calendarConfirmation?.resume(returning: false)
                self?.calendarConfirmation = nil
            })
            alert.addAction(UIAlertAction(title: "创建日程", style: .default) { [weak self] _ in
                self?.calendarConfirmation?.resume(returning: true)
                self?.calendarConfirmation = nil
            })
            presenter.present(alert, animated: true)
        }
    }

    private var shareDelegate: ShareDelegate?
    private var shareObservation: Task<Void, Never>?

    public func share(_ url: URL) async throws -> String {
        guard shareContinuation == nil else { throw OfficeToolError.unavailable("已有分享操作在进行") }
        guard let presenter = Self.topViewController() else {
            throw OfficeToolError.unavailable("找不到分享展示页面")
        }
        return await withTaskCancellationHandler {
            let deadline = interactionDeadline { [weak self] in
                self?.finishShare("timeout", dismissing: true)
            }
            defer { deadline.cancel() }
            return await withCheckedContinuation { continuation in
                shareContinuation = continuation
                let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                shareController = controller
                if let popover = controller.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                                y: presenter.view.bounds.maxY,
                                                width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                let delegate = ShareDelegate { [weak self] in
                    self?.finishShare("dismissed")
                }
                shareDelegate = delegate
                controller.presentationController?.delegate = delegate
                controller.completionWithItemsHandler = { [weak self] _, completed, _, error in
                    if let error {
                        self?.finishShare("failed: \(error.localizedDescription)")
                    } else {
                        self?.finishShare(completed ? "completed" : "cancelled")
                    }
                }
                presenter.present(controller, animated: true)
                controller.presentationController?.delegate = delegate
                shareObservation = Task { @MainActor [weak self, weak controller] in
                    var appeared = false
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard let self, let controller, self.shareContinuation != nil else { return }
                        if controller.presentingViewController != nil {
                            appeared = true
                        } else if appeared {
                            self.finishShare("dismissed")
                            return
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishShare("cancelled", dismissing: true)
            }
        }
    }

    private func finishShare(_ status: String, dismissing _: Bool = false) {
        guard let continuation = shareContinuation else { return }
        shareContinuation = nil
        shareDelegate = nil
        shareObservation?.cancel()
        shareObservation = nil
        let controller = shareController
        shareController = nil
        if controller?.presentingViewController != nil {
            controller?.dismiss(animated: true) { continuation.resume(returning: status) }
        } else {
            continuation.resume(returning: status)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        return topViewController(from: window?.rootViewController)
    }

    private static func topViewController(from base: UIViewController?) -> UIViewController? {
        guard let base else { return nil }
        if let navigation = base as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = base as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        if let presented = base.presentedViewController {
            return topViewController(from: presented)
        }
        return base
    }
}

private final class ShareDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
    private let didDismiss: () -> Void

    init(didDismiss: @escaping () -> Void) {
        self.didDismiss = didDismiss
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        didDismiss()
    }
}

private final class PickerDelegate: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private let didPick: ([URL]) -> Void
    private let didCancel: () -> Void

    init(didPick: @escaping ([URL]) -> Void, didCancel: @escaping () -> Void) {
        self.didPick = didPick
        self.didCancel = didCancel
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        didPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        didCancel()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        didCancel()
    }
}

private final class PreviewDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
    private let didDismiss: () -> Void

    init(didDismiss: @escaping () -> Void) {
        self.didDismiss = didDismiss
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        didDismiss()
    }
}

private final class PreviewDataSource: NSObject, QLPreviewControllerDataSource {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        url as QLPreviewItem
    }
}
