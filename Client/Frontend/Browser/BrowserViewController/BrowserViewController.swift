/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit
import WebKit
import Shared
import CoreData
import SnapKit
import XCGLogger
import Shared

import ReadingList
import MobileCoreServices

private let log = Logger.browserLogger


struct BrowserViewControllerUX {
    static let BackgroundColor = UIConstants.AppBackgroundColor
    static let ShowHeaderTapAreaHeight: CGFloat = 32
    static let BookmarkStarAnimationDuration: Double = 0.5
    static let BookmarkStarAnimationOffset: CGFloat = 80
}

class BrowserViewController: UIViewController {

    // Reader mode bar is currently (temporarily) glued onto the urlbar bottom, and is outside of the frame of the urlbar.
    // Need this to detect touches as a result
    class ViewToCaptureReaderModeTap : UIView {
        weak var urlBarView:BraveURLBarView?
        override func hitTest(point: CGPoint, withEvent event: UIEvent?) -> UIView? {
            if let toolbar = urlBarView?.readerModeToolbar {
                let pointForTargetView = toolbar.convertPoint(point, fromView: self)
                let isHidden = toolbar.hidden || toolbar.convertPoint(CGPoint(x:0,y:0), toView: nil).y < UIConstants.ToolbarHeight
                if !isHidden && CGRectContainsPoint(toolbar.bounds, pointForTargetView) {
                    return toolbar.settingsButton
                }
            }
            return super.hitTest(point, withEvent: event)
        }
    }

    var homePanelController: HomePanelViewController?
    var webViewContainer: UIView!
    var urlBar: URLBarView!
    var readerModeBar: ReaderModeBarView?
    var readerModeCache: ReaderModeCache
    var statusBarOverlay: UIView!
    private(set) var toolbar: BraveBrowserBottomToolbar?
    var searchController: SearchViewController?
    var screenshotHelper: ScreenshotHelper!
    var homePanelIsInline = true
    var searchLoader: SearchLoader!
    let snackBars = UIView()
    let webViewContainerToolbar = UIView()
    var findInPageBar: FindInPageBar?
    let findInPageContainer = UIView()

    // popover rotation handling
    var displayedPopoverController: UIViewController?
    var updateDisplayedPopoverProperties: (() -> ())?

    var openInHelper: OpenInHelper?

    // location label actions
    var pasteGoAction: AccessibleAction!
    var pasteAction: AccessibleAction!
    var copyAddressAction: AccessibleAction!

    weak var tabTrayController: TabTrayController!

    let profile: Profile
    let tabManager: TabManager

    // These views wrap the urlbar and toolbar to provide background effects on them
    var header: BlurWrapper!
    var footer: UIView!
    var footerBackdrop: UIView!
    var footerBackground: BlurWrapper?
    var topTouchArea: UIButton!

    // Backdrop used for displaying greyed background for private tabs
    var webViewContainerBackdrop: UIView!

    var scrollController = BraveScrollController()

    private var keyboardState: KeyboardState?
    
    private var currentThemeName: String?

    let WhiteListedUrls = ["\\/\\/itunes\\.apple\\.com\\/"]

    // Tracking navigation items to record history types.
    // TODO: weak references?
    var ignoredNavigation = Set<WKNavigation>()

    var navigationToolbar: BrowserToolbarProtocol {
        return toolbar ?? urlBar
    }

    static var instanceAsserter = 0 // Brave: it is easy to get confused as to which fx classes are effectively singletons

    init(profile: Profile, tabManager: TabManager) {
        self.profile = profile
        self.tabManager = tabManager
        self.readerModeCache = DiskReaderModeCache.sharedInstance
        super.init(nibName: nil, bundle: nil)
        didInit()

        BrowserViewController.instanceAsserter += 1
        assert(BrowserViewController.instanceAsserter == 1)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func selectedTabChanged(selected: Browser) {}

    override func supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        if UIDevice.currentDevice().userInterfaceIdiom == .Phone {
            return UIInterfaceOrientationMask.AllButUpsideDown
        } else {
            return UIInterfaceOrientationMask.All
        }
    }

    override func viewWillTransitionToSize(size: CGSize, withTransitionCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransitionToSize(size, withTransitionCoordinator: coordinator)

        displayedPopoverController?.dismissViewControllerAnimated(true, completion: nil)

        guard let displayedPopoverController = self.displayedPopoverController else {
            return
        }

        coordinator.animateAlongsideTransition(nil) { context in
            self.updateDisplayedPopoverProperties?()
            self.presentViewController(displayedPopoverController, animated: true, completion: nil)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        log.debug("BVC received memory warning")
    }

    private func didInit() {
        screenshotHelper = ScreenshotHelper(controller: self)
        tabManager.addDelegate(self)
        tabManager.addNavigationDelegate(self)
    }

    func shouldShowFooterForTraitCollection(previousTraitCollection: UITraitCollection) -> Bool {
        return previousTraitCollection.verticalSizeClass != .Compact &&
               previousTraitCollection.horizontalSizeClass != .Regular
    }


    func toggleSnackBarVisibility(show show: Bool) {
        if show {
            UIView.animateWithDuration(0.1, animations: { self.snackBars.hidden = false })
        } else {
            snackBars.hidden = true
        }
    }

    func updateToolbarStateForTraitCollection(newCollection: UITraitCollection) {
        let bottomToolbarIsHidden = shouldShowFooterForTraitCollection(newCollection)

        urlBar.hideBottomToolbar(!bottomToolbarIsHidden)
        
        // TODO: (IMO) should be refactored to not destroy and recreate the toolbar all the time
        // This would prevent theme knowledge from being retained as well
        toolbar?.removeFromSuperview()
        toolbar?.browserToolbarDelegate = nil
        footerBackground?.removeFromSuperview()
        footerBackground = nil
        toolbar = nil

        if bottomToolbarIsHidden {
            toolbar = BraveBrowserBottomToolbar()
            toolbar?.browserToolbarDelegate = self
            footerBackground = BlurWrapper(view: toolbar!)
            footerBackground?.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(footerBackground!)
            
            // Since this is freshly created, theme needs to be applied
            if let currentThemeName = self.currentThemeName {
                self.applyTheme(currentThemeName)
            }
        }

        view.setNeedsUpdateConstraints()
        if let home = homePanelController {
            home.view.setNeedsUpdateConstraints()
        }

        if let tab = tabManager.selectedTab,
               webView = tab.webView {
            updateURLBarDisplayURL(tab: tab)
            navigationToolbar.updateBackStatus(webView.canGoBack)
            navigationToolbar.updateForwardStatus(webView.canGoForward)
            navigationToolbar.updateReloadStatus(tab.loading ?? false)
        }
    }

    override func willTransitionToTraitCollection(newCollection: UITraitCollection, withTransitionCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        super.willTransitionToTraitCollection(newCollection, withTransitionCoordinator: coordinator)

        // During split screen launching on iPad, this callback gets fired before viewDidLoad gets a chance to
        // set things up. Make sure to only update the toolbar state if the view is ready for it.
        if isViewLoaded() {
            updateToolbarStateForTraitCollection(newCollection)
        }

        displayedPopoverController?.dismissViewControllerAnimated(true, completion: nil)

        // WKWebView looks like it has a bug where it doesn't invalidate it's visible area when the user
        // performs a device rotation. Since scrolling calls
        // _updateVisibleContentRects (https://github.com/WebKit/webkit/blob/master/Source/WebKit2/UIProcess/API/Cocoa/WKWebView.mm#L1430)
        // this method nudges the web view's scroll view by a single pixel to force it to invalidate.
        if let scrollView = self.tabManager.selectedTab?.webView?.scrollView {
            let contentOffset = scrollView.contentOffset
            coordinator.animateAlongsideTransition({ context in
                scrollView.setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y + 1), animated: true)
                self.scrollController.showToolbars(animated: false)
            }, completion: { context in
                scrollView.setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y), animated: false)
            })
        }
    }

    func SELappDidEnterBackgroundNotification() {
        displayedPopoverController?.dismissViewControllerAnimated(false, completion: nil)
    }

    func SELtappedTopArea() {
        scrollController.showToolbars(animated: true)
    }

    func SELappWillResignActiveNotification() {
        // If we are displying a private tab, hide any elements in the browser that we wouldn't want shown
        // when the app is in the home switcher
        guard let privateTab = tabManager.selectedTab where privateTab.isPrivate else {
            return
        }

        webViewContainerBackdrop.alpha = 1
        webViewContainer.alpha = 0
        urlBar.locationView.alpha = 0
    }

    func SELappDidBecomeActiveNotification() {
        // Re-show any components that might have been hidden because they were being displayed
        // as part of a private mode tab
        UIView.animateWithDuration(0.2, delay: 0, options: UIViewAnimationOptions.CurveEaseInOut, animations: {
            self.webViewContainer.alpha = 1
            self.urlBar.locationView.alpha = 1
            self.view.backgroundColor = UIColor.clearColor()
        }, completion: { _ in
            self.webViewContainerBackdrop.alpha = 0
        })
    }

    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self, name: UIApplicationWillResignActiveNotification, object: nil)
        NSNotificationCenter.defaultCenter().removeObserver(self, name: UIApplicationWillEnterForegroundNotification, object: nil)
        NSNotificationCenter.defaultCenter().removeObserver(self, name: UIApplicationDidEnterBackgroundNotification, object: nil)
    }

    override func loadView() {
        let v = ViewToCaptureReaderModeTap(frame: UIScreen.mainScreen().bounds)
        view = v
    }

    override func viewDidLoad() {
        log.debug("BVC viewDidLoad…")
        super.viewDidLoad()
        log.debug("BVC super viewDidLoad called.")

        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(BrowserViewController.SELappWillResignActiveNotification), name: UIApplicationWillResignActiveNotification, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(BrowserViewController.SELappDidBecomeActiveNotification), name: UIApplicationDidBecomeActiveNotification, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(BrowserViewController.SELappDidEnterBackgroundNotification), name: UIApplicationDidEnterBackgroundNotification, object: nil)
        KeyboardHelper.defaultHelper.addDelegate(self)

        log.debug("BVC adding footer and header…")
        footerBackdrop = UIView()
        footerBackdrop.backgroundColor = UIColor.whiteColor()
        view.addSubview(footerBackdrop)

        log.debug("BVC setting up webViewContainer…")
        webViewContainerBackdrop = UIView()
        webViewContainerBackdrop.backgroundColor = UIColor.grayColor()
        webViewContainerBackdrop.alpha = 0
        view.addSubview(webViewContainerBackdrop)

        webViewContainer = UIView()
        webViewContainer.addSubview(webViewContainerToolbar)
        view.addSubview(webViewContainer)

        log.debug("BVC setting up status bar…")
        statusBarOverlay = UIView()
        statusBarOverlay.backgroundColor = BraveUX.ToolbarsBackgroundSolidColor
        view.addSubview(statusBarOverlay)

        log.debug("BVC setting up top touch area…")
        topTouchArea = UIButton()
        topTouchArea.isAccessibilityElement = false
        topTouchArea.addTarget(self, action: #selector(BrowserViewController.SELtappedTopArea), forControlEvents: UIControlEvents.TouchUpInside)
        view.addSubview(topTouchArea)

        // Setup the URL bar, wrapped in a view to get transparency effect
#if BRAVE
        // Brave: need to inject in the middle of this function, override won't work
        urlBar = BraveURLBarView()
        urlBar.translatesAutoresizingMaskIntoConstraints = false
        urlBar.delegate = self
        urlBar.browserToolbarDelegate = self
        header = BlurWrapper(view: urlBar)
        view.addSubview(header)

        (view as! ViewToCaptureReaderModeTap).urlBarView = (urlBar as! BraveURLBarView)
 #endif

        // UIAccessibilityCustomAction subclass holding an AccessibleAction instance does not work, thus unable to generate AccessibleActions and UIAccessibilityCustomActions "on-demand" and need to make them "persistent" e.g. by being stored in BVC
        pasteGoAction = AccessibleAction(name: Strings.Paste_and_Go, handler: { () -> Bool in
            if let pasteboardContents = UIPasteboard.generalPasteboard().string {
                self.urlBar(self.urlBar, didSubmitText: pasteboardContents)
                return true
            }
            return false
        })
        pasteAction = AccessibleAction(name: Strings.Paste, handler: { () -> Bool in
            if let pasteboardContents = UIPasteboard.generalPasteboard().string {
                // Enter overlay mode and fire the text entered callback to make the search controller appear.
                self.urlBar.enterSearchMode(pasteboardContents, pasted: true)
                self.urlBar(self.urlBar, didEnterText: pasteboardContents)
                return true
            }
            return false
        })
        copyAddressAction = AccessibleAction(name: Strings.Copy_Address, handler: { () -> Bool in
            if let url = self.urlBar.currentURL {
                UIPasteboard.generalPasteboard().URL = url
            }
            return true
        })


        log.debug("BVC setting up search loader…")
        searchLoader = SearchLoader(profile: profile, urlBar: urlBar)

        footer = UIView()
        self.view.addSubview(footer)
        self.view.addSubview(snackBars)
        snackBars.backgroundColor = UIColor.clearColor()
        self.view.addSubview(findInPageContainer)

        scrollController.urlBar = urlBar
        scrollController.header = header
        scrollController.footer = footer
        scrollController.snackBars = snackBars
    }

    var headerHeightConstraint: Constraint?
    var webViewContainerTopOffset: Constraint?

    func setupConstraints() {
        
        statusBarOverlay.snp_makeConstraints { make in
            make.top.right.left.equalTo(statusBarOverlay.superview!)
            make.bottom.equalTo(topLayoutGuide)
        }
        
        header.snp_makeConstraints { make in
            scrollController.headerTopConstraint = make.top.equalTo(snp_topLayoutGuideBottom).constraint
            if let headerHeightConstraint = headerHeightConstraint {
                headerHeightConstraint.updateOffset(BraveURLBarView.CurrentHeight)
            } else {
                headerHeightConstraint = make.height.equalTo(BraveURLBarView.CurrentHeight).constraint
            }

            if UIDevice.currentDevice().userInterfaceIdiom == .Phone {
                // iPad layout is customized in BraveTopViewController for showing panels
                make.left.right.equalTo(header.superview!)
            }
        }
        
        // webViewContainer constraints set in Brave subclass.
        // TODO: This should be centralized

        webViewContainerBackdrop.snp_makeConstraints { make in
            make.edges.equalTo(webViewContainer)
        }

        webViewContainerToolbar.snp_makeConstraints { make in
            make.left.right.top.equalTo(webViewContainer)
            make.height.equalTo(0)
        }
    }

    override func viewDidLayoutSubviews() {
        log.debug("BVC viewDidLayoutSubviews…")
        super.viewDidLayoutSubviews()
        log.debug("BVC done.")
    }

    func loadQueuedTabs() {
        log.debug("Loading queued tabs in the background.")

        // Chain off of a trivial deferred in order to run on the background queue.
        succeed().upon() { res in
            self.dequeueQueuedTabs()
        }
    }

    private func dequeueQueuedTabs() {
        // Brave doesn't have queued tabs
    }

    override func viewWillAppear(animated: Bool) {
        log.debug("BVC viewWillAppear.")
        super.viewWillAppear(animated)
        log.debug("BVC super.viewWillAppear done.")
        
#if !DISABLE_INTRO_SCREEN
        // On iPhone, if we are about to show the On-Boarding, blank out the browser so that it does
        // not flash before we present. This change of alpha also participates in the animation when
        // the intro view is dismissed.
        if UIDevice.currentDevice().userInterfaceIdiom == .Phone {
            self.view.alpha = (profile.prefs.intForKey(IntroViewControllerSeenProfileKey) != nil) ? 1.0 : 0.0
        }
#endif
#if !BRAVE
        if activeCrashReporter?.previouslyCrashed ?? false {
            log.debug("Previously crashed.")

            // Reset previous crash state
            activeCrashReporter?.resetPreviousCrashState()

            let optedIntoCrashReporting = profile.prefs.boolForKey("crashreports.send.always")
            if optedIntoCrashReporting == nil {
                // Offer a chance to allow the user to opt into crash reporting
                showCrashOptInAlert()
            } else {
                showRestoreTabsAlert()
            }
        } else {
           tabManager.restoreTabs()
        }

        updateTabCountUsingTabManager(tabManager, animated: false)
#endif
    }

    private func shouldRestoreTabs() -> Bool {
        let tabsToRestore = TabMO.getAll()
        let onlyNoHistoryTabs = !tabsToRestore.every {
            if let history = $0.urlHistorySnapshot as? [String] {
                if history.count > 1 {
                    return false
                }
                if let first = history.first {
                    return first.contains(WebServer.sharedInstance.base)
                }
            }
            return true
        }
        return !onlyNoHistoryTabs && !DebugSettingsBundleOptions.skipSessionRestore
    }

    override func viewDidAppear(animated: Bool) {
        log.debug("BVC viewDidAppear.")

#if !DISABLE_INTRO_SCREEN
        presentIntroViewController()
#endif

        log.debug("BVC intro presented.")
        self.webViewContainerToolbar.hidden = false

        log.debug("BVC calling super.viewDidAppear.")
        super.viewDidAppear(animated)
        log.debug("BVC done.")

        if shouldShowWhatsNewTab() {
            if let whatsNewURL = SupportUtils.URLForTopic("new-ios") {
                self.openURLInNewTab(whatsNewURL)
                profile.prefs.setString(AppInfo.appVersion, forKey: LatestAppVersionProfileKey)
            }
        }

        showQueuedAlertIfAvailable()
    }

    private func shouldShowWhatsNewTab() -> Bool {
        guard let latestMajorAppVersion = profile.prefs.stringForKey(LatestAppVersionProfileKey)?.componentsSeparatedByString(".").first else {
            return DeviceInfo.hasConnectivity()
        }

        return latestMajorAppVersion != AppInfo.majorAppVersion && DeviceInfo.hasConnectivity()
    }

    private func showQueuedAlertIfAvailable() {
        if var queuedAlertInfo = tabManager.selectedTab?.dequeueJavascriptAlertPrompt() {
            let alertController = queuedAlertInfo.alertController()
            alertController.delegate = self
            presentViewController(alertController, animated: true, completion: nil)
        }
    }

    func resetBrowserChrome() {
        // animate and reset transform for browser chrome
        urlBar.updateAlphaForSubviews(1)

        [header,
            footer,
            readerModeBar,
            footerBackdrop].forEach { view in
                view?.transform = CGAffineTransformIdentity
        }
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()

        topTouchArea.snp_remakeConstraints { make in
            make.top.left.right.equalTo(self.view)
            make.height.equalTo(BrowserViewControllerUX.ShowHeaderTapAreaHeight)
        }

        readerModeBar?.snp_remakeConstraints { make in
            make.top.equalTo(self.header.snp_bottom).constraint
            make.height.equalTo(BraveUX.ReaderModeBarHeight)
            make.leading.trailing.equalTo(self.view)
        }

        footer.snp_remakeConstraints { make in
            scrollController.footerBottomConstraint = make.bottom.equalTo(self.view.snp_bottom).constraint
            make.top.equalTo(self.snackBars.snp_top)
            make.leading.trailing.equalTo(self.view)
        }

        footerBackdrop.snp_remakeConstraints { make in
            make.edges.equalTo(self.footer)
        }

        updateSnackBarConstraints()
        footerBackground?.snp_remakeConstraints { make in
            make.bottom.left.right.equalTo(self.footer)
            make.height.equalTo(UIConstants.ToolbarHeight)
        }
        urlBar.setNeedsUpdateConstraints()

        // Remake constraints even if we're already showing the home controller.
        // The home controller may change sizes if we tap the URL bar while on about:home.
        homePanelController?.view.snp_remakeConstraints { make in
            make.top.equalTo(self.header.snp_bottom)
            make.left.right.equalTo(self.view)
            if self.homePanelIsInline {
                make.bottom.equalTo(self.toolbar?.snp_top ?? self.view.snp_bottom)
            } else {
                make.bottom.equalTo(self.view.snp_bottom)
            }
        }

        findInPageContainer.snp_remakeConstraints { make in
            make.left.right.equalTo(self.view)

            if let keyboardHeight = keyboardState?.intersectionHeightForView(self.view) where keyboardHeight > 0 {
                make.bottom.equalTo(self.view).offset(-keyboardHeight)
            } else if let toolbar = self.toolbar {
                make.bottom.equalTo(toolbar.snp_top)
            } else {
                make.bottom.equalTo(self.view)
            }
        }
    }

    func showHomePanelController(inline inline: Bool) {
        log.debug("BVC showHomePanelController.")
        homePanelIsInline = inline

        #if BRAVE
            // we always want to show the bottom toolbar, if this is false, the bottom toolbar is hidden
            homePanelIsInline = true
        #endif

        if homePanelController == nil {
            homePanelController = HomePanelViewController()
            homePanelController!.profile = profile
            homePanelController!.delegate = self
            homePanelController!.url = tabManager.selectedTab?.displayURL
            homePanelController!.view.alpha = 0

            addChildViewController(homePanelController!)
            view.addSubview(homePanelController!.view)
            homePanelController!.didMoveToParentViewController(self)
        }

        let panelNumber = tabManager.selectedTab?.url?.fragment

        // splitting this out to see if we can get better crash reports when this has a problem
        var newSelectedButtonIndex = 0
        if let numberArray = panelNumber?.componentsSeparatedByString("=") {
            if let last = numberArray.last, lastInt = Int(last) {
                newSelectedButtonIndex = lastInt
            }
        }
        homePanelController?.selectedButtonIndex = newSelectedButtonIndex

        // We have to run this animation, even if the view is already showing because there may be a hide animation running
        // and we want to be sure to override its results.
        UIView.animateWithDuration(0.2, animations: { () -> Void in
            self.homePanelController!.view.alpha = 1
        }, completion: { finished in
            if finished {
                self.webViewContainer.accessibilityElementsHidden = true
                UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil)
            }
        })
        view.setNeedsUpdateConstraints()
        log.debug("BVC done with showHomePanelController.")
    }

    func hideHomePanelController() {
        guard let homePanel = homePanelController else { return }
        homePanelController = nil

        // UIView animation conflict is causing completion block to run prematurely
        let duration = 0.3

        UIView.animateWithDuration(duration, delay: 0, options: .BeginFromCurrentState, animations: { () -> Void in
            homePanel.view.alpha = 0
            }, completion: { (b) in })

        postAsyncToMain(duration) {
            homePanel.willMoveToParentViewController(nil)
            homePanel.view.removeFromSuperview()
            homePanel.removeFromParentViewController()
            self.webViewContainer.accessibilityElementsHidden = false
            UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil)

            // Refresh the reading view toolbar since the article record may have changed
            if let readerMode = self.tabManager.selectedTab?.getHelper(ReaderMode.self) where readerMode.state == .Active {
                self.showReaderModeBar(animated: false)
            }
        }
    }

    func updateInContentHomePanel(url: NSURL?) {
        if !urlBar.inSearchMode {
            if AboutUtils.isAboutHomeURL(url){
                urlBar.updateBookmarkStatus(false)
                showHomePanelController(inline: (tabManager.selectedTab?.canGoForward ?? false || tabManager.selectedTab?.canGoBack ?? false))
            } else {
                hideHomePanelController()
            }
        }
    }

    func finishEditingAndSubmit(url: NSURL) {
        guard let tab = tabManager.selectedTab else {
            return
        }

        // Ugly UI when submit completes, the view stack pops back to homepanel stats, which flash
        // then disappear as the webview is reshown. Hide the elements so the homepanel is just a white screen
        homePanelController?.view.subviews.forEach { $0.hidden = true }
        tabManager.selectedTab?.webView?.backgroundColor = UIColor.whiteColor()

        urlBar.currentURL = url
        urlBar.leaveSearchMode()

#if !BRAVE // TODO hookup when adding desktop AU
        if let webView = tab.webView {
            resetSpoofedUserAgentIfRequired(webView, newURL: url)
        }
#endif
        tab.loadRequest(NSURLRequest(URL: url))
    }

    func addBookmark(url: NSURL?, title: String?, parentFolder: Bookmark? = nil) {
        // Custom title can only be applied during an edit
        Bookmark.add(url: url, title: title, parentFolder: parentFolder)
        self.urlBar.updateBookmarkStatus(true)
    }

    func removeBookmark(url: NSURL) {
        if Bookmark.remove(forUrl: url, context: DataController.moc) {
            self.urlBar.updateBookmarkStatus(false)
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        if urlBar.inSearchMode {
            urlBar.SELdidClickCancel()
            return true
        } else if let selectedTab = tabManager.selectedTab where selectedTab.canGoBack {
            selectedTab.goBack()
            return true
        }
        return false
    }

//    private func runScriptsOnWebView(webView: WKWebView) {
//        webView.evaluateJavaScript("__firefox__.favicons.getFavicons()", completionHandler:nil)
//    }

    func updateUIForReaderHomeStateForTab(tab: Browser) {
        updateURLBarDisplayURL(tab: tab)
        updateInContentHomePanel(tab.url)

        if let url = tab.url {
            if ReaderModeUtils.isReaderModeURL(url) {
                showReaderModeBar(animated: false)
            } else {
                hideReaderModeBar(animated: false)
            }
        }
    }

    private func isWhitelistedUrl(url: NSURL) -> Bool {
        for entry in WhiteListedUrls {
            if let _ = url.absoluteString?.rangeOfString(entry, options: .RegularExpressionSearch) {
                return UIApplication.sharedApplication().canOpenURL(url)
            }
        }
        return false
    }

    /// Updates the URL bar text and button states.
    /// Call this whenever the page URL changes.
    func updateURLBarDisplayURL(tab _tab: Browser?) {
        guard let selected = tabManager.selectedTab else { return }
        let tab = _tab != nil ? _tab! : selected

        urlBar.currentURL = tab.displayURL

        let isPage = tab.displayURL?.isWebPage() ?? false
        navigationToolbar.updatePageStatus(isWebPage: isPage)

        guard let url = tab.url else {
            return
        }

        Bookmark.contains(url: url, completionOnMain: { isBookmarked in
            self.urlBar.updateBookmarkStatus(isBookmarked)
        })
    }
    // Mark: Opening New Tabs

    func switchBrowsingMode(toPrivate isPrivate: Bool, request: NSURLRequest? = nil) {
        if PrivateBrowsing.singleton.isOn == isPrivate {
            // No change
            return
        }
        
        func update() {
            applyTheme(isPrivate ? Theme.PrivateMode : Theme.NormalMode)
            
            let tabTrayController = self.tabTrayController ?? TabTrayController(tabManager: tabManager, profile: profile, tabTrayDelegate: self)
            tabTrayController.changePrivacyMode(isPrivate)
            self.tabTrayController = tabTrayController
            
            // Should be fixed as part of larger privatemode refactor
            //  But currently when switching to PM tabCount == 1, but no tabs actually
            //  exist, so causes lot of issues, explicit check for isPM
            if tabManager.tabCount == 0 || request != nil || isPrivate {
                tabManager.addTabAndSelect(request)
            }
        }
        
        if isPrivate {
            PrivateBrowsing.singleton.enter()
            update()
        } else {
            PrivateBrowsing.singleton.exit().uponQueue(dispatch_get_main_queue()) {
                self.tabManager.restoreTabs()
                update()
            }
        }
        // exiting is async and non-trivial for Brave, not currently handled here
    }

    func switchToTabForURLOrOpen(url: NSURL, isPrivate: Bool = false) {
        let tab = tabManager.getTabForURL(url)
        popToBrowser(tab)
        if let tab = tab {
            tabManager.selectTab(tab)
        } else {
            openURLInNewTab(url)
        }
    }

    func openURLInNewTab(url: NSURL?) {
        if let selectedTab = tabManager.selectedTab {
            screenshotHelper.takeScreenshot(selectedTab)
        }

        var request: NSURLRequest? = nil
        if let url = url {
            request = NSURLRequest(URL: url)
        }
        
        // Cannot leave PM via this, only enter
        if PrivateBrowsing.singleton.isOn {
            switchBrowsingMode(toPrivate: true)
        }
        
        tabManager.addTabAndSelect(request)
    }

    func openBlankNewTabAndFocus(isPrivate isPrivate: Bool = false) {
        popToBrowser()
        tabManager.selectTab(nil)
        openURLInNewTab(nil)
    }

    private func popToBrowser(forTab: Browser? = nil) {
        guard let currentViewController = navigationController?.topViewController else {
                return
        }
        if let presentedViewController = currentViewController.presentedViewController {
            presentedViewController.dismissViewControllerAnimated(false, completion: nil)
        }
        // if a tab already exists and the top VC is not the BVC then pop the top VC, otherwise don't.
        if currentViewController != self,
            let _ = forTab {
            self.navigationController?.popViewControllerAnimated(true)
        }
    }

    // Mark: User Agent Spoofing
#if !BRAVE // TODO hookup when adding desktop AU
    private func resetSpoofedUserAgentIfRequired(webView: WKWebView, newURL: NSURL) {
        // Reset the UA when a different domain is being loaded
        if webView.URL?.host != newURL.host {
            webView.customUserAgent = nil
        }
    }

    private func restoreSpoofedUserAgentIfRequired(webView: WKWebView, newRequest: NSURLRequest) {
        // Restore any non-default UA from the request's header
        let ua = newRequest.valueForHTTPHeaderField("User-Agent")
        webView.customUserAgent = ua != UserAgent.defaultUserAgent() ? ua : nil
    }
#endif

    var helper:ShareExtensionHelper!
    
    func presentActivityViewController(url: NSURL, tab: Browser, sourceView: UIView?, sourceRect: CGRect, arrowDirection: UIPopoverArrowDirection) {
        var activities = [UIActivity]()
        
        let findInPageActivity = FindInPageActivity() { [unowned self] in
            self.updateFindInPageVisibility(visible: true)
        }
        activities.append(findInPageActivity)
        
        //if let tab = tab where (tab.getHelper(name: ReaderMode.name()) as? ReaderMode)?.state != .Active { // needed for reader mode?
        let requestDesktopSiteActivity = RequestDesktopSiteActivity() { [weak tab] in
            if let url = tab?.url {
                (getApp().browserViewController as! BraveBrowserViewController).newTabForDesktopSite(url: url)
            }
            //tab?.toggleDesktopSite()
        }
        activities.append(requestDesktopSiteActivity)

        helper = ShareExtensionHelper(url: url, tab: tab, activities: activities)
        let controller = helper.createActivityViewController({ [unowned self] completed in
            // After dismissing, check to see if there were any prompts we queued up
            self.showQueuedAlertIfAvailable()

            // Usually the popover delegate would handle nil'ing out the references we have to it
            // on the BVC when displaying as a popover but the delegate method doesn't seem to be
            // invoked on iOS 10. See Bug 1297768 for additional details.
            self.displayedPopoverController = nil
            self.updateDisplayedPopoverProperties = nil
            self.helper = nil

            if completed {
                // We don't know what share action the user has chosen so we simply always
                // update the toolbar and reader mode bar to reflect the latest status.
                self.updateURLBarDisplayURL(tab: tab)
                self.updateReaderModeBar()
            }
        })

        let setupPopover = { [unowned self] in
            if let popoverPresentationController = controller.popoverPresentationController {
                popoverPresentationController.sourceView = sourceView
                popoverPresentationController.sourceRect = sourceRect
                popoverPresentationController.permittedArrowDirections = arrowDirection
                popoverPresentationController.delegate = self
            }
        }

        setupPopover()

        if controller.popoverPresentationController != nil {
            displayedPopoverController = controller
            updateDisplayedPopoverProperties = setupPopover
        }

        self.presentViewController(controller, animated: true, completion: nil)
    }

    func updateFindInPageVisibility(visible visible: Bool) {
        if visible {
            if findInPageBar == nil {
                let findInPageBar = FindInPageBar()
                self.findInPageBar = findInPageBar
                findInPageBar.delegate = self
                findInPageContainer.addSubview(findInPageBar)

                findInPageBar.snp_makeConstraints { make in
                    make.edges.equalTo(findInPageContainer)
                    make.height.equalTo(UIConstants.ToolbarHeight)
                }

                updateViewConstraints()

                // We make the find-in-page bar the first responder below, causing the keyboard delegates
                // to fire. This, in turn, will animate the Find in Page container since we use the same
                // delegate to slide the bar up and down with the keyboard. We don't want to animate the
                // constraints added above, however, so force a layout now to prevent these constraints
                // from being lumped in with the keyboard animation.
                findInPageBar.layoutIfNeeded()
            }

            self.findInPageBar?.becomeFirstResponder()
        } else if let findInPageBar = self.findInPageBar {
            findInPageBar.endEditing(true)
            guard let webView = tabManager.selectedTab?.webView else { return }
            webView.evaluateJavaScript("__firefox__.findDone()", completionHandler: nil)
            findInPageBar.removeFromSuperview()
            self.findInPageBar = nil
            updateViewConstraints()
        }
    }

    override func canBecomeFirstResponder() -> Bool {
        return true
    }

//    override func becomeFirstResponder() -> Bool {
//        // Make the web view the first responder so that it can show the selection menu.
//        return tabManager.selectedTab?.webView?.becomeFirstResponder() ?? false
//    }
}

/**
 * History visit management.
 * TODO: this should be expanded to track various visit types; see Bug 1166084.
 */
extension BrowserViewController {
    func ignoreNavigationInTab(tab: Browser, navigation: WKNavigation) {
        self.ignoredNavigation.insert(navigation)
    }

    func recordNavigationInTab(tab: Browser, navigation: WKNavigation) {
        //self.typedNavigation[navigation] = visitType
    }
}

extension BrowserViewController: WindowCloseHelperDelegate {
    func windowCloseHelper(helper: WindowCloseHelper, didRequestToCloseBrowser browser: Browser) {
        tabManager.removeTab(browser, createTabIfNoneLeft: true)
    }
}


extension BrowserViewController: HomePanelViewControllerDelegate {
    func homePanelViewController(homePanelViewController: HomePanelViewController, didSelectURL url: NSURL) {
        hideHomePanelController()
        finishEditingAndSubmit(url)
    }

    func homePanelViewController(homePanelViewController: HomePanelViewController, didSelectPanel panel: Int) {
        if AboutUtils.isAboutHomeURL(tabManager.selectedTab?.url) {
            tabManager.selectedTab?.webView?.evaluateJavaScript("history.replaceState({}, '', '#panel=\(panel)')", completionHandler: nil)
        }
    }
}

extension BrowserViewController: SearchViewControllerDelegate {
    func searchViewController(searchViewController: SearchViewController, didSelectURL url: NSURL) {
        finishEditingAndSubmit(url)
    }

    func presentSearchSettingsController() {
        let settingsNavigationController = SearchSettingsTableViewController()
        settingsNavigationController.model = self.profile.searchEngines

        let navController = UINavigationController(rootViewController: settingsNavigationController)

        self.presentViewController(navController, animated: true, completion: nil)
    }
    
    func searchViewController(searchViewController: SearchViewController, shouldFindInPage query: String) {
        cancelSearch()
        updateFindInPageVisibility(visible: true)
        findInPageBar?.text = query
    }
    
    func searchViewControllerAllowFindInPage() -> Bool {
        // Hides find in page for new tabs.
        if let st = tabManager.selectedTab, let wv = st.webView {
            if AboutUtils.isAboutHomeURL(wv.URL) == false {
                return true
            }
        }
        return false
    }
}

extension BrowserViewController: ReaderModeDelegate {
    func readerMode(readerMode: ReaderMode, didChangeReaderModeState state: ReaderModeState, forBrowser browser: Browser) {
        // If this reader mode availability state change is for the tab that we currently show, then update
        // the button. Otherwise do nothing and the button will be updated when the tab is made active.
        if tabManager.selectedTab === browser {
            urlBar.updateReaderModeState(state)
        }
    }

    func readerMode(readerMode: ReaderMode, didDisplayReaderizedContentForBrowser browser: Browser) {
        self.showReaderModeBar(animated: true)
        browser.showContent(true)
    }

    // Returning None here makes sure that the Popover is actually presented as a Popover and
    // not as a full-screen modal, which is the default on compact device classes.
    func adaptivePresentationStyleForPresentationController(controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return UIModalPresentationStyle.None
    }
}

// MARK: - UIPopoverPresentationControllerDelegate

extension BrowserViewController: UIPopoverPresentationControllerDelegate {
    func popoverPresentationControllerDidDismissPopover(popoverPresentationController: UIPopoverPresentationController) {
        displayedPopoverController = nil
        updateDisplayedPopoverProperties = nil
    }
}

extension BrowserViewController: IntroViewControllerDelegate {
    func presentIntroViewController(force: Bool = false) -> Bool {
        struct autoShowOnlyOnce { static var wasShownThisSession = false } // https://github.com/brave/browser-ios/issues/424
        if force || (profile.prefs.intForKey(IntroViewControllerSeenProfileKey) == nil && !autoShowOnlyOnce.wasShownThisSession) {
            autoShowOnlyOnce.wasShownThisSession = true
            let introViewController = IntroViewController()
            introViewController.delegate = self
            // On iPad we present it modally in a controller
            if UIDevice.currentDevice().userInterfaceIdiom == .Pad {
                introViewController.preferredContentSize = CGSize(width: IntroViewControllerUX.Width, height: IntroViewControllerUX.Height)
                introViewController.modalPresentationStyle = UIModalPresentationStyle.FormSheet
            }
            presentViewController(introViewController, animated: true) {}

            return true
        }

        return false
    }

    func introViewControllerDidFinish(introViewController: IntroViewController) {
        introViewController.dismissViewControllerAnimated(true) { finished in
            if self.navigationController?.viewControllers.count > 1 {
                self.navigationController?.popToRootViewControllerAnimated(true)
            }
        }
    }
}

extension BrowserViewController: KeyboardHelperDelegate {
    func keyboardHelper(keyboardHelper: KeyboardHelper, keyboardWillShowWithState state: KeyboardState) {
        keyboardState = state
        updateViewConstraints()

        UIView.animateWithDuration(state.animationDuration) {
            UIView.setAnimationCurve(state.animationCurve)
            self.findInPageContainer.layoutIfNeeded()
            self.snackBars.layoutIfNeeded()
        }



        if let loginsHelper = tabManager.selectedTab?.getHelper(LoginsHelper) {
            // keyboardWillShowWithState is called during a hide (brilliant), and because PW button setup is async make sure to exit here if already showing the button, or the show code will be called after kb hide
            if !urlBar.pwdMgrButton.hidden || loginsHelper.getKeyboardAccessory() != nil {
                return
            }

                loginsHelper.passwordManagerButtonSetup({ (shouldShow) in
                if UIDevice.currentDevice().userInterfaceIdiom == .Pad {
                    self.urlBar.pwdMgrButton.hidden = !shouldShow
                    
                    let icon = ThirdPartyPasswordManagerType.icon(type: PasswordManagerButtonSetting.currentSetting)
                    self.urlBar.pwdMgrButton.setImage(icon, forState: .Normal)

                    self.urlBar.setNeedsUpdateConstraints()
                }
            })
        }
    }

    func keyboardHelper(keyboardHelper: KeyboardHelper, keyboardDidShowWithState state: KeyboardState) {
    }

    func keyboardHelper(keyboardHelper: KeyboardHelper, keyboardWillHideWithState state: KeyboardState) {
        keyboardState = nil
        updateViewConstraints()

        UIView.animateWithDuration(state.animationDuration) {
            UIView.setAnimationCurve(state.animationCurve)
            self.findInPageContainer.layoutIfNeeded()
            self.snackBars.layoutIfNeeded()
        }
        
        if let loginsHelper = tabManager.selectedTab?.getHelper(LoginsHelper) {
            loginsHelper.hideKeyboardAccessory()
            urlBar.pwdMgrButton.hidden = true
            urlBar.setNeedsUpdateConstraints()
        }
    }
}

extension BrowserViewController: SessionRestoreHelperDelegate {
    func sessionRestoreHelper(helper: SessionRestoreHelper, didRestoreSessionForBrowser browser: Browser) {
        browser.restoring = false

        if let tab = tabManager.selectedTab where tab.webView === browser.webView {
            updateUIForReaderHomeStateForTab(tab)
        }
    }
}

extension BrowserViewController: TabTrayDelegate {
    // This function animates and resets the browser chrome transforms when
    // the tab tray dismisses.
    func tabTrayDidDismiss(tabTray: TabTrayController) {
        resetBrowserChrome()
    }

    func tabTrayDidAddBookmark(tab: Browser) {
        self.addBookmark(tab.url, title: tab.title)
    }


    func tabTrayDidAddToReadingList(tab: Browser) -> ReadingListClientRecord? {
        guard let url = tab.url?.absoluteString where url.characters.count > 0 else { return nil }
        return profile.readingList?.createRecordWithURL(url, title: tab.title ?? url, addedBy: UIDevice.currentDevice().name).successValue
    }

    func tabTrayRequestsPresentationOf(viewController viewController: UIViewController) {
        self.presentViewController(viewController, animated: false, completion: nil)
    }
}

// MARK: Browser Chrome Theming
extension BrowserViewController: Themeable {

    func applyTheme(themeName: String) {
        urlBar.applyTheme(themeName)
        toolbar?.applyTheme(themeName)
        //readerModeBar?.applyTheme(themeName)

        // TODO: Check if blur is enabled
        // Should be added to theme, instead of handled here
        switch(themeName) {
        case Theme.NormalMode:
            statusBarOverlay.backgroundColor = BraveUX.ToolbarsBackgroundSolidColor
            header.blurStyle = .Light
            footerBackground?.blurStyle = .Light
        case Theme.PrivateMode:
            statusBarOverlay.backgroundColor = BraveUX.DarkToolbarsBackgroundSolidColor
            header.blurStyle = .Dark
            footerBackground?.blurStyle = .Dark
        default:
            log.debug("Unknown Theme \(themeName)")
        }
        
        self.currentThemeName = themeName
    }
}

// A small convienent class for wrapping a view with a blur background that can be modified
class BlurWrapper: UIView {
    var blurStyle: UIBlurEffectStyle = .ExtraLight {
        didSet {
            let newEffect = UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
            effectView.removeFromSuperview()
            effectView = newEffect
            insertSubview(effectView, belowSubview: wrappedView)
            effectView.snp_remakeConstraints { make in
                make.edges.equalTo(self)
            }
        }
    }

    var effectView: UIVisualEffectView
    private var wrappedView: UIView

    init(view: UIView) {
        wrappedView = view
        effectView = UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
        super.init(frame: CGRectZero)

        addSubview(effectView)
        addSubview(wrappedView)

        effectView.snp_makeConstraints { make in
            make.edges.equalTo(self)
        }

        wrappedView.snp_makeConstraints { make in
            make.edges.equalTo(self)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

protocol Themeable {
    func applyTheme(themeName: String)
}

extension BrowserViewController: JSPromptAlertControllerDelegate {
    func promptAlertControllerDidDismiss(alertController: JSPromptAlertController) {
        showQueuedAlertIfAvailable()
    }
}
