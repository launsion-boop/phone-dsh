// SPDX-License-Identifier: MIT

import Foundation
import MessageUI
import SwiftUI
import Translation
import UIKit

extension OfficePresenter {
    public func composeMail(to recipients: [String], subject: String, body: String) async throws -> String {
        guard let presenter = OfficeSystemPresenter.topViewController() else {
            throw OfficeToolError.unavailable("找不到邮件草稿展示页面")
        }
        return await withCheckedContinuation { continuation in
            let controller = MFMailComposeViewController()
            controller.setToRecipients(recipients)
            controller.setSubject(subject)
            controller.setMessageBody(body, isHTML: false)
            let delegate = MailComposerDelegate { result in
                controller.dismiss(animated: true)
                continuation.resume(returning: result)
            }
            controller.mailComposeDelegate = delegate
            objc_setAssociatedObject(controller, &OfficeSystemPresenter.mailDelegateKey, delegate,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            presenter.present(controller, animated: true)
        }
    }

    public func translate(text: String, source: String?, target: String) async throws -> String {
        guard #available(iOS 18.0, *) else {
            throw OfficeToolError.unavailable("系统翻译需要 iOS 18 或更新版本")
        }
        guard translationContinuation == nil else {
            throw OfficeToolError.unavailable("已有翻译操作在进行")
        }
        guard let presenter = OfficeSystemPresenter.topViewController() else {
            throw OfficeToolError.unavailable("找不到系统翻译展示页面")
        }
        return try await withTaskCancellationHandler {
            let deadline = interactionDeadline { [weak self] in
                self?.finishTranslation(with: .failure(OfficeToolError.unavailable("系统翻译等待超时")))
            }
            defer { deadline.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                translationContinuation = continuation
                let view = OfficeTranslationTaskView(text: text, source: source, target: target) { [weak self] result in
                    self?.finishTranslation(with: result)
                }
                let controller = UIHostingController(rootView: view)
                translationController = controller
                controller.modalPresentationStyle = .formSheet
                presenter.present(controller, animated: true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishTranslation(with: .failure(OfficeToolError.cancelled))
            }
        }
    }

    func finishTranslation(with result: Result<String, Error>) {
        guard let continuation = translationContinuation else { return }
        translationContinuation = nil
        let controller = translationController
        translationController = nil
        if controller?.presentingViewController != nil {
            controller?.dismiss(animated: true) { continuation.resume(with: result) }
        } else {
            continuation.resume(with: result)
        }
    }
}

private enum OfficeSystemPresenter {
    static var mailDelegateKey = 0

    static func topViewController() -> UIViewController? {
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

private final class MailComposerDelegate: NSObject, MFMailComposeViewControllerDelegate {
    private let completion: (String) -> Void

    init(completion: @escaping (String) -> Void) {
        self.completion = completion
    }

    func mailComposeController(_ controller: MFMailComposeViewController,
                               didFinishWith result: MFMailComposeResult, error: Error?) {
        if let error {
            completion("draft_error: \(error.localizedDescription)")
            return
        }
        switch result {
        case .cancelled: completion("draft_cancelled")
        case .saved: completion("draft_saved")
        case .sent: completion("sent_by_user")
        case .failed: completion("draft_failed")
        @unknown default: completion("draft_unknown")
        }
    }
}

@available(iOS 18.0, *)
private struct OfficeTranslationTaskView: View {
    let text: String
    let source: String?
    let target: String
    let completion: (Result<String, Error>) -> Void
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("正在准备系统翻译…")
            Text("翻译使用 Apple 语言能力；若缺少离线语言包，系统可能请求下载。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("取消翻译", role: .cancel) {
                completion(.failure(OfficeToolError.cancelled))
            }
        }
        .padding(32)
        .frame(minWidth: 280)
        .onAppear {
            configuration = TranslationSession.Configuration(
                source: source.map { Locale.Language(identifier: $0) },
                target: Locale.Language(identifier: target))
        }
        .translationTask(configuration) { session in
            do {
                let response = try await session.translate(text)
                await MainActor.run { completion(.success(response.targetText)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }
}
