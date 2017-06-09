/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared

import SwiftKeychainWrapper
import LocalAuthentication

// This file contains all of the settings available in the main settings screen of the app.

private var ShowDebugSettings: Bool = false
private var DebugSettingsClickCount: Int = 0

// For great debugging!
class HiddenSetting: Setting {
    let settings: SettingsTableViewController

    init(settings: SettingsTableViewController) {
        self.settings = settings
        super.init(title: nil)
    }

    override var hidden: Bool {
        return !ShowDebugSettings
    }
}


class DeleteExportedDataSetting: HiddenSetting {
    override var title: NSAttributedString? {
        // Not localized for now.
        return NSAttributedString(string: "Debug: delete exported databases", attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor])
    }

    override func onClick(navigationController: UINavigationController?) {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true)[0]
        let fileManager = NSFileManager.defaultManager()
        do {
            let files = try fileManager.contentsOfDirectoryAtPath(documentsPath)
            for file in files {
                if file.startsWith("browser.") || file.startsWith("logins.") {
                    try fileManager.removeItemInDirectory(documentsPath, named: file)
                }
            }
        } catch {
            print("Couldn't delete exported data: \(error).")
        }
    }
}

class ExportBrowserDataSetting: HiddenSetting {
    override var title: NSAttributedString? {
        // Not localized for now.
        return NSAttributedString(string: "Debug: copy databases to app container", attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor])
    }

    override func onClick(navigationController: UINavigationController?) {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true)[0]
        do {
            let log = Logger.syncLogger
            try self.settings.profile.files.copyMatching(fromRelativeDirectory: "", toAbsoluteDirectory: documentsPath) { file in
                log.debug("Matcher: \(file)")
                return file.startsWith("browser.") || file.startsWith("logins.")
            }
        } catch {
            print("Couldn't export browser data: \(error).")
        }
    }
}

// Opens the the license page in a new tab
class LicenseAndAcknowledgementsSetting: Setting {
    override var url: NSURL? {
        return NSURL(string: WebServer.sharedInstance.URLForResource("license", module: "about"))
    }

    override func onClick(navigationController: UINavigationController?) {
        setUpAndPushSettingsContentViewController(navigationController)
    }
}

// Opens the on-boarding screen again
class ShowIntroductionSetting: Setting {
    let profile: Profile

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile
        super.init(title: NSAttributedString(string: Strings.ShowTour, attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor]))
    }

    override func onClick(navigationController: UINavigationController?) {
        navigationController?.dismissViewControllerAnimated(true, completion: {
            if let appDelegate = UIApplication.sharedApplication().delegate as? AppDelegate {
                appDelegate.browserViewController.presentIntroViewController(true)
            }
        })
    }
}

// Opens the search settings pane
class SearchSetting: Setting {
    let profile: Profile

    override var accessoryType: UITableViewCellAccessoryType { return .DisclosureIndicator }

    override var style: UITableViewCellStyle { return .Value1 }

    override var status: NSAttributedString { return NSAttributedString(string: profile.searchEngines.defaultEngine.shortName) }

    override var accessibilityIdentifier: String? { return "Search" }

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile
        super.init(title: NSAttributedString(string: Strings.DefaultSearchEngine, attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor]))
    }

    override func onClick(navigationController: UINavigationController?) {
        let viewController = SearchSettingsTableViewController()
        viewController.model = profile.searchEngines
        navigationController?.pushViewController(viewController, animated: true)
    }
}

class LoginsSetting: Setting {
    let profile: Profile
    weak var navigationController: UINavigationController?

    override var accessoryType: UITableViewCellAccessoryType { return .DisclosureIndicator }

    override var accessibilityIdentifier: String? { return "Logins" }

    init(settings: SettingsTableViewController, delegate: SettingsDelegate?) {
        self.profile = settings.profile
        self.navigationController = settings.navigationController

        let loginsTitle = Strings.Logins
        super.init(title: NSAttributedString(string: loginsTitle, attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor]),
                   delegate: delegate)
    }

    private func navigateToLoginsList() {
        let viewController = LoginListViewController(profile: profile)
        viewController.settingsDelegate = delegate
        navigationController?.pushViewController(viewController, animated: true)
    }
}

class SyncDevicesSetting: Setting {
    let profile: Profile
    
    override var accessoryType: UITableViewCellAccessoryType { return .DisclosureIndicator }
    
    override var accessibilityIdentifier: String? { return "SyncDevices" }
    
    init(settings: SettingsTableViewController) {
        self.profile = settings.profile
        
        let clearTitle = Strings.SyncDevices
        super.init(title: NSAttributedString(string: clearTitle, attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor]))
    }
    
    override func onClick(navigationController: UINavigationController?) {
        
        if Sync.shared.isInSyncGroup {
            let settingsTableViewController = SyncSettingsViewController(style: .Grouped)
            settingsTableViewController.profile = getApp().profile
            navigationController?.pushViewController(settingsTableViewController, animated: true)
        } else {
            navigationController?.pushViewController(SyncWelcomeViewController(), animated: true)
        }
    }
}

class SyncDeviceSetting: Setting {
    let profile: Profile
    
    var onTap: (()->Void)?
    internal var displayTitle: String!
    
    override var accessoryType: UITableViewCellAccessoryType { return .None }
    
    override var accessibilityIdentifier: String? { return "SyncDevice" }
    
    init(profile profile: Profile, title: String) {
        self.profile = profile
        self.displayTitle = title
        super.init(title: NSAttributedString(string: title, attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor]))
    }
    
    override func onClick(navigationController: UINavigationController?) {
        if onTap != nil {
            onTap!()
        }
    }
}

class RemoveDeviceSetting: Setting {
    let profile: Profile
    
    override var accessoryType: UITableViewCellAccessoryType { return .None }
    
    override var accessibilityIdentifier: String? { return "RemoveDeviceSetting" }
    
    override var textAlignment: NSTextAlignment { return .Center }
    
    init(profile: Profile) {
        self.profile = profile
        let clearTitle = Strings.SyncRemoveThisDevice
        super.init(title: NSAttributedString(string: clearTitle, attributes: [NSForegroundColorAttributeName: UIColor.redColor(), NSFontAttributeName: UIFont.systemFontOfSize(17, weight: UIFontWeightRegular)]))
    }
    
    override func onClick(navigationController: UINavigationController?) {
        
        let alert = UIAlertController(title: "Remove this Device?", message: "This device will be disconnected from sync group and no longer receive or send sync data. All existing data will remain on device.", preferredStyle: .Alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: UIAlertActionStyle.Cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Remove", style: UIAlertActionStyle.Destructive) { action in
            Sync.shared.leaveSyncGroup()
            navigationController?.popToRootViewControllerAnimated(true)
        })
        
        navigationController?.presentViewController(alert, animated: true, completion: nil)
    }
}

class ClearPrivateDataSetting: Setting {
    let profile: Profile

    override var accessoryType: UITableViewCellAccessoryType { return .DisclosureIndicator }

    override var accessibilityIdentifier: String? { return "ClearPrivateData" }

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile

        let clearTitle = Strings.ClearPrivateData
        super.init(title: NSAttributedString(string: clearTitle, attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor]))
    }

    override func onClick(navigationController: UINavigationController?) {
        let viewController = ClearPrivateDataTableViewController()
        viewController.profile = profile
        navigationController?.pushViewController(viewController, animated: true)
    }
}

class PrivacyPolicySetting: Setting {
    override var title: NSAttributedString? {
        return NSAttributedString(string: Strings.Privacy_Policy, attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor])
    }

    override var url: NSURL? {
        return NSURL(string: "https://www.brave.com/ios_privacy.html")
    }

    override func onClick(navigationController: UINavigationController?) {
        setUpAndPushSettingsContentViewController(navigationController)
    }
}

class ChangePinSetting: Setting {
    let profile: Profile
    
    override var accessoryType: UITableViewCellAccessoryType { return .DisclosureIndicator }
    
    override var accessibilityIdentifier: String? { return "ChangePin" }
    
    init(settings: SettingsTableViewController) {
        self.profile = settings.profile
        
        let clearTitle = Strings.Change_Pin
        super.init(title: NSAttributedString(string: clearTitle, attributes: [NSForegroundColorAttributeName: UIConstants.TableViewRowTextColor]))
    }
    
    override func onClick(navigationController: UINavigationController?) {
        let view = PinViewController()
        navigationController?.pushViewController(view, animated: true)
    }
}

