/*
* Copyright (c) 2015, Tidepool Project
*
* This program is free software; you can redistribute it and/or modify it under
* the terms of the associated License, which is identical to the BSD 2-Clause
* License as published by the Open Source Initiative at opensource.org.
*
* This program is distributed in the hope that it will be useful, but WITHOUT
* ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
* FOR A PARTICULAR PURPOSE. See the License for more details.
*
* You should have received a copy of the License along with this program; if
* not, you can obtain one from Tidepool Project at tidepool.org.
*/

import Foundation
import UIKit
import Alamofire
import SwiftyJSON
import CoreData
import CocoaLumberjack

protocol NoteAPIWatcher {
    // Notify caller that a cell has been updated...
    func loadingNotes(_ loading: Bool)
    func endRefresh()
    func addNotes(_ notes: [BlipNote])
    func addComments(_ notes: [BlipNote], messageId: String)
    func postComplete(_ note: BlipNote)
    func deleteComplete(_ note: BlipNote)
    func updateComplete(_ originalNote: BlipNote, editedNote: BlipNote)
}

protocol UsersFetchAPIWatcher {
    func viewableUsers(_ userIds: [String])
}

/// APIConnector is a singleton object with the main responsibility of communicating to the Tidepool service:
/// - Given a username and password, login.
/// - Can refresh connection.
/// - Fetches Tidepool data.
/// - Provides online/offline statis.
class APIConnector {
    
    static var _connector: APIConnector?
    /// Supports a singleton for the application.
    class func connector() -> APIConnector {
        if _connector == nil {
        _connector = APIConnector()
        }
        return _connector!
    }
    
    // MARK: - Constants
    
    fileprivate let kSessionTokenDefaultKey = "SToken"
    fileprivate let kCurrentServiceDefaultKey = "SCurrentService"
    fileprivate let kSessionTokenHeaderId = "X-Tidepool-Session-Token"
    fileprivate let kSessionTokenResponseId = "x-tidepool-session-token"

    // Error domain and codes
    fileprivate let kTidepoolMobileErrorDomain = "TidepoolMobileErrorDomain"
    fileprivate let kNoSessionTokenErrorCode = -1
    
    // Session token, acquired on login and saved in NSUserDefaults
    // TODO: save in database?
    fileprivate var _sessionToken: String?
    var sessionToken: String? {
        set(newToken) {
            if ( newToken != nil ) {
                UserDefaults.standard.setValue(newToken, forKey:kSessionTokenDefaultKey)
            } else {
                UserDefaults.standard.removeObject(forKey: kSessionTokenDefaultKey)
            }
            UserDefaults.standard.synchronize()
            _sessionToken = newToken
        }
        get {
            return _sessionToken
        }
    }
    
    // Dictionary of servers and their base URLs
    let kServers = [
        "Development" :  "https://dev-api.tidepool.org",
        "Staging" :      "https://stg-api.tidepool.org",
        "Integration" :  "https://int-api.tidepool.org",
        "Production" :   "https://api.tidepool.org"
    ]
    let kSortedServerNames = [
        "Development",
        "Staging",
        "Integration",
        "Production"
    ]
    fileprivate let kDefaultServerName = "Production"
    //fileprivate let kDefaultServerName = "Integration"

    fileprivate var _currentService: String?
    var currentService: String? {
        set(newService) {
            if newService == nil {
                UserDefaults.standard.removeObject(forKey: kCurrentServiceDefaultKey)
                UserDefaults.standard.synchronize()
                _currentService = nil
            } else {
                if kServers[newService!] != nil {
                    UserDefaults.standard.setValue(newService, forKey: kCurrentServiceDefaultKey)
                    UserDefaults.standard.synchronize()
                    _currentService = newService
                }
            }
        }
        get {
            if _currentService == nil {
                if let service = UserDefaults.standard.string(forKey: kCurrentServiceDefaultKey) {
                    // don't set a service this build does not support
                    if kServers[service] != nil {
                        _currentService = service
                    }
                }
            }
            if _currentService == nil || kServers[_currentService!] == nil {
                _currentService = kDefaultServerName
            }
            return _currentService
        }
    }
    
    // Base URL for API calls, set during initialization
    var baseUrl: URL?
    var baseUrlString: String?

    // Reachability object, valid during lifetime of this APIConnector, and convenience function that uses this
    // Register for ReachabilityChangedNotification to monitor reachability changes             
    var reachability: Reachability?
    func isConnectedToNetwork() -> Bool {
        if let reachability = reachability {
            return reachability.isReachable
        } else {
            DDLogError("Reachability object not configured!")
            return true
        }
    }

    func serviceAvailable() -> Bool {
        if !isConnectedToNetwork() || sessionToken == nil {
            return false
        }
        return true
    }

    // MARK: Initialization
    
    /// Creator of APIConnector must call this function after init!
    func configure() -> APIConnector {
        self.baseUrlString = kServers[currentService!]!
        self.baseUrl = URL(string: baseUrlString!)!
        DDLogInfo("Using service: \(String(describing: self.baseUrl))")
        self.sessionToken = UserDefaults.standard.string(forKey: kSessionTokenDefaultKey)
        if let reachability = reachability {
            reachability.stopNotifier()
        }
        self.reachability = Reachability()
        
        do {
           try reachability?.startNotifier()
        } catch {
            DDLogError("Unable to start notifier!")
        }
        return self
    }
    
    deinit {
        reachability?.stopNotifier()
    }
    
    func switchToServer(_ serverName: String) {
        if (currentService != serverName) {
            currentService = serverName
            // refresh connector since there is a new service...
            _ = configure()
            DDLogInfo("Switched to \(serverName) server")
            
            let notification = Notification(name: Notification.Name(rawValue: "switchedToNewServer"), object: nil)
            NotificationCenter.default.post(notification)
            
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                appDelegate.logout()
            }
        }
    }
    
    /// Logs in the user and obtains the session token for the session (stored internally)
    func login(_ username: String, password: String, completion: @escaping (Result<User>, Int?) -> (Void)) {
        // Similar to email inputs in HTML5, trim the email (username) string of whitespace
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Clear in case it was set while logged out...
        self.lastNetworkError = nil
        // Set our endpoint for login
        let endpoint = "auth/login"
        
        // Create the authorization string (user:pass base-64 encoded)
        let base64LoginString = NSString(format: "%@:%@", trimmedUsername, password)
            .data(using: String.Encoding.utf8.rawValue)?
            .base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0))
        
        // Set our headers with the login string
        let headers = ["Authorization" : "Basic " + base64LoginString!]
        
        // Send the request and deal with the response as JSON
        UIApplication.shared.isNetworkActivityIndicatorVisible = true
        sendRequest(.post, endpoint: endpoint, headers:headers).responseJSON { response in
            UIApplication.shared.isNetworkActivityIndicatorVisible = false
            if ( response.result.isSuccess ) {
                // Look for the auth token
                self.sessionToken = response.response!.allHeaderFields[self.kSessionTokenResponseId] as! String?
                let json = JSON(response.result.value!)
                
                // Create the User object
                // TODO: Should this call be made in TidepoolMobileDataController?
                let moc = TidepoolMobileDataController.sharedInstance.mocForCurrentUser()
                if let user = User.fromJSON(json, email: trimmedUsername, moc: moc) {
                    TidepoolMobileDataController.sharedInstance.loginUser(user)
                    APIConnector.connector().trackMetric("Logged In")
                    completion(Result.success(user), nil)
                } else {
                    APIConnector.connector().trackMetric("Log In Failed")
                    TidepoolMobileDataController.sharedInstance.logoutUser()
                    completion(Result.failure(NSError(domain: self.kTidepoolMobileErrorDomain,
                        code: -1,
                        userInfo: ["description":"Could not create user from JSON", "result":response.result.value!])), -1)
                }
            } else {
                APIConnector.connector().trackMetric("Log In Failed")
                TidepoolMobileDataController.sharedInstance.logoutUser()
                let statusCode = response.response?.statusCode
                completion(Result.failure(response.result.error!), statusCode)
            }
        }
    }
 
    func fetchProfile(_ userId: String, _ completion: @escaping (Result<JSON>) -> (Void)) {
        // Set our endpoint for the user profile
        // format is like: https://api.tidepool.org/metadata/f934a287c4/profile
        let endpoint = "metadata/" + userId + "/profile"
        UIApplication.shared.isNetworkActivityIndicatorVisible = true
        DDLogInfo("fetchProfile endpoint: \(endpoint)")
        sendRequest(.get, endpoint: endpoint).responseJSON { response in
            UIApplication.shared.isNetworkActivityIndicatorVisible = false
            if ( response.result.isSuccess ) {
                let json = JSON(response.result.value!)
                if let jsonStr = json.rawString() {
                    DDLogInfo("profile json: \(jsonStr)")
                }
                completion(Result.success(json))
            } else {
                // Failure
                completion(Result.failure(response.result.error!))
            }
        }
    }
    
    func fetchUserSettings(_ userId: String, _ completion: @escaping (Result<JSON>) -> (Void)) {
        // Set our endpoint for the user profile
        // format is like: https://api.tidepool.org/metadata/f934a287c4/settings
        let endpoint = "metadata/" + userId + "/settings"
        UIApplication.shared.isNetworkActivityIndicatorVisible = true
        sendRequest(.get, endpoint: endpoint).responseJSON { response in
            UIApplication.shared.isNetworkActivityIndicatorVisible = false
            if ( response.result.isSuccess ) {
                let json = JSON(response.result.value!)
                completion(Result.success(json))
            } else {
                // Failure
                if let httpResponse = response.response, httpResponse.statusCode ==  404 {
                    DDLogInfo("No user settings found on service!")
                } else {
                    DDLogInfo("User settings fetched failed with result: \(response.result.error!)")
                }
                completion(Result.failure(response.result.error!))
            }
        }
    }
    
    // When offline just stash metrics in metricsCache array
    fileprivate var metricsCache: [String] = []
    // Used so we only have one metric send in progress at a time, to help balance service load a bit...
    fileprivate var metricSendInProgress = false
    func trackMetric(_ metric: String, flushBuffer: Bool = false) {
        // Set our endpoint for the event tracking
        // Format: https://api.tidepool.org/metrics/thisuser/urchin%20-%20Remember%20Me%20Used?source=urchin&sourceVersion=1.1
        // Format: https://api.tidepool.org/metrics/thisuser/tidepool-Viewed%20Hamburger%20Menu?source=tidepool&sourceVersion=0%2E8%2E1

        metricsCache.append(metric)
        if !serviceAvailable() || (metricSendInProgress && !flushBuffer) {
            //DDLogInfo("Offline: trackMetric stashed: \(metric)")
            return
        }
        
        let nextMetric = metricsCache.removeFirst()
        let endpoint = "metrics/thisuser/tidepool-" + nextMetric
        let parameters = ["source": "tidepool", "sourceVersion": UIApplication.appVersion()]
        metricSendInProgress = true
        sendRequest(.get, endpoint: endpoint, parameters: parameters as [String : AnyObject]?).responseJSON { response in
            self.metricSendInProgress = false
            if let theResponse = response.response {
                let statusCode = theResponse.statusCode
                if statusCode == 200 {
                    DDLogInfo("Tracked metric: \(nextMetric)")
                    if !self.metricsCache.isEmpty {
                        self.trackMetric(self.metricsCache.removeFirst(), flushBuffer: flushBuffer)
                    }
                } else {
                    DDLogError("Failed status code: \(statusCode) for tracking metric: \(metric)")
                    self.lastNetworkError = statusCode
                    if let error = response.result.error {
                        DDLogError("NSError: \(error)")
                    }
                }
            } else {
                DDLogError("Invalid response for tracking metric: \(response.result.error!)")
            }
        }
    }
    
    /// Remembers last network error for authorization problem monitoring
    var lastNetworkError: Int?
    func logout(_ completion: () -> (Void)) {
        // Clear our session token and remove entries from the db
        APIConnector.connector().trackMetric("Logged Out", flushBuffer: true)
        self.lastNetworkError = nil
        self.sessionToken = nil
        TidepoolMobileDataController.sharedInstance.logoutUser()
        completion()
    }
    
    func refreshToken(_ completion: @escaping (_ succeeded: Bool, _ responseStatusCode: Int) -> (Void)) {
        
        let endpoint = "/auth/login"
        
        if self.sessionToken == nil || TidepoolMobileDataController.sharedInstance.currentUserId == nil {
            // We don't have a session token to refresh.
            completion(false, 0)
            return
        }
        
        // Post the request.
        UIApplication.shared.isNetworkActivityIndicatorVisible = true
        self.sendRequest(.get, endpoint:endpoint).responseJSON { response in
            UIApplication.shared.isNetworkActivityIndicatorVisible = false
            if ( response.result.isSuccess ) {
                DDLogInfo("Session token updated")
                self.sessionToken = response.response!.allHeaderFields[self.kSessionTokenResponseId] as! String?
                completion(true, response.response?.statusCode ?? 0)
            } else {
                if let error = response.result.error {
                    let message = "Refresh token failed, error: \(error)"
                    DDLogError(message)
                    UIApplication.localNotifyMessage(message)

                    // TODO: handle network offline!
                }
                completion(false, response.response?.statusCode ?? 0)
            }
        }
    }
    
    /** For now this method returns the result as a JSON object. The result set can be huge, and we want processing to
     *  happen outside of this method until we have something a little less firehose-y.
     */
    func getUserData(_ completion: @escaping (Result<JSON>) -> (Void)) {
        // Set our endpoint for the user data
        let userId = TidepoolMobileDataController.sharedInstance.currentViewedUser!.userid
        let endpoint = "data/" + userId
        
        UIApplication.shared.isNetworkActivityIndicatorVisible = true
        sendRequest(.get, endpoint: endpoint).responseJSON { response in
            UIApplication.shared.isNetworkActivityIndicatorVisible = false
            if ( response.result.isSuccess ) {
                let json = JSON(response.result.value!)
                completion(Result.success(json))
            } else {
                // Failure
                completion(Result.failure(response.result.error!))
            }
        }
    }
    
    func getReadOnlyUserData(_ startDate: Date? = nil, endDate: Date? = nil, objectTypes: String = "smbg,bolus,cbg,wizard,basal,food", completion: @escaping (Result<JSON>) -> (Void)) {
        // Set our endpoint for the user data
        // TODO: centralize define of read-only events!
        // request format is like: https://api.tidepool.org/data/f934a287c4?endDate=2015-11-17T08%3A00%3A00%2E000Z&startDate=2015-11-16T12%3A00%3A00%2E000Z&type=smbg%2Cbolus%2Ccbg%2Cwizard%2Cbasal
        let userId = TidepoolMobileDataController.sharedInstance.currentViewedUser!.userid
        let endpoint = "data/" + userId
        UIApplication.shared.isNetworkActivityIndicatorVisible = true
        DDLogInfo("getReadOnlyUserData request start")
        // TODO: If there is no data returned, I get a failure case with status code 200, and error FAILURE: Error Domain=NSCocoaErrorDomain Code=3840 "Invalid value around character 0." UserInfo={NSDebugDescription=Invalid value around character 0.} ] Maybe an Alamofire issue?
        var parameters: Dictionary = ["type": objectTypes]
        if let startDate = startDate {
            // NOTE: start date is excluded (i.e., dates > start date)
            parameters.updateValue(TidepoolMobileUtils.dateToJSON(startDate), forKey: "startDate")
        }
        if let endDate = endDate {
            // NOTE: end date is included (i.e., dates <= end date)
            parameters.updateValue(TidepoolMobileUtils.dateToJSON(endDate), forKey: "endDate")
        }
        sendRequest(.get, endpoint: endpoint, parameters: parameters as [String : AnyObject]?).responseJSON { response in
            UIApplication.shared.isNetworkActivityIndicatorVisible = false
            DDLogInfo("getReadOnlyUserData request complete")
            if (response.result.isSuccess) {
                let json = JSON(response.result.value!)
                var validResult = true
                if let status = json["status"].number {
                    let statusCode = Int(truncating: status)
                    DDLogInfo("getReadOnlyUserData includes status field: \(statusCode)")
                    // TODO: determine if any status is indicative of failure here! Note that if call was successful, there will be no status field in the json result. The only verified error response is 403 which happens when we pass an invalid token.
                    if statusCode == 401 || statusCode == 403 {
                        validResult = false
                        self.lastNetworkError = statusCode
                        completion(Result.failure(NSError(domain: self.kTidepoolMobileErrorDomain,
                            code: statusCode,
                            userInfo: nil)))
                    }
                }
                if validResult {
                    completion(Result.success(json))
                }
            } else {
                // Failure: typically, no data were found:
                // Error Domain=NSCocoaErrorDomain Code=3840 "Invalid value around character 0." UserInfo={NSDebugDescription=Invalid value around character 0.}
                if let theResponse = response.response {
                    let statusCode = theResponse.statusCode
                    if statusCode != 200 {
                        DDLogError("Failure status code: \(statusCode) for getReadOnlyUserData")
                        APIConnector.connector().trackMetric("Tidepool Data Fetch Failure - Code " + String(statusCode))
                    }
                    // Otherwise, just indicates no data were found...
                } else {
                    DDLogError("Invalid response for getReadOnlyUserData metric")
                }
                completion(Result.failure(response.result.error!))
            }
        }
    }
    
    // MARK: - Internal methods
    
    // User-agent string, based on that from Alamofire, but common regardless of whether Alamofire library is used
    private func userAgentString() -> String {
        if _userAgentString == nil {
            _userAgentString = {
                if let info = Bundle.main.infoDictionary {
                    let executable = info[kCFBundleExecutableKey as String] as? String ?? "Unknown"
                    let bundle = info[kCFBundleIdentifierKey as String] as? String ?? "Unknown"
                    let appVersion = info["CFBundleShortVersionString"] as? String ?? "Unknown"
                    let appBuild = info[kCFBundleVersionKey as String] as? String ?? "Unknown"
                    
                    let osNameVersion: String = {
                        let version = ProcessInfo.processInfo.operatingSystemVersion
                        let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
                        
                        let osName: String = {
                            #if os(iOS)
                            return "iOS"
                            #elseif os(watchOS)
                            return "watchOS"
                            #elseif os(tvOS)
                            return "tvOS"
                            #elseif os(macOS)
                            return "OS X"
                            #elseif os(Linux)
                            return "Linux"
                            #else
                            return "Unknown"
                            #endif
                        }()
                        
                        return "\(osName) \(versionString)"
                    }()
                    
                    return "\(executable)/\(appVersion) (\(bundle); build:\(appBuild); \(osNameVersion))"
                }
                
                return "TidepoolMobile"
            }()
        }
        return _userAgentString!
    }
    private var _userAgentString: String?
    
    private func sessionManager() -> SessionManager {
        if _sessionManager == nil {
            // get the default headers
            var alamoHeaders = Alamofire.SessionManager.defaultHTTPHeaders
            // add our custom user-agent
            alamoHeaders["User-Agent"] = self.userAgentString()
            // create a custom session configuration
            let configuration = URLSessionConfiguration.default
            // add the headers
            configuration.httpAdditionalHeaders = alamoHeaders
            // create a session manager with the configuration
            _sessionManager = Alamofire.SessionManager(configuration: configuration)
        }
        return _sessionManager!
    }
    private var _sessionManager: SessionManager?
    
    // Sends a request to the specified endpoint
    private func sendRequest(_ requestType: HTTPMethod? = .get,
        endpoint: (String),
        parameters: [String: AnyObject]? = nil,
        headers: [String: String]? = nil) -> (DataRequest)
    {
        let url = baseUrl!.appendingPathComponent(endpoint)
        
        // Get our API headers (the session token) and add any headers supplied by the caller
        var apiHeaders = getApiHeaders()
        if ( apiHeaders != nil ) {
            if ( headers != nil ) {
                for(k, v) in headers! {
                    _ = apiHeaders?.updateValue(v, forKey: k)
                }
            }
        } else {
            // We have no headers of our own to use- just use the caller's directly
            apiHeaders = headers
        }
        
        // Fire off the network request
        DDLogInfo("sendRequest url: \(url), params: \(parameters ?? [:]), headers: \(apiHeaders ?? [:])")
        return self.sessionManager().request(url, method: requestType!, parameters: parameters, headers: apiHeaders).validate()
        //debugPrint(result)
        //return result
    }
    
    func getApiHeaders() -> [String: String]? {
        if ( sessionToken != nil ) {
            return [kSessionTokenHeaderId : sessionToken!]
        }
        return nil
    }
    

    //
    // MARK: - Note fetching and uploading
    //
    
    func getAllViewableUsers(_ fetchWatcher: UsersFetchAPIWatcher) {
        
        let urlExtension = "/access/groups/" + TidepoolMobileDataController.sharedInstance.currentUserId!
        
        let headerDict = [kSessionTokenHeaderId:"\(sessionToken!)"]
        
        let completion = { (response: URLResponse?, data: Data?, error: NSError?) -> Void in
            if let httpResponse = response as? HTTPURLResponse {
                if (httpResponse.statusCode == 200) {
                    DDLogInfo("Found viewable users")
                    let jsonResult: NSDictionary = ((try? JSONSerialization.jsonObject(with: data!, options: JSONSerialization.ReadingOptions.mutableContainers)) as? NSDictionary)!
                    var users: [String] = []
                    for key in jsonResult.keyEnumerator() {
                        users.append(key as! String)
                    }
                    fetchWatcher.viewableUsers(users)
                } else {
                    DDLogError("Did not find viewable users - invalid status code \(httpResponse.statusCode)")
                    self.alertWithOkayButton(self.unknownError, message: self.unknownErrorMessage)
                }
            } else {
                DDLogError("Did not find viewable users - response could not be parsed")
                self.alertWithOkayButton(self.unknownError, message: self.unknownErrorMessage)
            }
        }
        
        blipRequest("GET", urlExtension: urlExtension, headerDict: headerDict, body: nil, completion: completion)
    }

    func getNotesForUserInDateRange(_ fetchWatcher: NoteAPIWatcher, userid: String, start: Date?, end: Date?) {
        
        if sessionToken == nil {
            return
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        var startString = ""
        if let start = start {
            startString = "?starttime=" + dateFormatter.string(from: start)
        }
        
        var endString = ""
        if let end = end {
            endString = "&endtime="  + dateFormatter.string(from: end)
        }
        
        let urlExtension = "/message/notes/" + userid + startString + endString
        let headerDict = [kSessionTokenHeaderId:"\(sessionToken!)"]
        
        let preRequest = { () -> Void in
            fetchWatcher.loadingNotes(true)
        }
        
        let completion = { (response: URLResponse?, data: Data?, error: NSError?) -> Void in
            
            // End refreshing for refresh control
            fetchWatcher.endRefresh()
            
            if let httpResponse = response as? HTTPURLResponse, let data = data {
                if (httpResponse.statusCode == 200) {
                    DDLogInfo("Got notes for user (\(userid)) in given date range: \(startString) to \(endString)")
                    var notes: [BlipNote] = []
                    
                    if let jsonResult: NSDictionary = ((try? JSONSerialization.jsonObject(with: data, options: JSONSerialization.ReadingOptions.mutableContainers)) as? NSDictionary) {
                        
                        //DDLogInfo("notes: \(JSON(data!))")
                        let messages: NSArray = jsonResult.value(forKey: "messages") as! NSArray
                        
                        let dateFormatter = DateFormatter()
                        
                        for message in messages {
                            let id = (message as AnyObject).value(forKey: "id") as! String
                            let otheruserid = (message as AnyObject).value(forKey: "userid") as! String
                            let groupid = (message as AnyObject).value(forKey: "groupid") as! String
                            
                            
                            var timestamp: Date?
                            let timestampString = (message as AnyObject).value(forKey: "timestamp") as? String
                            if let timestampString = timestampString {
                                timestamp = dateFormatter.dateFromISOString(timestampString)
                            }
                            
                            var createdtime: Date?
                            let createdtimeString = (message as AnyObject).value(forKey: "createdtime") as? String
                            if let createdtimeString = createdtimeString {
                                createdtime = dateFormatter.dateFromISOString(createdtimeString)
                            } else {
                                createdtime = timestamp
                            }

                            if let timestamp = timestamp, let createdtime = createdtime {
                                let messagetext = (message as AnyObject).value(forKey: "messagetext") as! String
                                
                                let otheruser = BlipUser(userid: otheruserid)
                                let userDict = (message as AnyObject).value(forKey: "user") as! NSDictionary
                                otheruser.processUserDict(userDict)
                                
                                let note = BlipNote(id: id, userid: otheruserid, groupid: groupid, timestamp: timestamp, createdtime: createdtime, messagetext: messagetext, user: otheruser)
                                notes.append(note)
                            } else {
                                if timestamp == nil {
                                    DDLogError("Ignoring fetched note with invalid format timestamp string: \(String(describing: timestampString))")
                                }
                                if createdtime == nil {
                                    DDLogError("Ignoring fetched note with invalid create time string: \(String(describing: createdtimeString))")
                                }
                            }
                        }
                        
                        fetchWatcher.addNotes(notes)
                    } else {
                        DDLogError("No notes retrieved - unable to parse json result!")
                        self.alertWithOkayButton(self.unknownError, message: self.unknownErrorMessage)
                    }
                } else if (httpResponse.statusCode == 404) {
                    DDLogInfo("No notes retrieved, status code: \(httpResponse.statusCode), userid: \(userid)")
                } else {
                    DDLogError("No notes retrieved - invalid status code \(httpResponse.statusCode)")
                    self.alertWithOkayButton(self.unknownError, message: self.unknownErrorMessage)
                }
                
                fetchWatcher.loadingNotes(false)
                let notification = Notification(name: Notification.Name(rawValue: "doneFetching"), object: nil)
                NotificationCenter.default.post(notification)
            } else {
                // TODO: have seen this... need to dump response and debug!
                DDLogError("No notes retrieved - could not parse response")
                self.alertWithOkayButton(self.unknownError, message: self.unknownErrorMessage)
            }
        }
        
        blipRequest("GET", urlExtension: urlExtension, headerDict: headerDict, body: nil, preRequest: preRequest, completion: completion)
    }

    func getMessageThreadForNote(_ fetchWatcher: NoteAPIWatcher, messageId: String) {
        
        if sessionToken == nil {
            return
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let urlExtension = "/message/thread/" + messageId
        
        let headerDict = [kSessionTokenHeaderId:"\(sessionToken!)"]
        
        let preRequest = { () -> Void in
            fetchWatcher.loadingNotes(true)
        }
        
        let completion = { (response: URLResponse?, data: Data?, error: NSError?) -> Void in
            
            // End refreshing for refresh control
            fetchWatcher.endRefresh()
            
            if let httpResponse = response as? HTTPURLResponse {
                if (httpResponse.statusCode == 200) {
                    DDLogInfo("Got thread for note \(messageId)")
                    var notes: [BlipNote] = []
                    
                    let jsonResult: NSDictionary = ((try? JSONSerialization.jsonObject(with: data!, options: JSONSerialization.ReadingOptions.mutableContainers)) as? NSDictionary)!
                    
                    DDLogInfo("notes: \(jsonResult)")
                    let messages: NSArray = jsonResult.value(forKey: "messages") as! NSArray
                    let dateFormatter = DateFormatter()
                    
                    for message in messages {
                        let id = (message as AnyObject).value(forKey: "id") as! String
                        let parentmessage = (message as AnyObject).value(forKey: "parentmessage") as? String
                        let otheruserid = (message as AnyObject).value(forKey: "userid") as! String
                        let groupid = (message as AnyObject).value(forKey: "groupid") as! String
                        
                        var timestamp: Date?
                        let timestampString = (message as AnyObject).value(forKey: "timestamp") as? String
                        if let timestampString = timestampString {
                            timestamp = dateFormatter.dateFromISOString(timestampString)
                        }

                        var createdtime: Date?
                        let createdtimeString = (message as AnyObject).value(forKey: "createdtime") as? String
                        if let createdtimeString = createdtimeString {
                            createdtime = dateFormatter.dateFromISOString(createdtimeString)
                        } else {
                            createdtime = timestamp
                        }
                        
                        if let timestamp = timestamp, let createdtime = createdtime {
                            let messagetext = (message as AnyObject).value(forKey: "messagetext") as! String
                            
                            let otheruser = BlipUser(userid: otheruserid)
                            let userDict = (message as AnyObject).value(forKey: "user") as! NSDictionary
                            otheruser.processUserDict(userDict)
                            
                            let note = BlipNote(id: id, userid: otheruserid, groupid: groupid, timestamp: timestamp, createdtime: createdtime, messagetext: messagetext, user: otheruser)
                            note.parentmessage = parentmessage
                            notes.append(note)
                        } else {
                            if timestamp == nil {
                                DDLogError("Ignoring fetched comment with invalid format timestamp string: \(String(describing: timestampString))")
                            }
                            if createdtime == nil {
                                DDLogError("Ignoring fetched comment with invalid create time string: \(String(describing: createdtimeString))")
                            }
                        }
                    }
                    
                    fetchWatcher.addComments(notes, messageId: messageId)
                } else if (httpResponse.statusCode == 404) {
                    DDLogError("No notes retrieved, status code: \(httpResponse.statusCode), messageId: \(messageId)")
                } else {
                    DDLogError("No notes retrieved - invalid status code \(httpResponse.statusCode)")
                    self.alertWithOkayButton(self.unknownError, message: self.unknownErrorMessage)
                }
                
                fetchWatcher.loadingNotes(false)
                let notification = Notification(name: Notification.Name(rawValue: "doneFetching"), object: nil)
                NotificationCenter.default.post(notification)
            } else {
                DDLogError("No comments retrieved - could not parse response")
                self.alertWithOkayButton(self.unknownError, message: self.unknownErrorMessage)
            }
        }
        
        blipRequest("GET", urlExtension: urlExtension, headerDict: headerDict, body: nil, preRequest: preRequest, completion: completion)
    }
    
    func doPostWithNote(_ postWatcher: NoteAPIWatcher, note: BlipNote) {
        
        var urlExtension = ""
        if let parentMessage = note.parentmessage {
            // this is a reply
            urlExtension = "/message/reply/" + parentMessage
        } else {
            // this is a note, i.e., start of a thread
            urlExtension = "/message/send/" + note.groupid
        }
        
        let headerDict = [kSessionTokenHeaderId:"\(sessionToken!)", "Content-Type":"application/json"]
        
        let jsonObject = note.dictionaryFromNote()
        let body: Data?
        do {
            body = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
        } catch {
            body = nil
        }
        
        let completion = { (response: URLResponse?, data: Data?, error: NSError?) -> Void in
            if let httpResponse = response as? HTTPURLResponse {
                
                if (httpResponse.statusCode == 201) {
                    DDLogInfo("Sent note for groupid: \(note.groupid)")
                    
                    let jsonResult: NSDictionary = ((try? JSONSerialization.jsonObject(with: data!, options: JSONSerialization.ReadingOptions.mutableContainers)) as? NSDictionary)!
                    
                    note.id = jsonResult.value(forKey: "id") as! String
                    postWatcher.postComplete(note)
                    
                } else {
                    DDLogError("Did not send note for groupid \(note.groupid) - invalid status code \(httpResponse.statusCode)")
                    self.alertWithOkayButton(self.unknownError, message: self.unknownErrorMessage)
                }
            } else {
                DDLogError("Did not send note for groupid \(note.groupid) - could not parse response")
                self.alertWithOkayButton(self.unknownError, message: self.unknownErrorMessage)
            }
        }
        
        blipRequest("POST", urlExtension: urlExtension, headerDict: headerDict, body: body, completion: completion)
    }

    // update note or comment...
    func updateNote(_ updateWatcher: NoteAPIWatcher, editedNote: BlipNote, originalNote: BlipNote) {
        
        let urlExtension = "/message/edit/" + originalNote.id
        
        let headerDict = [kSessionTokenHeaderId:"\(sessionToken!)", "Content-Type":"application/json"]
        
        let jsonObject = editedNote.updatesFromNote()
        let body: Data?
        do {
            body = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
        } catch  {
            body = nil
        }
        
        let completion = { (response: URLResponse?, data: Data?, error: NSError?) -> Void in
            if let httpResponse = response as? HTTPURLResponse {
                if (httpResponse.statusCode == 200) {
                    DDLogInfo("Edited note with id \(originalNote.id)")
                    updateWatcher.updateComplete(originalNote, editedNote: editedNote)
                } else {
                    DDLogError("Did not edit note with id \(originalNote.id) - invalid status code \(httpResponse.statusCode)")
                    self.alertWithOkayButton(self.unknownError, message: self.unknownErrorMessage)
                }
            } else {
                DDLogError("Did not edit note with id \(originalNote.id) - could not parse response")
                self.alertWithOkayButton(self.unknownError, message: self.unknownErrorMessage)
            }
        }
        
        blipRequest("PUT", urlExtension: urlExtension, headerDict: headerDict, body: body, completion: completion)
    }
    
    // delete note or comment...
    func deleteNote(_ deleteWatcher: NoteAPIWatcher, noteToDelete: BlipNote) {
        let urlExtension = "/message/remove/" + noteToDelete.id
        
        let headerDict = [kSessionTokenHeaderId:"\(sessionToken!)"]
        
        let completion = { (response: URLResponse?, data: Data?, error: NSError?) -> Void in
            if let httpResponse = response as? HTTPURLResponse {
                if (httpResponse.statusCode == 202) {
                    DDLogInfo("Deleted note with id \(noteToDelete.id)")
                    deleteWatcher.deleteComplete(noteToDelete)
                } else {
                    DDLogError("Did not delete note with id \(noteToDelete.id) - invalid status code \(httpResponse.statusCode)")
                    self.alertWithOkayButton(self.unknownError, message: self.unknownErrorMessage)
                }
            } else {
                DDLogError("Did not delete note with id \(noteToDelete.id) - could not parse response")
                self.alertWithOkayButton(self.unknownError, message: self.unknownErrorMessage)
            }
        }
        
        blipRequest("DELETE", urlExtension: urlExtension, headerDict: headerDict, body: nil, completion: completion)
    }

    
    let unknownError: String = "Unknown Error Occurred"
    let unknownErrorMessage: String = "An unknown error occurred. We are working hard to resolve this issue."
    private var isShowingAlert = false
    
    private func alertWithOkayButton(_ title: String, message: String) {
        DDLogInfo("title: \(title), message: \(message)")
        if defaultDebugLevel != DDLogLevel.off {
            let callStackSymbols = Thread.callStackSymbols
            DDLogInfo("callStackSymbols: \(callStackSymbols)")
        }
        
        if (!isShowingAlert) {
            isShowingAlert = true
            
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { Void in
                self.isShowingAlert = false
            }))
            presentAlert(alert)
        }
    }

    private func presentAlert(_ alert: UIAlertController) {
        if var topController = UIApplication.shared.keyWindow?.rootViewController {
            while let presentedViewController = topController.presentedViewController {
                topController = presentedViewController
            }
            topController.present(alert, animated: true, completion: nil)
        }
    }
    
    func alertIfNetworkIsUnreachable() -> Bool {
        if serviceAvailable() {
            return false
        }
        let alert = UIAlertController(title: "Not Connected to Network", message: "This application requires a network to access the Tidepool service!", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: { Void in
            return
        }))
        presentAlert(alert)
        return true
    }
    
    func alertWhileNetworkIsUnreachable(_ completion: @escaping () -> (Void)) {
        if serviceAvailable() {
            completion()
            return
        }
        let alert = UIAlertController(title: "Not Connected to Network", message: "This application requires a network to access the Tidepool service!", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: { Void in
            self.alertWhileNetworkIsUnreachable {
                completion()
            }
        }))
        presentAlert(alert)
    }

    func blipRequest(_ method: String, urlExtension: String, headerDict: [String: String], body: Data?, preRequest: (() -> Void)? = nil, completion: @escaping (_ response: URLResponse?, _ data: Data?, _ error: NSError?) -> Void) {
        
        if (self.isConnectedToNetwork()) {
            preRequest?()
            
            let baseURL = kServers[currentService!]!
            var urlString = baseURL + urlExtension
            urlString = urlString.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed)!
            let url = URL(string: urlString)
            let request = NSMutableURLRequest(url: url!)
            request.httpMethod = method
            for (field, value) in headerDict {
                request.setValue(value, forHTTPHeaderField: field)
            }
            // make user-agent similar to that from Alamofire
            request.setValue(self.userAgentString(), forHTTPHeaderField: "User-Agent")
            request.httpBody = body
            
            UIApplication.shared.isNetworkActivityIndicatorVisible = true
            let task = URLSession.shared.dataTask(with: request as URLRequest) {
                (data, response, error) -> Void in
                DispatchQueue.main.async(execute: {
                    UIApplication.shared.isNetworkActivityIndicatorVisible = false
                    completion(response, data, (error as NSError?))
                })
                return
            }
            task.resume()
        } else {
            DDLogInfo("Not connected to network")
        }
    }
    
 }
