// SPDX-License-Identifier: MIT

import Foundation
import UIKit
import UniformTypeIdentifiers

public struct PhoneFolderRoot: Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    let url: URL?

    public init(id: String, name: String, kind: String, url: URL? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
    }
}

@MainActor
public final class PhoneFolderGrantStore {
    public static let shared = PhoneFolderGrantStore()

    private var grantedRoots: [PhoneFolderRoot] = []
    private let defaults: UserDefaults
    public private(set) var restoreError: String?
    private var continuation: CheckedContinuation<PhoneFolderRoot, Error>?
    private var delegate: PhoneFolderPickerDelegate?
    private var controller: UIDocumentPickerViewController?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let restored = PhoneFolderBookmarkStore.load(defaults: defaults)
        grantedRoots = restored.roots
        restoreError = restored.error
    }

    public var hasGrants: Bool {
        grantedRoots.contains(where: PhoneFolderBookmarkStore.isAccessible)
    }

    public var roots: [PhoneFolderRoot] {
        [PhoneFolderRoot(id: "app-artifacts", name: "Phone DSH 文件", kind: "app")] + grantedRoots
    }

    public func metadata(for root: PhoneFolderRoot) -> [String: Any] {
        PhoneFolderBookmarkStore.metadata(for: root)
    }

    public func grantFolder() async throws -> PhoneFolderRoot {
        guard continuation == nil else {
            throw PhoneToolError.unavailable(.filesFolder, "已有文件夹选择操作在进行")
        }
        guard let presenter = PhoneCapabilityViewPresenter.topViewController() else {
            throw PhoneToolError.unavailable(.filesFolder, "找不到系统文件夹选择器展示页面")
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.allowsMultipleSelection = false
            picker.shouldShowFileExtensions = true
            let delegate = PhoneFolderPickerDelegate(
                picked: { [weak self] urls in
                    guard let self, let url = urls.first else { return }
                    do {
                        self.finish(.success(try self.insert(url)))
                    } catch {
                        self.finish(.failure(error))
                    }
                },
                cancelled: { [weak self] in
                    self?.finish(.failure(PhoneToolError.cancelled))
                })
            self.delegate = delegate
            controller = picker
            picker.delegate = delegate
            picker.presentationController?.delegate = delegate
            presenter.present(picker, animated: true)
        }
    }

    private func insert(_ url: URL) throws -> PhoneFolderRoot {
        let standardized = url.standardizedFileURL
        let root = grantedRoots.first(where: { $0.url == standardized }) ?? PhoneFolderRoot(
            id: "folder-\(UUID().uuidString.lowercased())",
            name: standardized.lastPathComponent,
            kind: "security-scoped", url: standardized)
        try PhoneFolderBookmarkStore.save(root, existing: grantedRoots, defaults: defaults)
        if !grantedRoots.contains(where: { $0.id == root.id }) { grantedRoots.append(root) }
        grantedRoots.sort { $0.id < $1.id }
        restoreError = nil
        return root
    }

    private func finish(_ result: Result<PhoneFolderRoot, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        delegate = nil
        controller = nil
        continuation.resume(with: result)
    }
}

private final class PhoneFolderPickerDelegate: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private let picked: ([URL]) -> Void
    private let cancelled: () -> Void

    init(picked: @escaping ([URL]) -> Void, cancelled: @escaping () -> Void) {
        self.picked = picked
        self.cancelled = cancelled
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        picked(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cancelled()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        cancelled()
    }
}
