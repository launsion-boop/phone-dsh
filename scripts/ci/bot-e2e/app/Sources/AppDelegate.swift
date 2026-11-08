// SPDX-License-Identifier: MIT

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    let anchor = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        anchor.alpha = 0.01
        controller.view.addSubview(anchor)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
