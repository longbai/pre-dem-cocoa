/*
 * Author: Andreas Linde <mail@andreaslinde.de>
 *         Kent Sutherland
 *
 * Copyright (c) 2012-2014 HockeyApp, Bit Stadium GmbH.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "PreSniffSDKEnums.h"

@protocol PreSniffManagerDelegate;

@class PRESBaseManager;
#if HOCKEYSDK_FEATURE_CRASH_REPORTER
@class PRESCrashManager;
#endif
#if HOCKEYSDK_FEATURE_UPDATES
@class BITUpdateManager;
#endif
#if HOCKEYSDK_FEATURE_STORE_UPDATES
@class BITStoreUpdateManager;
#endif
#if HOCKEYSDK_FEATURE_FEEDBACK
@class BITFeedbackManager;
#endif
#if HOCKEYSDK_FEATURE_AUTHENTICATOR
@class BITAuthenticator;
#endif
#if HOCKEYSDK_FEATURE_METRICS
@class PRESMetricsManager;
#endif

/** 
 The HockeySDK manager. Responsible for setup and management of all components
 
 This is the principal SDK class. It represents the entry point for the HockeySDK. The main promises of the class are initializing the SDK modules, providing access to global properties and to all modules. Initialization is divided into several distinct phases:
 
 1. Setup the [HockeyApp](http://hockeyapp.net/) app identifier and the optional delegate: This is the least required information on setting up the SDK and using it. It does some simple validation of the app identifier and checks if the app is running from the App Store or not.
 2. Provides access to the SDK modules `PRESCrashManager`, `BITUpdateManager`, and `BITFeedbackManager`. This way all modules can be further configured to personal needs, if the defaults don't fit the requirements.
 3. Configure each module.
 4. Start up all modules.
 
 The SDK is optimized to defer everything possible to a later time while making sure e.g. crashes on startup can also be caught and each module executes other code with a delay some seconds. This ensures that applicationDidFinishLaunching will process as fast as possible and the SDK will not block the startup sequence resulting in a possible kill by the watchdog process.

 All modules do **NOT** show any user interface if the module is not activated or not integrated.
 `PRESCrashManager`: Shows an alert on startup asking the user if he/she agrees on sending the crash report, if `[PRESCrashManager crashManagerStatus]` is set to `PRESCrashManagerStatusAlwaysAsk` (default)
 `BITUpdateManager`: Is automatically deactivated when the SDK detects it is running from a build distributed via the App Store. Otherwise if it is not deactivated manually, it will show an alert after startup informing the user about a pending update, if one is available. If the user then decides to view the update another screen is presented with further details and an option to install the update.
 `BITFeedbackManager`: If this module is deactivated or the user interface is nowhere added into the app, this module will not do anything. It will not fetch the server for data or show any user interface. If it is integrated, activated, and the user already used it to provide feedback, it will show an alert after startup if a new answer has been received from the server with the option to view it.
 
 Example:
 
    [[PreSniffManager sharedPreSniffManager]
      configureWithIdentifier:@"<AppIdentifierFromHockeyApp>"
                     delegate:nil];
    [[PreSniffManager sharedPreSniffManager] startManager];
 
 @warning The SDK is **NOT** thread safe and has to be set up on the main thread!
 
 @warning Most properties of all components require to be set **BEFORE** calling`startManager`!

 */

#import "PreSniffSDKNullability.h"
NS_ASSUME_NONNULL_BEGIN

@interface PreSniffManager: NSObject

#pragma mark - Public Methods

///-----------------------------------------------------------------------------
/// @name Initialization
///-----------------------------------------------------------------------------

/**
 Returns a shared PreSniffManager object
 
 @return A singleton PreSniffManager instance ready use
 */
+ (PreSniffManager *)sharedPreSniffManager;


/**
 Initializes the manager with a particular app identifier
 
 Initialize the manager with a HockeyApp app identifier.
 
    [[PreSniffManager sharedPreSniffManager]
      configureWithIdentifier:@"<AppIdentifierFromHockeyApp>"];
 
 @see configureWithIdentifier:delegate:
 @see configureWithBetaIdentifier:liveIdentifier:delegate:
 @see startManager
 @param appIdentifier The app identifier that should be used.
 */
- (void)configureWithIdentifier:(NSString *)appIdentifier;


/**
 Initializes the manager with a particular app identifier and delegate
 
 Initialize the manager with a HockeyApp app identifier and assign the class that
 implements the optional protocols `PreSniffManagerDelegate`, `PRESCrashManagerDelegate` or
 `BITUpdateManagerDelegate`.
 
    [[PreSniffManager sharedPreSniffManager]
      configureWithIdentifier:@"<AppIdentifierFromHockeyApp>"
                     delegate:nil];

 @see configureWithIdentifier:
 @see configureWithBetaIdentifier:liveIdentifier:delegate:
 @see startManager
 @see PreSniffManagerDelegate
 @see PRESCrashManagerDelegate
 @see BITUpdateManagerDelegate
 @see BITFeedbackManagerDelegate
 @param appIdentifier The app identifier that should be used.
 @param delegate `nil` or the class implementing the option protocols
 */
- (void)configureWithIdentifier:(NSString *)appIdentifier delegate:(nullable id<PreSniffManagerDelegate>)delegate;


/**
 Initializes the manager with an app identifier for beta, one for live usage and delegate
 
 Initialize the manager with different HockeyApp app identifiers for beta and live usage.
 All modules will automatically detect if the app is running in the App Store and use
 the live app identifier for that. In all other cases it will use the beta app identifier.
 And also assign the class that implements the optional protocols `PreSniffManagerDelegate`,
 `PRESCrashManagerDelegate` or `BITUpdateManagerDelegate`
 
    [[PreSniffManager sharedPreSniffManager]
      configureWithBetaIdentifier:@"<AppIdentifierForBetaAppFromHockeyApp>"
                   liveIdentifier:@"<AppIdentifierForLiveAppFromHockeyApp>"
                         delegate:nil];

 We recommend using one app entry on HockeyApp for your beta versions and another one for
 your live versions. The reason is that you will have way more beta versions than live
 versions, but on the other side get way more crash reports on the live version. Separating
 them into two different app entries makes it easier to work with the data. In addition
 you will likely end up having the same version number for a beta and live version which
 would mix different data into the same version. Also the live version does not require
 you to upload any IPA files, uploading only the dSYM package for crash reporting is
 just fine.

 @see configureWithIdentifier:
 @see configureWithIdentifier:delegate:
 @see startManager
 @see PreSniffManagerDelegate
 @see PRESCrashManagerDelegate
 @see BITUpdateManagerDelegate
 @see BITFeedbackManagerDelegate
 @param betaIdentifier The app identifier for the _non_ app store (beta) configurations
 @param liveIdentifier The app identifier for the app store configurations.
 @param delegate `nil` or the class implementing the optional protocols
 */
- (void)configureWithBetaIdentifier:(NSString *)betaIdentifier liveIdentifier:(NSString *)liveIdentifier delegate:(nullable id<PreSniffManagerDelegate>)delegate;


/**
 Starts the manager and runs all modules
 
 Call this after configuring the manager and setting up all modules.
 
 @see configureWithIdentifier:delegate:
 @see configureWithBetaIdentifier:liveIdentifier:delegate:
 */
- (void)startManager;


#pragma mark - Public Properties

///-----------------------------------------------------------------------------
/// @name Modules
///-----------------------------------------------------------------------------


/**
 Set the delegate
 
 Defines the class that implements the optional protocol `PreSniffManagerDelegate`.
 
 The delegate will automatically be propagated to all components. There is no need to set the delegate
 for each component individually.
 
 @warning This property needs to be set before calling `startManager`
 
 @see PreSniffManagerDelegate
 @see PRESCrashManagerDelegate
 @see BITUpdateManagerDelegate
 @see BITFeedbackManagerDelegate
 */
@property (nonatomic, weak, nullable) id<PreSniffManagerDelegate> delegate;


/**
 Defines the server URL to send data to or request data from
 
 By default this is set to the HockeyApp servers and there rarely should be a
 need to modify that.
 Please be aware that the URL for `BITMetricsManager` needs to be set separately
 as this class uses a different endpoint!
 
 @warning This property needs to be set before calling `startManager`
 */
@property (nonatomic, strong) NSString *serverURL;


#if HOCKEYSDK_FEATURE_CRASH_REPORTER

/**
 Reference to the initialized PRESCrashManager module

 Returns the PRESCrashManager instance initialized by PreSniffManager
 
 @see configureWithIdentifier:delegate:
 @see configureWithBetaIdentifier:liveIdentifier:delegate:
 @see startManager
 @see disableCrashManager
 */
@property (nonatomic, strong, readonly) PRESCrashManager *crashManager;


/**
 Flag the determines whether the Crash Manager should be disabled
 
 If this flag is enabled, then crash reporting is disabled and no crashes will
 be send.
 
 Please note that the Crash Manager instance will be initialized anyway, but crash report
 handling (signal and uncaught exception handlers) will **not** be registered.

 @warning This property needs to be set before calling `startManager`

 *Default*: _NO_
 @see crashManager
 */
@property (nonatomic, getter = isCrashManagerDisabled) BOOL disableCrashManager;

#endif


#if HOCKEYSDK_FEATURE_UPDATES

/**
 Reference to the initialized BITUpdateManager module
 
 Returns the BITUpdateManager instance initialized by PreSniffManager
 
 @see configureWithIdentifier:delegate:
 @see configureWithBetaIdentifier:liveIdentifier:delegate:
 @see startManager
 @see disableUpdateManager
 */
@property (nonatomic, strong, readonly) BITUpdateManager *updateManager;


/**
 Flag the determines whether the Update Manager should be disabled
 
 If this flag is enabled, then checking for updates and submitting beta usage
 analytics will be turned off!
 
 Please note that the Update Manager instance will be initialized anyway!
 
 @warning This property needs to be set before calling `startManager`

 *Default*: _NO_
 @see updateManager
 */
@property (nonatomic, getter = isUpdateManagerDisabled) BOOL disableUpdateManager;

#endif


#if HOCKEYSDK_FEATURE_STORE_UPDATES

/**
 Reference to the initialized BITStoreUpdateManager module
 
 Returns the BITStoreUpdateManager instance initialized by PreSniffManager
 
 @see configureWithIdentifier:delegate:
 @see configureWithBetaIdentifier:liveIdentifier:delegate:
 @see startManager
 @see enableStoreUpdateManager
 */
@property (nonatomic, strong, readonly) BITStoreUpdateManager *storeUpdateManager;


/**
 Flag the determines whether the App Store Update Manager should be enabled
 
 If this flag is enabled, then checking for updates when the app runs from the
 app store will be turned on!
 
 Please note that the Store Update Manager instance will be initialized anyway!

 @warning This property needs to be set before calling `startManager`

 *Default*: _NO_
 @see storeUpdateManager
 */
@property (nonatomic, getter = isStoreUpdateManagerEnabled) BOOL enableStoreUpdateManager;

#endif


#if HOCKEYSDK_FEATURE_FEEDBACK

/**
 Reference to the initialized BITFeedbackManager module
 
 Returns the BITFeedbackManager instance initialized by PreSniffManager
 
 @see configureWithIdentifier:delegate:
 @see configureWithBetaIdentifier:liveIdentifier:delegate:
 @see startManager
 @see disableFeedbackManager
 */
@property (nonatomic, strong, readonly) BITFeedbackManager *feedbackManager;


/**
 Flag the determines whether the Feedback Manager should be disabled
 
 If this flag is enabled, then letting the user give feedback and
 get responses will be turned off!
 
 Please note that the Feedback Manager instance will be initialized anyway!

 @warning This property needs to be set before calling `startManager`

 *Default*: _NO_
 @see feedbackManager
 */
@property (nonatomic, getter = isFeedbackManagerDisabled) BOOL disableFeedbackManager;

#endif


#if HOCKEYSDK_FEATURE_AUTHENTICATOR

/**
 Reference to the initialized BITAuthenticator module
 
 Returns the BITAuthenticator instance initialized by PreSniffManager
 
 @see configureWithIdentifier:delegate:
 @see configureWithBetaIdentifier:liveIdentifier:delegate:
 @see startManager
 */
@property (nonatomic, strong, readonly) BITAuthenticator *authenticator;

#endif

#if HOCKEYSDK_FEATURE_METRICS

/**
 Reference to the initialized BITMetricsManager module
 
 Returns the BITMetricsManager instance initialized by PreSniffManager
 */
@property (nonatomic, strong, readonly) PRESMetricsManager *metricsManager;

/**
 Flag the determines whether the BITMetricsManager should be disabled
 
 If this flag is enabled, then sending metrics data such as sessions and users 
 will be turned off!
 
 Please note that the BITMetricsManager instance will be initialized anyway!
  
 *Default*: _NO_
 @see metricsManager
 */
@property (nonatomic, getter = isMetricsManagerDisabled) BOOL disableMetricsManager;

/**
 Flag the determines whether the HttpMonitor should be disabled
 
 If this flag is enabled, then sending HttpMonitor data
 will be turned off!
 
 *Default*: _NO_
 */
@property (nonatomic, getter = isHttpMonitorDisabled) BOOL disableHttpMonitor;

#endif

///-----------------------------------------------------------------------------
/// @name Environment
///-----------------------------------------------------------------------------


/**
 Enum that indicates what kind of environment the application is installed and running in.
 
 This property can be used to disable or enable specific funtionality 
 only when specific conditions are met.
 That could mean for example, to only enable debug UI elements 
 when the app has been installed over HockeyApp but not in the AppStore.
 
 The underlying enum type at the moment only specifies values for the AppStore,
 TestFlight and Other. Other summarizes several different distribution methods
 and we might define additional specifc values for other environments in the future.
 
 @see BITEnvironment
 */
@property (nonatomic, readonly) BITEnvironment appEnvironment;


/**
 Returns the app installation specific anonymous UUID
 
 The value returned by this method is unique and persisted per app installation
 in the keychain.  It is also being used in crash reports as `CrashReporter Key`
 and internally when sending crash reports and feedback messages.
 
 This is not identical to the `[ASIdentifierManager advertisingIdentifier]` or
 the `[UIDevice identifierForVendor]`!
 */
@property (nonatomic, readonly) NSString *installString;


/**
 Disable tracking the installation of an app on a device
 
 This will cause the app to generate a new `installString` value every time the
 app is cold started.
 
 This property is only considered in App Store Environment, since it would otherwise
 affect the `BITUpdateManager` and `BITAuthenticator` functionalities!
 
 @warning This property needs to be set before calling `startManager`
 
 *Default*: _NO_
 */
@property (nonatomic, getter=isInstallTrackingDisabled) BOOL disableInstallTracking;

///-----------------------------------------------------------------------------
/// @name Debug Logging
///-----------------------------------------------------------------------------

/**
 This property is used indicate the amount of verboseness and severity for which
 you want to see log messages in the console.
 */
@property (nonatomic, assign) BITLogLevel logLevel;

/**
 Flag that determines whether additional logging output should be generated
 by the manager and all modules.
 
 This is ignored if the app is running in the App Store and reverts to the
 default value in that case.
 
 @warning This property needs to be set before calling `startManager`
 
 *Default*: _NO_
 */
@property (nonatomic, assign, getter=isDebugLogEnabled) BOOL debugLogEnabled DEPRECATED_MSG_ATTRIBUTE("Use logLevel instead!");

/**
 Set a custom block that handles all the log messages that are emitted from the SDK.

 You can use this to reroute the messages that would normally be logged by `NSLog();`
 to your own custom logging framework.

 An example of how to do this with NSLogger:
 
 ```
 [[PreSniffManager sharedPreSniffManager] setLogHandler:^(BITLogMessageProvider messageProvider, BITLogLevel logLevel, const char *file, const char *function, uint line) {
    LogMessageRawF(file, (int)line, function, @"HockeySDK", (int)logLevel-1, messageProvider());
 }];
 ```

 or with CocoaLumberjack:
 
 ```
 [[PreSniffManager sharedPreSniffManager] setLogHandler:^(BITLogMessageProvider messageProvider, BITLogLevel logLevel, const char *file, const char *function, uint line) {
    [DDLog log:YES message:messageProvider() level:ddLogLevel flag:(DDLogFlag)(1 << (logLevel-1)) context:<#CocoaLumberjackContext#> file:file function:function line:line tag:nil];
 }];
 ```
 
 @param logHandler The block of type BITLogHandler that will process all logged messages.
 */
- (void)setLogHandler:(BITLogHandler)logHandler;


///-----------------------------------------------------------------------------
/// @name Integration test
///-----------------------------------------------------------------------------

/**
 Pings the server with the HockeyApp app identifiers used for initialization
 
 Call this method once for debugging purposes to test if your SDK setup code
 reaches the server successfully.
 
 Once invoked, check the apps page on HockeyApp for a verification.
 
 If you setup the SDK with a beta and live identifier, a call to both app IDs will be done.

 This call is ignored if the app is running in the App Store!.
 */
- (void)testIdentifier;


///-----------------------------------------------------------------------------
/// @name Additional meta data
///-----------------------------------------------------------------------------

/** Set the userid that should used in the SDK components
 
 Right now this is used by the `PRESCrashManager` to attach to a crash report.
 `BITFeedbackManager` uses it too for assigning the user to a discussion thread.

 The value can be set at any time and will be stored in the keychain on the current
 device only! To delete the value from the keychain set the value to `nil`.
 
 This property is optional and can be used as an alternative to the delegate. If you
 want to define specific data for each component, use the delegate instead which does
 overwrite the values set by this property.
 
 @warning When returning a non nil value, crash reports are not anonymous any more
 and the crash alerts will not show the word "anonymous"!
 
 @warning This property needs to be set before calling `startManager` to be considered
 for being added to crash reports as meta data.

 @see userName
 @see userEmail
 @see `[PreSniffManagerDelegate userIDForHockeyManager:componentManager:]`
 */
@property (nonatomic, copy, nullable) NSString *userID;


/** Set the user name that should used in the SDK components
 
 Right now this is used by the `PRESCrashManager` to attach to a crash report.
 `BITFeedbackManager` uses it too for assigning the user to a discussion thread.
 
 The value can be set at any time and will be stored in the keychain on the current
 device only! To delete the value from the keychain set the value to `nil`.
 
 This property is optional and can be used as an alternative to the delegate. If you
 want to define specific data for each component, use the delegate instead which does
 overwrite the values set by this property.

 @warning When returning a non nil value, crash reports are not anonymous any more
 and the crash alerts will not show the word "anonymous"!

 @warning This property needs to be set before calling `startManager` to be considered
 for being added to crash reports as meta data.

 @see userID
 @see userEmail
 @see `[PreSniffManagerDelegate userNameForHockeyManager:componentManager:]`
 */
@property (nonatomic, copy, nullable) NSString *userName;


/** Set the users email address that should used in the SDK components
 
 Right now this is used by the `PRESCrashManager` to attach to a crash report.
 `BITFeedbackManager` uses it too for assigning the user to a discussion thread.
 
 The value can be set at any time and will be stored in the keychain on the current
 device only! To delete the value from the keychain set the value to `nil`.
 
 This property is optional and can be used as an alternative to the delegate. If you
 want to define specific data for each component, use the delegate instead which does
 overwrite the values set by this property.
 
 @warning When returning a non nil value, crash reports are not anonymous any more
 and the crash alerts will not show the word "anonymous"!
 
 @warning This property needs to be set before calling `startManager` to be considered
 for being added to crash reports as meta data.

 @see userID
 @see userName
 @see [PreSniffManagerDelegate userEmailForHockeyManager:componentManager:]
 */
@property (nonatomic, copy, nullable) NSString *userEmail;


///-----------------------------------------------------------------------------
/// @name SDK meta data
///-----------------------------------------------------------------------------

/**
 Returns the SDK Version (CFBundleShortVersionString).
 */
- (NSString *)version;

/**
 Returns the SDK Build (CFBundleVersion) as a string.
 */
- (NSString *)build;

@end

NS_ASSUME_NONNULL_END
