//
//  MenuAccountSettingsViewController.swift
//  TidepoolMobile
//
//  Created by Larry Kenyon on 9/14/15.
//  Copyright © 2015 Tidepool. All rights reserved.
//

import UIKit
import CocoaLumberjack
import TPHealthKitUploader

class MenuAccountSettingsViewController: UIViewController, UITextViewDelegate {

    var userSelectedSyncHealthData = false
    var userSelectedSwitchProfile = false
    var userSelectedLogout = false
    var userSelectedLoggedInUser = false
    var userSelectedExternalLink: URL? = nil
    var eventListViewController: EventListViewController? = nil

    @IBOutlet weak var loginAccount: UILabel!
    @IBOutlet weak var versionString: TidepoolMobileUILabel!
    @IBOutlet weak var usernameLabel: TidepoolMobileUILabel!
    @IBOutlet weak var sidebarView: UIView!
    @IBOutlet weak var healthKitSwitch: UISwitch!
    @IBOutlet weak var healthKitLabel: TidepoolMobileUILabel!
    @IBOutlet weak var healthStatusContainerView: UIStackView!
    @IBOutlet weak var healthExplanation: UILabel!
    @IBOutlet weak var healthStatusLine1: TidepoolMobileUILabel!
    @IBOutlet weak var healthStatusLine2: TidepoolMobileUILabel!
    @IBOutlet weak var syncHealthDataSeparator: TidepoolMobileUIView!
    @IBOutlet weak var syncHealthDataContainer: UIView!

    @IBOutlet weak var privacyTextField: UITextView!
    var hkTimeRefreshTimer: Timer?
    fileprivate let kHKTimeRefreshInterval: TimeInterval = 30.0
    private let hkUploader = TPUploaderAPI.connector().uploader()
    
    //
    // MARK: - Base Methods
    //

    override func viewDidLoad() {
        super.viewDidLoad()
        let curService = APIConnector.connector().currentService!
        if curService == "Production" {
            versionString.text = "v" + UIApplication.appVersion()
        } else{
            versionString.text = "v" + UIApplication.appVersion() + " on " + curService
        }
        loginAccount.text = TidepoolMobileDataController.sharedInstance.currentUserName
        
        //healthKitSwitch.tintColor = Styles.brightBlueColor
        //healthKitSwitch.thumbTintColor = Styles.whiteColor
        healthKitSwitch.onTintColor = Styles.brightBlueColor

        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self, selector: #selector(MenuAccountSettingsViewController.handleUploaderNotification(_:)), name: Notification.Name(rawValue: TPUploaderNotifications.Updated), object: nil)
    }

    deinit {
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: nil, object: nil)
        hkTimeRefreshTimer?.invalidate()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    override func viewWillAppear(_ animated: Bool) {
        DDLogInfo("MenuVC viewWillAppear")
        super.viewWillAppear(animated)
    }
    
    func menuWillOpen() {
        // Treat this like viewWillAppear...
        userSelectedLoggedInUser = false
        userSelectedSyncHealthData = false
        userSelectedSwitchProfile = false
        userSelectedLogout = false
        userSelectedExternalLink = nil

        usernameLabel.text = TidepoolMobileDataController.sharedInstance.userFullName
        configureHKInterface()

        // configure custom buttons
        sidebarView.setNeedsLayout()
        sidebarView.layoutIfNeeded()
        sidebarView.checkAdjustSubviewSizing()
    }
    
    //
    // MARK: - Navigation
    //

    @IBAction func done(_ segue: UIStoryboardSegue) {
        print("unwind segue to menuaccount done!")
    }

    //
    // MARK: - Button/switch handling
    //
    
    @IBAction func selectLoggedInUserButton(_ sender: Any) {
        userSelectedLoggedInUser = true
        self.hideSideMenuView()
    }
    
    @IBAction func syncHealthDataTapped(_ sender: AnyObject) {
        userSelectedSyncHealthData = true
        self.hideSideMenuView()
    }

    @IBAction func switchProfileTapped(_ sender: AnyObject) {
        userSelectedSwitchProfile = true
        self.hideSideMenuView()
    }
    
    @IBAction func supportButtonHandler(_ sender: AnyObject) {
        APIConnector.connector().trackMetric("Clicked Tidepool Support (Hamburger)")
        userSelectedExternalLink = URL(string: TPConstants.kTidepoolSupportURL)
        self.hideSideMenuView()
    }
    
    @IBAction func privacyButtonTapped(_ sender: Any) {
        APIConnector.connector().trackMetric("Clicked Privacy and Terms (Hamburger)")
        userSelectedExternalLink = URL(string: "http://tidepool.org/legal/")
        self.hideSideMenuView()
    }
    
    @IBAction func logOutTapped(_ sender: AnyObject) {
        userSelectedLogout = true
        self.hideSideMenuView()
    }

    @IBAction func debugSettingsTapped(_ sender: AnyObject) {
        self.debugSettings = DebugSettings(presentingViewController: self.eventListViewController)
        self.debugSettings?.showDebugMenuActionSheet()
    }

    //
    // MARK: - Healthkit Methods
    //
    
    @IBAction func enableHealthData(_ sender: AnyObject) {
        if let enableSwitch = sender as? UISwitch {
            if enableSwitch == healthKitSwitch {
                if enableSwitch.isOn {
                    // Note: this enable function is asynchronous, so interface enable won't be true for a while
                    // TODO: rewrite to pass along completion routine?
                    enableHealthKitInterfaceForCurrentUser()
                    APIConnector.connector().trackMetric("Connect to health on")
                    // Note: because of above, avoid calling healthKitInterfaceEnabledForCurrentUser immediately...
                    configureHKInterfaceForState(true)
                } else {
                    TidepoolMobileDataController.sharedInstance.disableHealthKitInterface()
                    APIConnector.connector().trackMetric("Connect to health off")
                    configureHKInterfaceForState(false)
                }
            }
        }
    }

    fileprivate func startHKTimeRefreshTimer() {
        if hkTimeRefreshTimer == nil {
            hkTimeRefreshTimer = Timer.scheduledTimer(timeInterval: kHKTimeRefreshInterval, target: self, selector: #selector(MenuAccountSettingsViewController.nextHKTimeRefresh), userInfo: nil, repeats: true)
        }
    }

    func stopHKTimeRefreshTimer() {
        hkTimeRefreshTimer?.invalidate()
        hkTimeRefreshTimer = nil
    }

    @objc func nextHKTimeRefresh() {
        //DDLogInfo("nextHKTimeRefresh")
        configureHKInterface()
    }
    
    @objc internal func handleUploaderNotification(_ notification: Notification) {
        DDLogInfo("handleUploaderNotification: \(notification.name)")
        configureHKInterface()
    }

    private func configureHKInterface() {
        let hkCurrentEnable = hkUploader.healthKitInterfaceEnabledForCurrentUser()
        healthKitSwitch.isOn = hkCurrentEnable
        configureHKInterfaceForState(hkCurrentEnable)
        configureSyncHealthButton(hkCurrentEnable)
    }
    
    // Note: this is used by the switch logic itself since the underlying interface enable lags asychronously behind the UI switch...
    private func configureHKInterfaceForState(_ hkCurrentEnable: Bool) {
        if hkCurrentEnable {
            self.configureHealthStatusLines()
            // make sure timer is turned on to prevent a stale interface...
            startHKTimeRefreshTimer()
        } else {
            stopHKTimeRefreshTimer()
        }
        
        // TODO: UI polish - this whole section should be removed from the stacked view if hideHealthKitUI is true, rather than showing empty space!
        
        let hideHealthKitUI = !hkUploader.shouldShowHealthKitUI()
        syncHealthDataContainer.isHidden = hideHealthKitUI
        healthKitSwitch.isHidden = hideHealthKitUI
        healthKitLabel.isHidden = hideHealthKitUI
        syncHealthDataSeparator.isHidden = hideHealthKitUI || !hkCurrentEnable
        healthStatusContainerView.isHidden = hideHealthKitUI || !hkCurrentEnable
        healthExplanation.isHidden = hideHealthKitUI || hkCurrentEnable
    }
    
    let kHealthSectionHeightEnabled: CGFloat = 122.0
    let kHealthSectionHeightDisabled: CGFloat = 80.0
    @IBOutlet weak var healthKitUISectionHeight: NSLayoutConstraint!
    @IBOutlet var syncHealthButtonItems: [UIView]!
    
    private func configureSyncHealthButton(_ enabled: Bool) {
        let hideButton = !enabled
        for item in syncHealthButtonItems {
            item.isHidden = hideButton
        }
        healthKitUISectionHeight.constant = enabled ? kHealthSectionHeightEnabled : kHealthSectionHeightDisabled
        sidebarView.layoutIfNeeded()
    }
    
    private func enableHealthKitInterfaceForCurrentUser() {
        if hkUploader.healthKitInterfaceConfiguredForOtherUser() {
            // use dialog to confirm delete with user!
            let curHKUserName = hkUploader.curHKUserName() ?? "Unknown"
            //let curUserName = usernameLabel.text!
            let titleString = "Are you sure?"
            let messageString = "A different account (" + curHKUserName + ") is currently associated with Health Data on this device"
            let alert = UIAlertController(title: titleString, message: messageString, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { Void in
                self.healthKitSwitch.isOn = false
                return
            }))
            alert.addAction(UIAlertAction(title: "Change Account", style: .default, handler: { Void in
                TidepoolMobileDataController.sharedInstance.enableHealthKitInterface()
            }))
            self.present(alert, animated: true, completion: nil)
        } else {
            TidepoolMobileDataController.sharedInstance.enableHealthKitInterface()
        }
    }
    
    let healthKitUploadStatusLastUploadTime: String = "Last %@ reading %@"
    let healthKitUploadStatusNoDataAvailableToUpload: String = "No data available to upload"
    let healthKitUploadStatusDaysUploaded: String = "Syncing day %d of %d"
    let healthKitUploadStatusUploadPausesWhenPhoneIsLocked: String = "Your screen must stay awake and unlocked"

    fileprivate func configureHealthStatusLines() {
        var healthStatusLine1Text = ""
        var healthStatusLine2Text = ""

        let isHistoricalAllActive = hkUploader.isUploadInProgressForMode(TPUploader.Mode.HistoricalAll)
        if isHistoricalAllActive {
            let (current, total) = TPUploaderAPI.connector().lastHistoricalUpload()
            
            healthStatusLine1Text = "Syncing Health data…"
            if let current = current, let total = total {
                healthStatusLine2Text = String(format: healthKitUploadStatusDaysUploaded, current, total)
            } else {
                healthStatusLine2Text = " "
            }
            healthStatusLine1.usage = "sidebarSettingHKMainStatus"
            healthStatusLine2.usage = "sidebarSettingHKMinorStatus"
        } else {
            var hadSuccessfulUpload = false
            var lastUploadTime = Date.distantPast
            var lastType = " "
            
            let currentStats = hkUploader.currentUploadStats()
            for stat in currentStats {
                if stat.hasSuccessfullyUploaded {
                    hadSuccessfulUpload = true
                    if stat.lastSuccessfulUploadTime.compare(lastUploadTime) == .orderedDescending {
                        lastUploadTime = stat.lastSuccessfulUploadTime
                        lastType = stat.typeName
                    }
                    DDLogInfo("Mode: \(stat.mode.rawValue)")
                    DDLogInfo("Type: \(stat.typeName)")
                    DDLogInfo("Last successful upload time: \(stat.lastSuccessfulUploadTime)")
                    DDLogInfo("")
                }
            }
            if hadSuccessfulUpload {
                let lastUploadTimeAgoInWords = lastUploadTime.timeAgoInWords(Date())
                healthStatusLine1Text = String(format: healthKitUploadStatusLastUploadTime, lastType, lastUploadTimeAgoInWords)
            } else {
                healthStatusLine1Text = healthKitUploadStatusNoDataAvailableToUpload
            }
            healthStatusLine1.usage = "sidebarSettingHKMainStatus"
            healthStatusLine2.usage = "sidebarSettingHKMinorStatus"
        }

        healthStatusLine1.text = healthStatusLine1Text
        healthStatusLine2.text = healthStatusLine2Text
    }
    
    fileprivate var debugSettings: DebugSettings?
}
