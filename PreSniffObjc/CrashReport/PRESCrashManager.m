/*
 * Author: Andreas Linde <mail@andreaslinde.de>
 *         Kent Sutherland
 *
 * Copyright (c) 2012-2014 HockeyApp, Bit Stadium GmbH.
 * Copyright (c) 2011 Andreas Linde & Kent Sutherland.
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

#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>

#import "PRESPrivate.h"
#import "PRESHelper.h"
#import "PRESNetworkClient.h"

#import "PRESCrashManager.h"
#import "PRESCrashManagerPrivate.h"
#import "PRESBaseManagerPrivate.h"
#import "PRESCrashReportTextFormatter.h"
#import "PRESCrashDetailsPrivate.h"
#import "PRESCrashCXXExceptionHandler.h"
#import "PRESVersion.h"
#import "PRESMetricsManagerPrivate.h"
#import "PRESChannel.h"
#import "PRESPersistencePrivate.h"
#include <sys/sysctl.h>

// stores the set of crashreports that have been approved but aren't sent yet
#define kPRESCrashApprovedReports @"PreSniffObjcCrashApprovedReports"

// keys for meta information associated to each crash
#define kPRESCrashMetaUserName @"PRESCrashMetaUserName"
#define kPRESCrashMetaUserEmail @"PRESCrashMetaUserEmail"
#define kPRESCrashMetaUserID @"PRESCrashMetaUserID"
#define kPRESCrashMetaApplicationLog @"PRESCrashMetaApplicationLog"
#define kPRESCrashMetaAttachment @"PRESCrashMetaAttachment"

// internal keys
static NSString *const KPRESAttachmentDictIndex = @"index";
static NSString *const KPRESAttachmentDictAttachment = @"attachment";

static NSString *const kPRESCrashManagerStatus = @"PRESCrashManagerStatus";

static NSString *const kPRESAppWentIntoBackgroundSafely = @"PRESAppWentIntoBackgroundSafely";
static NSString *const kPRESAppDidReceiveLowMemoryNotification = @"PRESAppDidReceiveLowMemoryNotification";
static NSString *const kPRESAppMarketingVersion = @"PRESAppMarketingVersion";
static NSString *const kPRESAppVersion = @"PRESAppVersion";
static NSString *const kPRESAppOSVersion = @"PRESAppOSVersion";
static NSString *const kPRESAppOSBuild = @"PRESAppOSBuild";
static NSString *const kPRESAppUUIDs = @"PRESAppUUIDs";

static NSString *const kPRESFakeCrashUUID = @"PRESFakeCrashUUID";
static NSString *const kPRESFakeCrashAppMarketingVersion = @"PRESFakeCrashAppMarketingVersion";
static NSString *const kPRESFakeCrashAppVersion = @"PRESFakeCrashAppVersion";
static NSString *const kPRESFakeCrashAppBundleIdentifier = @"PRESFakeCrashAppBundleIdentifier";
static NSString *const kPRESFakeCrashOSVersion = @"PRESFakeCrashOSVersion";
static NSString *const kPRESFakeCrashDeviceModel = @"PRESFakeCrashDeviceModel";
static NSString *const kPRESFakeCrashAppBinaryUUID = @"PRESFakeCrashAppBinaryUUID";
static NSString *const kPRESFakeCrashReport = @"PRESFakeCrashAppString";
static char const *PRESSaveEventsFilePath;

static PRESCrashManagerCallbacks bitCrashCallbacks = {
    .context = NULL,
    .handleSignal = NULL
};

static void pres_save_events_callback(siginfo_t *info, ucontext_t *uap, void *context) {
    
    // Do not flush metrics queue if queue is empty (metrics module disabled) to not freeze the app
    if (!PRESSafeJsonEventsString) {
        return;
    }
    
    // Try to get a file descriptor with our pre-filled path
    int fd = open(PRESSaveEventsFilePath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        return;
    }
    
    size_t len = strlen(PRESSafeJsonEventsString);
    if (len > 0) {
        // Simply write the whole string to disk
        write(fd, PRESSafeJsonEventsString, len);
    }
    close(fd);
}

// Proxy implementation for PLCrashReporter to keep our interface stable while this can change
static void plcr_post_crash_callback (siginfo_t *info, ucontext_t *uap, void *context) {
    pres_save_events_callback(info, uap, context);
    if (bitCrashCallbacks.handleSignal != NULL) {
        bitCrashCallbacks.handleSignal(context);
    }
}

static PLCrashReporterCallbacks plCrashCallbacks = {
    .version = 0,
    .context = NULL,
    .handleSignal = plcr_post_crash_callback
};

// Temporary class until PLCR catches up
// We trick PLCR with an Objective-C exception.
//
// This code provides us access to the C++ exception message, including a correct stack trace.
//
@interface PRESCrashCXXExceptionWrapperException : NSException
- (instancetype)initWithCXXExceptionInfo:(const PRESCrashUncaughtCXXExceptionInfo *)info;
@end

@implementation PRESCrashCXXExceptionWrapperException {
    const PRESCrashUncaughtCXXExceptionInfo *_info;
}

- (instancetype)initWithCXXExceptionInfo:(const PRESCrashUncaughtCXXExceptionInfo *)info {
    extern char* __cxa_demangle(const char* mangled_name, char* output_buffer, size_t* length, int* status);
    char *demangled_name = &__cxa_demangle ? __cxa_demangle(info->exception_type_name ?: "", NULL, NULL, NULL) : NULL;
    
    if ((self = [super
                 initWithName:[NSString stringWithUTF8String:demangled_name ?: info->exception_type_name ?: ""]
                 reason:[NSString stringWithUTF8String:info->exception_message ?: ""]
                 userInfo:nil])) {
        _info = info;
    }
    return self;
}

- (NSArray *)callStackReturnAddresses {
    NSMutableArray *cxxFrames = [NSMutableArray arrayWithCapacity:_info->exception_frames_count];
    
    for (uint32_t i = 0; i < _info->exception_frames_count; ++i) {
        [cxxFrames addObject:[NSNumber numberWithUnsignedLongLong:_info->exception_frames[i]]];
    }
    return cxxFrames;
}

@end


// C++ Exception Handler
static void uncaught_cxx_exception_handler(const PRESCrashUncaughtCXXExceptionInfo *info) {
    // This relies on a LOT of sneaky internal knowledge of how PLCR works and should not be considered a long-term solution.
    NSGetUncaughtExceptionHandler()([[PRESCrashCXXExceptionWrapperException alloc] initWithCXXExceptionInfo:info]);
    abort();
}


@implementation PRESCrashManager {
    NSMutableDictionary *_approvedCrashReports;
    
    NSMutableArray *_crashFiles;
    NSString       *_lastCrashFilename;
    NSString       *_settingsFile;
    NSString       *_analyzerInProgressFile;
    NSFileManager  *_fileManager;
    
    BOOL _crashIdenticalCurrentVersion;
    
    BOOL _sendingInProgress;
    BOOL _isSetup;
    
    BOOL _didLogLowMemoryWarning;
    
    id _appDidBecomeActiveObserver;
    id _appWillTerminateObserver;
    id _appDidEnterBackgroundObserver;
    id _appWillEnterForegroundObserver;
    id _appDidReceiveLowMemoryWarningObserver;
    id _networkDidBecomeReachableObserver;
}

- (instancetype)initWithAppIdentifier:(NSString *)appIdentifier appEnvironment:(PRESEnvironment)environment hockeyAppClient:(PRESNetworkClient *)hockeyAppClient {
    if ((self = [super initWithAppIdentifier:appIdentifier appEnvironment:environment])) {
        _delegate = nil;
        _isSetup = NO;
        
        _hockeyAppClient = hockeyAppClient;
        
        _showAlwaysButton = YES;
        _alertViewHandler = nil;
        
        _plCrashReporter = nil;
        _exceptionHandler = nil;
        
        _crashIdenticalCurrentVersion = YES;
        
        _didCrashInLastSession = NO;
        _timeIntervalCrashInLastSessionOccurred = -1;
        _didLogLowMemoryWarning = NO;
        
        _approvedCrashReports = [[NSMutableDictionary alloc] init];
        
        _fileManager = [[NSFileManager alloc] init];
        _crashFiles = [[NSMutableArray alloc] init];
        
        _crashManagerStatus = PRESCrashManagerStatusAutoSend;
        
        if ([[NSUserDefaults standardUserDefaults] stringForKey:kPRESCrashManagerStatus]) {
            _crashManagerStatus = (PRESCrashManagerStatus)[[NSUserDefaults standardUserDefaults] integerForKey:kPRESCrashManagerStatus];
        } else {
            // migrate previous setting if available
            if ([[NSUserDefaults standardUserDefaults] boolForKey:@"PRESCrashAutomaticallySendReports"]) {
                _crashManagerStatus = PRESCrashManagerStatusAutoSend;
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"PRESCrashAutomaticallySendReports"];
            }
            [[NSUserDefaults standardUserDefaults] setInteger:_crashManagerStatus forKey:kPRESCrashManagerStatus];
        }
        
        _crashesDir = pres_settingsDir();
        _settingsFile = [_crashesDir stringByAppendingPathComponent:PRES_CRASH_SETTINGS];
        _analyzerInProgressFile = [_crashesDir stringByAppendingPathComponent:PRES_CRASH_ANALYZER];
        
        
        if (!PRESBundle() && !pres_isRunningInAppExtension()) {
            PRESLogWarning(@"[PreSniffObjc] WARNING: %@ is missing, will send reports automatically!", PRES_BUNDLE);
        }
    }
    return self;
}


- (void) dealloc {
    [self unregisterObservers];
}


- (void)setCrashManagerStatus:(PRESCrashManagerStatus)crashManagerStatus {
    _crashManagerStatus = crashManagerStatus;
    
    [[NSUserDefaults standardUserDefaults] setInteger:crashManagerStatus forKey:kPRESCrashManagerStatus];
}

- (void)setServerURL:(NSString *)serverURL {
    if ([serverURL isEqualToString:super.serverURL]) { return; }
    
    super.serverURL = serverURL;
    self.hockeyAppClient = [[PRESNetworkClient alloc] initWithBaseURL:[NSURL URLWithString:serverURL]];
}

#pragma mark - Private

/**
 * Save all settings
 *
 * This saves the list of approved crash reports
 */
- (void)saveSettings {
    NSError *error = nil;
    
    NSMutableDictionary *rootObj = [NSMutableDictionary dictionaryWithCapacity:2];
    if (_approvedCrashReports && [_approvedCrashReports count] > 0) {
        [rootObj setObject:_approvedCrashReports forKey:kPRESCrashApprovedReports];
    }
    
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:(id)rootObj format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    
    if (plist) {
        [plist writeToFile:_settingsFile atomically:YES];
    } else {
        PRESLogError(@"ERROR: Writing settings. %@", [error description]);
    }
}

/**
 * Load all settings
 *
 * This contains the list of approved crash reports
 */
- (void)loadSettings {
    NSError *error = nil;
    NSPropertyListFormat format;
    
    if (![_fileManager fileExistsAtPath:_settingsFile])
        return;
    
    NSData *plist = [NSData dataWithContentsOfFile:_settingsFile];
    if (plist) {
        NSDictionary *rootObj = (NSDictionary *)[NSPropertyListSerialization
                                                 propertyListWithData:plist
                                                 options:NSPropertyListMutableContainersAndLeaves
                                                 format:&format
                                                 error:&error];
        
        if ([rootObj objectForKey:kPRESCrashApprovedReports])
            [_approvedCrashReports setDictionary:[rootObj objectForKey:kPRESCrashApprovedReports]];
    } else {
        PRESLogError(@"ERROR: Reading crash manager settings.");
    }
}


/**
 * Remove a cached crash report
 *
 *  @param filename The base filename of the crash report
 */
- (void)cleanCrashReportWithFilename:(NSString *)filename {
    if (!filename) return;
    
    NSError *error = NULL;
    
    [_fileManager removeItemAtPath:filename error:&error];
    [_fileManager removeItemAtPath:[filename stringByAppendingString:@".data"] error:&error];
    [_fileManager removeItemAtPath:[filename stringByAppendingString:@".meta"] error:&error];
    [_fileManager removeItemAtPath:[filename stringByAppendingString:@".desc"] error:&error];
    
    NSString *cacheFilename = [filename lastPathComponent];
    [self removeKeyFromKeychain:[NSString stringWithFormat:@"%@.%@", cacheFilename, kPRESCrashMetaUserName]];
    [self removeKeyFromKeychain:[NSString stringWithFormat:@"%@.%@", cacheFilename, kPRESCrashMetaUserEmail]];
    [self removeKeyFromKeychain:[NSString stringWithFormat:@"%@.%@", cacheFilename, kPRESCrashMetaUserID]];
    
    [_crashFiles removeObject:filename];
    [_approvedCrashReports removeObjectForKey:filename];
    
    [self saveSettings];
}

/**
 *	 Remove all crash reports and stored meta data for each from the file system and keychain
 *
 * This is currently only used as a helper method for tests
 */
- (void)cleanCrashReports {
    for (NSUInteger i=0; i < [_crashFiles count]; i++) {
        [self cleanCrashReportWithFilename:[_crashFiles objectAtIndex:i]];
    }
}

- (BOOL)persistAttachment:(PRESAttachment *)attachment withFilename:(NSString *)filename {
    NSString *attachmentFilename = [filename stringByAppendingString:@".data"];
    NSMutableData *data = [[NSMutableData alloc] init];
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
    
    [archiver encodeObject:attachment forKey:kPRESCrashMetaAttachment];
    
    [archiver finishEncoding];
    
    return [data writeToFile:attachmentFilename atomically:YES];
}

- (void)persistUserProvidedMetaData:(PRESCrashMetaData *)userProvidedMetaData {
    if (!userProvidedMetaData) return;
    
    if (userProvidedMetaData.userProvidedDescription && [userProvidedMetaData.userProvidedDescription length] > 0) {
        NSError *error;
        [userProvidedMetaData.userProvidedDescription writeToFile:[NSString stringWithFormat:@"%@.desc", [_crashesDir stringByAppendingPathComponent: _lastCrashFilename]] atomically:YES encoding:NSUTF8StringEncoding error:&error];
    }
    
    if (userProvidedMetaData.userName && [userProvidedMetaData.userName length] > 0) {
        [self addStringValueToKeychain:userProvidedMetaData.userName forKey:[NSString stringWithFormat:@"%@.%@", _lastCrashFilename, kPRESCrashMetaUserName]];
        
    }
    
    if (userProvidedMetaData.userEmail && [userProvidedMetaData.userEmail length] > 0) {
        [self addStringValueToKeychain:userProvidedMetaData.userEmail forKey:[NSString stringWithFormat:@"%@.%@", _lastCrashFilename, kPRESCrashMetaUserEmail]];
    }
    
    if (userProvidedMetaData.userID && [userProvidedMetaData.userID length] > 0) {
        [self addStringValueToKeychain:userProvidedMetaData.userID forKey:[NSString stringWithFormat:@"%@.%@", _lastCrashFilename, kPRESCrashMetaUserID]];
        
    }
}

/**
 *  Read the attachment data from the stored file
 *
 *  @param filename The crash report file path
 *
 *  @return an PRESAttachment instance or nil
 */
- (PRESAttachment *)attachmentForCrashReport:(NSString *)filename {
    NSString *attachmentFilename = [filename stringByAppendingString:@".data"];
    
    if (![_fileManager fileExistsAtPath:attachmentFilename])
        return nil;
    
    
    NSData *codedData = [[NSData alloc] initWithContentsOfFile:attachmentFilename];
    if (!codedData)
        return nil;
    
    NSKeyedUnarchiver *unarchiver = nil;
    
    @try {
        unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:codedData];
    }
    @catch (NSException *exception) {
        return nil;
    }
    
    if ([unarchiver containsValueForKey:kPRESCrashMetaAttachment]) {
        PRESAttachment *attachment = [unarchiver decodeObjectForKey:kPRESCrashMetaAttachment];
        return attachment;
    }
    
    return nil;
}

/**
 *	 Extract all app specific UUIDs from the crash reports
 *
 * This allows us to send the UUIDs in the XML construct to the server, so the server does not need to parse the crash report for this data.
 * The app specific UUIDs help to identify which dSYMs are needed to symbolicate this crash report.
 *
 *	@param	report The crash report from PLCrashReporter
 *
 *	@return XML structure with the app specific UUIDs
 */
- (NSString *) extractAppUUIDs:(BITPLCrashReport *)report {
    NSMutableString *uuidString = [NSMutableString string];
    NSArray *uuidArray = [PRESCrashReportTextFormatter arrayOfAppUUIDsForCrashReport:report];
    
    for (NSDictionary *element in uuidArray) {
        if ([element objectForKey:kPRESBinaryImageKeyType] && [element objectForKey:kPRESBinaryImageKeyArch] && [element objectForKey:kPRESBinaryImageKeyUUID]) {
            [uuidString appendFormat:@"<uuid type=\"%@\" arch=\"%@\">%@</uuid>",
             [element objectForKey:kPRESBinaryImageKeyType],
             [element objectForKey:kPRESBinaryImageKeyArch],
             [element objectForKey:kPRESBinaryImageKeyUUID]
             ];
        }
    }
    
    return uuidString;
}

- (void) registerObservers {
    __weak typeof(self) weakSelf = self;
    
    if(nil == _appDidBecomeActiveObserver) {
        _appDidBecomeActiveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                                        object:nil
                                                                                         queue:NSOperationQueue.mainQueue
                                                                                    usingBlock:^(NSNotification *note) {
                                                                                        typeof(self) strongSelf = weakSelf;
                                                                                        [strongSelf triggerDelayedProcessing];
                                                                                    }];
    }
    
    if(nil == _networkDidBecomeReachableObserver) {
        _networkDidBecomeReachableObserver = [[NSNotificationCenter defaultCenter] addObserverForName:PRESNetworkDidBecomeReachableNotification
                                                                                               object:nil
                                                                                                queue:NSOperationQueue.mainQueue
                                                                                           usingBlock:^(NSNotification *note) {
                                                                                               typeof(self) strongSelf = weakSelf;
                                                                                               [strongSelf triggerDelayedProcessing];
                                                                                           }];
    }
    
    if (nil ==  _appWillTerminateObserver) {
        _appWillTerminateObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                                                      object:nil
                                                                                       queue:NSOperationQueue.mainQueue
                                                                                  usingBlock:^(NSNotification *note) {
                                                                                      typeof(self) strongSelf = weakSelf;
                                                                                      [strongSelf leavingAppSafely];
                                                                                  }];
    }
    
    if (nil ==  _appDidEnterBackgroundObserver) {
        _appDidEnterBackgroundObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                                                           object:nil
                                                                                            queue:NSOperationQueue.mainQueue
                                                                                       usingBlock:^(NSNotification *note) {
                                                                                           typeof(self) strongSelf = weakSelf;
                                                                                           [strongSelf leavingAppSafely];
                                                                                       }];
    }
    
    if (nil == _appWillEnterForegroundObserver) {
        _appWillEnterForegroundObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                                                            object:nil
                                                                                             queue:NSOperationQueue.mainQueue
                                                                                        usingBlock:^(NSNotification *note) {
                                                                                            typeof(self) strongSelf = weakSelf;
                                                                                            [strongSelf appEnteredForeground];
                                                                                        }];
    }
    
    if (nil == _appDidReceiveLowMemoryWarningObserver) {
        _appDidReceiveLowMemoryWarningObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                                                                   object:nil
                                                                                                    queue:NSOperationQueue.mainQueue
                                                                                               usingBlock:^(NSNotification *note) {
                                                                                                   // we only need to log this once
                                                                                                   if (!_didLogLowMemoryWarning) {
                                                                                                       [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kPRESAppDidReceiveLowMemoryNotification];
                                                                                                       _didLogLowMemoryWarning = YES;
                                                                                                       if(pres_isPreiOS8Environment()) {
                                                                                                           // calling synchronize in pre-iOS 8 takes longer to sync than in iOS 8+, calling synchronize explicitly.
                                                                                                           [[NSUserDefaults standardUserDefaults] synchronize];
                                                                                                       }
                                                                                                   }
                                                                                               }];
    }
}

- (void) unregisterObservers {
    [self unregisterObserver:_appDidBecomeActiveObserver];
    [self unregisterObserver:_appWillTerminateObserver];
    [self unregisterObserver:_appDidEnterBackgroundObserver];
    [self unregisterObserver:_appWillEnterForegroundObserver];
    [self unregisterObserver:_appDidReceiveLowMemoryWarningObserver];
    
    [self unregisterObserver:_networkDidBecomeReachableObserver];
}

- (void) unregisterObserver:(id)observer {
    if (observer) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        observer = nil;
    }
}

- (void)leavingAppSafely {
    if (self.isAppNotTerminatingCleanlyDetectionEnabled) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kPRESAppWentIntoBackgroundSafely];
        if(pres_isPreiOS8Environment()) {
            // calling synchronize in pre-iOS 8 takes longer to sync than in iOS 8+, calling synchronize explicitly.
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
    }
}

- (void)appEnteredForeground {
    // we disable kill detection while the debugger is running, since we'd get only false positives if the app is terminated by the user using the debugger
    if (self.isDebuggerAttached) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kPRESAppWentIntoBackgroundSafely];
    } else if (self.isAppNotTerminatingCleanlyDetectionEnabled) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kPRESAppWentIntoBackgroundSafely];
        
        static dispatch_once_t predAppData;
        
        dispatch_once(&predAppData, ^{
            id marketingVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
            if (marketingVersion && [marketingVersion isKindOfClass:[NSString class]])
                [[NSUserDefaults standardUserDefaults] setObject:marketingVersion forKey:kPRESAppMarketingVersion];
            
            id bundleVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
            if (bundleVersion && [bundleVersion isKindOfClass:[NSString class]])
                [[NSUserDefaults standardUserDefaults] setObject:bundleVersion forKey:kPRESAppVersion];
            
            [[NSUserDefaults standardUserDefaults] setObject:[[UIDevice currentDevice] systemVersion] forKey:kPRESAppOSVersion];
            [[NSUserDefaults standardUserDefaults] setObject:[self osBuild] forKey:kPRESAppOSBuild];
            
            NSString *uuidString =[NSString stringWithFormat:@"<uuid type=\"app\" arch=\"%@\">%@</uuid>",
                                   [self deviceArchitecture],
                                   [self executableUUID]
                                   ];
            
            [[NSUserDefaults standardUserDefaults] setObject:uuidString forKey:kPRESAppUUIDs];
            if(pres_isPreiOS8Environment()) {
                // calling synchronize in pre-iOS 8 takes longer to sync than in iOS 8+, calling synchronize explicitly.
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
        });
    }
}

- (NSString *)deviceArchitecture {
    NSString *archName = @"???";
    
    size_t size;
    cpu_type_t type;
    cpu_subtype_t subtype;
    size = sizeof(type);
    if (sysctlbyname("hw.cputype", &type, &size, NULL, 0))
        return archName;
    
    size = sizeof(subtype);
    if (sysctlbyname("hw.cpusubtype", &subtype, &size, NULL, 0))
        return archName;
    
    archName = [PRESCrashReportTextFormatter pres_archNameFromCPUType:type subType:subtype] ?: @"???";
    
    return archName;
}

- (NSString *)osBuild {
    size_t size;
    sysctlbyname("kern.osversion", NULL, &size, NULL, 0);
    char *answer = (char*)malloc(size);
    if (answer == NULL)
        return nil;
    sysctlbyname("kern.osversion", answer, &size, NULL, 0);
    NSString *osBuild = [NSString stringWithCString:answer encoding: NSUTF8StringEncoding];
    free(answer);
    return osBuild;
}

/**
 *	 Get the userID from the delegate which should be stored with the crash report
 *
 *	@return The userID value
 */
- (NSString *)userIDForCrashReport {
    NSString *userID;
    
    // first check the global keychain storage
    NSString *userIdFromKeychain = [self stringValueFromKeychainForKey:kPRESMetaUserID];
    if (userIdFromKeychain) {
        userID = userIdFromKeychain;
    }
    
    if ([[PRESManager sharedPRESManager].delegate respondsToSelector:@selector(userIDForPRESManager:componentManager:)]) {
        userID = [[PRESManager sharedPRESManager].delegate
                  userIDForPRESManager:[PRESManager sharedPRESManager]
                  componentManager:self];
    }
    
    return userID  ?: @"";
}

/**
 *	 Get the userName from the delegate which should be stored with the crash report
 *
 *	@return The userName value
 */
- (NSString *)userNameForCrashReport {
    // first check the global keychain storage
    NSString *username = [self stringValueFromKeychainForKey:kPRESMetaUserName] ?: @"";
    
    if ([[PRESManager sharedPRESManager].delegate respondsToSelector:@selector(userNameForPRESManager:componentManager:)]) {
        username = [[PRESManager sharedPRESManager].delegate
                    userNameForPRESManager:[PRESManager sharedPRESManager]
                    componentManager:self] ?: @"";
    }
    
    return username;
}

/**
 *	 Get the userEmail from the delegate which should be stored with the crash report
 *
 *	@return The userEmail value
 */
- (NSString *)userEmailForCrashReport {
    // first check the global keychain storage
    NSString *useremail = [self stringValueFromKeychainForKey:kPRESMetaUserEmail] ?: @"";
    
    if ([[PRESManager sharedPRESManager].delegate respondsToSelector:@selector(userEmailForPRESManager:componentManager:)]) {
        useremail = [[PRESManager sharedPRESManager].delegate
                     userEmailForPRESManager:[PRESManager sharedPRESManager]
                     componentManager:self] ?: @"";
    }
    
    return useremail;
}

#pragma mark - CrashCallbacks

/**
 *  Set the callback for PLCrashReporter
 *
 *  @param callbacks PRESCrashManagerCallbacks instance
 */
- (void)setCrashCallbacks:(PRESCrashManagerCallbacks *)callbacks {
    if (!callbacks) return;
    if (_isSetup) {
        PRESLogWarning(@"WARNING: CrashCallbacks need to be configured before calling startManager!");
    }
    
    // set our proxy callback struct
    bitCrashCallbacks.context = callbacks->context;
    bitCrashCallbacks.handleSignal = callbacks->handleSignal;
    
    // set the PLCrashReporterCallbacks struct
    plCrashCallbacks.context = callbacks->context;
}

- (void)configDefaultCrashCallback {
    PRESMetricsManager *metricsManager = [PRESManager sharedPRESManager].metricsManager;
    PRESPersistence *persistence = metricsManager.persistence;
    PRESSaveEventsFilePath = strdup([persistence fileURLForType:PRESPersistenceTypeTelemetry].UTF8String);
}

#pragma mark - Public

- (void)setAlertViewHandler:(PRESCustomAlertViewHandler)alertViewHandler{
    _alertViewHandler = alertViewHandler;
}


- (BOOL)isDebuggerAttached {
    return pres_isDebuggerAttached();
}


- (void)generateTestCrash {
    if (self.appEnvironment != PRESEnvironmentAppStore) {
        
        if ([self isDebuggerAttached]) {
            PRESLogWarning(@"[PreSniffObjc] WARNING: The debugger is attached. The following crash cannot be detected by the SDK!");
        }
        
        __builtin_trap();
    }
}

/**
 *  Write a meta file for a new crash report
 *
 *  @param filename the crash reports temp filename
 */
- (void)storeMetaDataForCrashReportFilename:(NSString *)filename {
    PRESLogVerbose(@"VERBOSE: Storing meta data for crash report with filename %@", filename);
    NSError *error = NULL;
    NSMutableDictionary *metaDict = [NSMutableDictionary dictionaryWithCapacity:4];
    NSString *applicationLog = @"";
    
    [self addStringValueToKeychain:[self userNameForCrashReport] forKey:[NSString stringWithFormat:@"%@.%@", filename, kPRESCrashMetaUserName]];
    [self addStringValueToKeychain:[self userEmailForCrashReport] forKey:[NSString stringWithFormat:@"%@.%@", filename, kPRESCrashMetaUserEmail]];
    [self addStringValueToKeychain:[self userIDForCrashReport] forKey:[NSString stringWithFormat:@"%@.%@", filename, kPRESCrashMetaUserID]];
    
    if ([self.delegate respondsToSelector:@selector(applicationLogForCrashManager:)]) {
        applicationLog = [self.delegate applicationLogForCrashManager:self] ?: @"";
    }
    [metaDict setObject:applicationLog forKey:kPRESCrashMetaApplicationLog];
    
    if ([self.delegate respondsToSelector:@selector(attachmentForCrashManager:)]) {
        PRESLogVerbose(@"VERBOSE: Processing attachment for crash report with filename %@", filename);
        PRESAttachment *attachment = [self.delegate attachmentForCrashManager:self];
        
        if (attachment && attachment.hockeyAttachmentData) {
            BOOL success = [self persistAttachment:attachment withFilename:[_crashesDir stringByAppendingPathComponent: filename]];
            if (!success) {
                PRESLogError(@"ERROR: Persisting the crash attachment failed");
            } else {
                PRESLogVerbose(@"VERBOSE: Crash attachment successfully persisted.");
            }
        } else {
            PRESLogDebug(@"INFO: Crash attachment was nil");
        }
    }
    
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:(id)metaDict
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&error];
    if (plist) {
        BOOL success = [plist writeToFile:[_crashesDir stringByAppendingPathComponent: [filename stringByAppendingPathExtension:@"meta"]] atomically:YES];
        if (!success) {
            PRESLogError(@"ERROR: Writing crash meta data failed.");
        }
    } else {
        PRESLogError(@"ERROR: Writing crash meta data failed. %@", error);
    }
    PRESLogVerbose(@"VERBOSE: Storing crash meta data finished.");
}

- (BOOL)handleUserInput:(PRESCrashManagerUserInput)userInput withUserProvidedMetaData:(PRESCrashMetaData *)userProvidedMetaData {
    switch (userInput) {
        case PRESCrashManagerUserInputDontSend:
            if ([self.delegate respondsToSelector:@selector(crashManagerWillCancelSendingCrashReport:)]) {
                [self.delegate crashManagerWillCancelSendingCrashReport:self];
            }
            
            if (_lastCrashFilename)
                [self cleanCrashReportWithFilename:[_crashesDir stringByAppendingPathComponent: _lastCrashFilename]];
            
            return YES;
            
        case PRESCrashManagerUserInputSend:
            if (userProvidedMetaData)
                [self persistUserProvidedMetaData:userProvidedMetaData];
            
            [self approveLatestCrashReport];
            [self sendNextCrashReport];
            return YES;
            
        case PRESCrashManagerUserInputAlwaysSend:
            _crashManagerStatus = PRESCrashManagerStatusAutoSend;
            [[NSUserDefaults standardUserDefaults] setInteger:_crashManagerStatus forKey:kPRESCrashManagerStatus];
            
            if ([self.delegate respondsToSelector:@selector(crashManagerWillSendCrashReportsAlways:)]) {
                [self.delegate crashManagerWillSendCrashReportsAlways:self];
            }
            
            if (userProvidedMetaData)
                [self persistUserProvidedMetaData:userProvidedMetaData];
            
            [self approveLatestCrashReport];
            [self sendNextCrashReport];
            return YES;
            
        default:
            return NO;
    }
    
}

#pragma mark - PLCrashReporter

/**
 *	 Process new crash reports provided by PLCrashReporter
 *
 * Parse the new crash report and gather additional meta data from the app which will be stored along the crash report
 */
- (void) handleCrashReport {
    PRESLogVerbose(@"VERBOSE: Handling crash report");
    NSError *error = NULL;
    
    if (!self.plCrashReporter) return;
    
    // check if the next call ran successfully the last time
    if (![_fileManager fileExistsAtPath:_analyzerInProgressFile]) {
        // mark the start of the routine
        [_fileManager createFileAtPath:_analyzerInProgressFile contents:nil attributes:nil];
        PRESLogVerbose(@"VERBOSE: AnalyzerInProgress file created");
        
        [self saveSettings];
        
        // Try loading the crash report
        NSData *crashData = [[NSData alloc] initWithData:[self.plCrashReporter loadPendingCrashReportDataAndReturnError: &error]];
        
        NSString *cacheFilename = [NSString stringWithFormat: @"%.0f", [NSDate timeIntervalSinceReferenceDate]];
        _lastCrashFilename = cacheFilename;
        
        if (crashData == nil) {
            PRESLogError(@"ERROR: Could not load crash report: %@", error);
        } else {
            // get the startup timestamp from the crash report, and the file timestamp to calculate the timeinterval when the crash happened after startup
            BITPLCrashReport *report = [[BITPLCrashReport alloc] initWithData:crashData error:&error];
            
            if (report == nil) {
                PRESLogWarning(@"WARNING: Could not parse crash report");
            } else {
                NSDate *appStartTime = nil;
                NSDate *appCrashTime = nil;
                if ([report.processInfo respondsToSelector:@selector(processStartTime)]) {
                    if (report.systemInfo.timestamp && report.processInfo.processStartTime) {
                        appStartTime = report.processInfo.processStartTime;
                        appCrashTime =report.systemInfo.timestamp;
                        _timeIntervalCrashInLastSessionOccurred = [report.systemInfo.timestamp timeIntervalSinceDate:report.processInfo.processStartTime];
                    }
                }
                
                [crashData writeToFile:[_crashesDir stringByAppendingPathComponent: cacheFilename] atomically:YES];
                
                NSString *incidentIdentifier = @"???";
                if (report.uuidRef != NULL) {
                    incidentIdentifier = (NSString *) CFBridgingRelease(CFUUIDCreateString(NULL, report.uuidRef));
                }
                
                NSString *reporterKey = pres_appAnonID(NO) ?: @"";
                
                _lastSessionCrashDetails = [[PRESCrashDetails alloc] initWithIncidentIdentifier:incidentIdentifier
                                                                                    reporterKey:reporterKey
                                                                                         signal:report.signalInfo.name
                                                                                  exceptionName:report.exceptionInfo.exceptionName
                                                                                exceptionReason:report.exceptionInfo.exceptionReason
                                                                                   appStartTime:appStartTime
                                                                                      crashTime:appCrashTime
                                                                                      osVersion:report.systemInfo.operatingSystemVersion
                                                                                        osBuild:report.systemInfo.operatingSystemBuild
                                                                                     appVersion:report.applicationInfo.applicationMarketingVersion
                                                                                       appBuild:report.applicationInfo.applicationVersion
                                                                           appProcessIdentifier:report.processInfo.processID
                                            ];
                
                // fetch and store the meta data after setting _lastSessionCrashDetails, so the property can be used in the protocol methods
                [self storeMetaDataForCrashReportFilename:cacheFilename];
            }
        }
    } else {
        PRESLogWarning(@"WARNING: AnalyzerInProgress file found, handling crash report skipped");
    }
    
    // Purge the report
    // mark the end of the routine
    if ([_fileManager fileExistsAtPath:_analyzerInProgressFile]) {
        [_fileManager removeItemAtPath:_analyzerInProgressFile error:&error];
    }
    
    [self saveSettings];
    
    [self.plCrashReporter purgePendingCrashReport];
}

/**
 Get the filename of the first not approved crash report
 
 @return NSString Filename of the first found not approved crash report
 */
- (NSString *)firstNotApprovedCrashReport {
    if ((!_approvedCrashReports || [_approvedCrashReports count] == 0) && [_crashFiles count] > 0) {
        return [_crashFiles objectAtIndex:0];
    }
    
    for (NSUInteger i=0; i < [_crashFiles count]; i++) {
        NSString *filename = [_crashFiles objectAtIndex:i];
        
        if (![_approvedCrashReports objectForKey:filename]) return filename;
    }
    
    return nil;
}

/**
 *	Check if there are any new crash reports that are not yet processed
 *
 *	@return	`YES` if there is at least one new crash report found, `NO` otherwise
 */
- (BOOL)hasPendingCrashReport {
    if (_crashManagerStatus == PRESCrashManagerStatusDisabled) return NO;
    
    if ([self.fileManager fileExistsAtPath:_crashesDir]) {
        NSError *error = NULL;
        
        NSArray *dirArray = [self.fileManager contentsOfDirectoryAtPath:_crashesDir error:&error];
        
        for (NSString *file in dirArray) {
            NSString *filePath = [_crashesDir stringByAppendingPathComponent:file];
            
            NSDictionary *fileAttributes = [self.fileManager attributesOfItemAtPath:filePath error:&error];
            if ([[fileAttributes objectForKey:NSFileType] isEqualToString:NSFileTypeRegular] &&
                [[fileAttributes objectForKey:NSFileSize] intValue] > 0 &&
                ![file hasSuffix:@".DS_Store"] &&
                ![file hasSuffix:@".analyzer"] &&
                ![file hasSuffix:@".plist"] &&
                ![file hasSuffix:@".data"] &&
                ![file hasSuffix:@".meta"] &&
                ![file hasSuffix:@".desc"]) {
                [_crashFiles addObject:filePath];
            }
        }
    }
    
    if ([_crashFiles count] > 0) {
        PRESLogDebug(@"INFO: %lu pending crash reports found.", (unsigned long)[_crashFiles count]);
        return YES;
    } else {
        if (_didCrashInLastSession) {
            if ([self.delegate respondsToSelector:@selector(crashManagerWillCancelSendingCrashReport:)]) {
                [self.delegate crashManagerWillCancelSendingCrashReport:self];
            }
            
            _didCrashInLastSession = NO;
        }
        
        return NO;
    }
}


#pragma mark - Crash Report Processing

// store the latest crash report as user approved, so if it fails it will retry automatically
- (void)approveLatestCrashReport {
    [_approvedCrashReports setObject:[NSNumber numberWithBool:YES] forKey:[_crashesDir stringByAppendingPathComponent: _lastCrashFilename]];
    [self saveSettings];
}

- (void)triggerDelayedProcessing {
    PRESLogVerbose(@"VERBOSE: Triggering delayed crash processing.");
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(invokeDelayedProcessing) object:nil];
    [self performSelector:@selector(invokeDelayedProcessing) withObject:nil afterDelay:0.5];
}

/**
 * Delayed startup processing for everything that does not to be done in the app startup runloop
 *
 * - Checks if there is another exception handler installed that may block ours
 * - Present UI if the user has to approve new crash reports
 * - Send pending approved crash reports
 */
- (void)invokeDelayedProcessing {
    if (!pres_isRunningInAppExtension() &&
        [[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) {
        return;
    }
    
    PRESLogDebug(@"INFO: Start delayed CrashManager processing");
    
    // was our own exception handler successfully added?
    if (self.exceptionHandler) {
        // get the current top level error handler
        NSUncaughtExceptionHandler *currentHandler = NSGetUncaughtExceptionHandler();
        
        // If the top level error handler differs from our own, then at least another one was added.
        // This could cause exception crashes not to be reported to PreSniff. See log message for details.
        if (self.exceptionHandler != currentHandler) {
            PRESLogWarning(@"[PreSniffObjc] WARNING: Another exception handler was added. If this invokes any kind exit() after processing the exception, which causes any subsequent error handler not to be invoked, these crashes will NOT be reported to PreSniff!");
        }
    }
    
    if (!_sendingInProgress && [self hasPendingCrashReport]) {
        _sendingInProgress = YES;
        
        NSString *notApprovedReportFilename = [self firstNotApprovedCrashReport];
        
        // this can happen in case there is a non approved crash report but it didn't happen in the previous app session
        if (notApprovedReportFilename && !_lastCrashFilename) {
            _lastCrashFilename = [notApprovedReportFilename lastPathComponent];
        }
        
        if (!PRESBundle() || pres_isRunningInAppExtension()) {
            [self approveLatestCrashReport];
            [self sendNextCrashReport];
        } else if (_crashManagerStatus != PRESCrashManagerStatusAutoSend && notApprovedReportFilename) {
            
            if ([self.delegate respondsToSelector:@selector(crashManagerWillShowSubmitCrashReportAlert:)]) {
                [self.delegate crashManagerWillShowSubmitCrashReportAlert:self];
            }
            
            NSString *appName = pres_appName(PRESLocalizedString(@"PreSniffNamePlaceholder"));
            NSString *alertDescription = [NSString stringWithFormat:PRESLocalizedString(@"CrashDataFoundAnonymousDescription"), appName];
            
            // the crash report is not anonymous any more if username or useremail are not nil
            NSString *userid = [self userIDForCrashReport];
            NSString *username = [self userNameForCrashReport];
            NSString *useremail = [self userEmailForCrashReport];
            
            if ((userid && [userid length] > 0) ||
                (username && [username length] > 0) ||
                (useremail && [useremail length] > 0)) {
                alertDescription = [NSString stringWithFormat:PRESLocalizedString(@"CrashDataFoundDescription"), appName];
            }
            
            if (_alertViewHandler) {
                _alertViewHandler();
            } else {
                /* We won't use this for now until we have a more robust solution for displaying UIAlertController
                 // requires iOS 8
                 id uialertcontrollerClass = NSClassFromString(@"UIAlertController");
                 if (uialertcontrollerClass) {
                 __weak typeof(self) weakSelf = self;
                 
                 UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:PRESLocalizedString(@"CrashDataFoundTitle"), appName]
                 message:alertDescription
                 preferredStyle:UIAlertControllerStyleAlert];
                 
                 
                 UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:PRESLocalizedString(@"CrashDontSendReport")
                 style:UIAlertActionStyleCancel
                 handler:^(UIAlertAction * action) {
                 typeof(self) strongSelf = weakSelf;
                 
                 [strongSelf handleUserInput:PRESCrashManagerUserInputDontSend withUserProvidedMetaData:nil];
                 }];
                 
                 [alertController addAction:cancelAction];
                 
                 UIAlertAction *sendAction = [UIAlertAction actionWithTitle:PRESLocalizedString(@"CrashSendReport")
                 style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction * action) {
                 typeof(self) strongSelf = weakSelf;
                 [strongSelf handleUserInput:PRESCrashManagerUserInputSend withUserProvidedMetaData:nil];
                 }];
                 
                 [alertController addAction:sendAction];
                 
                 if (self.shouldShowAlwaysButton) {
                 UIAlertAction *alwaysSendAction = [UIAlertAction actionWithTitle:PRESLocalizedString(@"CrashSendReportAlways")
                 style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction * action) {
                 typeof(self) strongSelf = weakSelf;
                 [strongSelf handleUserInput:PRESCrashManagerUserInputAlwaysSend withUserProvidedMetaData:nil];
                 }];
                 
                 [alertController addAction:alwaysSendAction];
                 }
                 
                 [self showAlertController:alertController];
                 } else {
                 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:[NSString stringWithFormat:PRESLocalizedString(@"CrashDataFoundTitle"), appName]
                                                                    message:alertDescription
                                                                   delegate:self
                                                          cancelButtonTitle:PRESLocalizedString(@"CrashDontSendReport")
                                                          otherButtonTitles:PRESLocalizedString(@"CrashSendReport"), nil];
                
                if (self.shouldShowAlwaysButton) {
                    [alertView addButtonWithTitle:PRESLocalizedString(@"CrashSendReportAlways")];
                }
                
                [alertView show];
#pragma clang diagnostic pop
                /*}*/
            }
        } else {
            [self approveLatestCrashReport];
            [self sendNextCrashReport];
        }
    }
}

/**
 *	 Main startup sequence initializing PLCrashReporter if it wasn't disabled
 */
- (void)startManager {
    if (_crashManagerStatus == PRESCrashManagerStatusDisabled) return;
    
    [self registerObservers];
    
    [self loadSettings];
    
    if (!_isSetup) {
        static dispatch_once_t plcrPredicate;
        dispatch_once(&plcrPredicate, ^{
            /* Configure our reporter */
            
            PLCrashReporterSignalHandlerType signalHandlerType = PLCrashReporterSignalHandlerTypeBSD;
            if (self.isMachExceptionHandlerEnabled) {
                signalHandlerType = PLCrashReporterSignalHandlerTypeMach;
            }
            
            PLCrashReporterSymbolicationStrategy symbolicationStrategy = PLCrashReporterSymbolicationStrategyNone;
            if (self.isOnDeviceSymbolicationEnabled) {
                symbolicationStrategy = PLCrashReporterSymbolicationStrategyAll;
            }
            
            BITPLCrashReporterConfig *config = [[BITPLCrashReporterConfig alloc] initWithSignalHandlerType: signalHandlerType
                                                                                     symbolicationStrategy: symbolicationStrategy];
            self.plCrashReporter = [[BITPLCrashReporter alloc] initWithConfiguration: config];
            
            // Check if we previously crashed
            if ([self.plCrashReporter hasPendingCrashReport]) {
                _didCrashInLastSession = YES;
                [self handleCrashReport];
            }
            
            // The actual signal and mach handlers are only registered when invoking `enableCrashReporterAndReturnError`
            // So it is safe enough to only disable the following part when a debugger is attached no matter which
            // signal handler type is set
            // We only check for this if we are not in the App Store environment
            
            BOOL debuggerIsAttached = NO;
            if (self.appEnvironment != PRESEnvironmentAppStore) {
                if ([self isDebuggerAttached]) {
                    debuggerIsAttached = YES;
                    PRESLogWarning(@"[PreSniffObjc] WARNING: Detecting crashes is NOT enabled due to running the app with a debugger attached.");
                }
            }
            
            if (!debuggerIsAttached) {
                // Multiple exception handlers can be set, but we can only query the top level error handler (uncaught exception handler).
                //
                // To check if PLCrashReporter's error handler is successfully added, we compare the top
                // level one that is set before and the one after PLCrashReporter sets up its own.
                //
                // With delayed processing we can then check if another error handler was set up afterwards
                // and can show a debug warning log message, that the dev has to make sure the "newer" error handler
                // doesn't exit the process itself, because then all subsequent handlers would never be invoked.
                //
                // Note: ANY error handler setup BEFORE PreSniffObjc initialization will not be processed!
                
                // get the current top level error handler
                NSUncaughtExceptionHandler *initialHandler = NSGetUncaughtExceptionHandler();
                
                // PLCrashReporter may only be initialized once. So make sure the developer
                // can't break this
                NSError *error = NULL;
                
                [self configDefaultCrashCallback];
                // Set plCrashReporter callback which contains our default callback and potentially user defined callbacks
                [self.plCrashReporter setCrashCallbacks:&plCrashCallbacks];
                
                // Enable the Crash Reporter
                if (![self.plCrashReporter enableCrashReporterAndReturnError: &error])
                    PRESLogError(@"[PreSniffObjc] ERROR: Could not enable crash reporter: %@", [error localizedDescription]);
                
                // get the new current top level error handler, which should now be the one from PLCrashReporter
                NSUncaughtExceptionHandler *currentHandler = NSGetUncaughtExceptionHandler();
                
                // do we have a new top level error handler? then we were successful
                if (currentHandler && currentHandler != initialHandler) {
                    self.exceptionHandler = currentHandler;
                    
                    PRESLogDebug(@"INFO: Exception handler successfully initialized.");
                } else {
                    // this should never happen, theoretically only if NSSetUncaugtExceptionHandler() has some internal issues
                    PRESLogError(@"[PreSniffObjc] ERROR: Exception handler could not be set. Make sure there is no other exception handler set up!");
                }
                
                // Add the C++ uncaught exception handler, which is currently not handled by PLCrashReporter internally
                [PRESCrashUncaughtCXXExceptionHandlerManager addCXXExceptionHandler:uncaught_cxx_exception_handler];
            }
            _isSetup = YES;
        });
    }
    
    if ([[NSUserDefaults standardUserDefaults] valueForKey:kPRESAppDidReceiveLowMemoryNotification])
        _didReceiveMemoryWarningInLastSession = [[NSUserDefaults standardUserDefaults] boolForKey:kPRESAppDidReceiveLowMemoryNotification];
    
    if (!_didCrashInLastSession && self.isAppNotTerminatingCleanlyDetectionEnabled) {
        BOOL didAppSwitchToBackgroundSafely = YES;
        
        if ([[NSUserDefaults standardUserDefaults] valueForKey:kPRESAppWentIntoBackgroundSafely])
            didAppSwitchToBackgroundSafely = [[NSUserDefaults standardUserDefaults] boolForKey:kPRESAppWentIntoBackgroundSafely];
        
        if (!didAppSwitchToBackgroundSafely) {
            BOOL considerReport = YES;
            
            if ([self.delegate respondsToSelector:@selector(considerAppNotTerminatedCleanlyReportForCrashManager:)]) {
                considerReport = [self.delegate considerAppNotTerminatedCleanlyReportForCrashManager:self];
            }
            
            if (considerReport) {
                PRESLogVerbose(@"INFO: App kill detected, creating crash report.");
                [self createCrashReportForAppKill];
                
                _didCrashInLastSession = YES;
            }
        }
    }
    if ([[UIApplication sharedApplication] applicationState] == UIApplicationStateActive) {
        [self appEnteredForeground];
    }
    [self appEnteredForeground];
    
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kPRESAppDidReceiveLowMemoryNotification];
    
    if(pres_isPreiOS8Environment()) {
        // calling synchronize in pre-iOS 8 takes longer to sync than in iOS 8+, calling synchronize explicitly.
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    
    [self triggerDelayedProcessing];
    PRESLogVerbose(@"VERBOSE: CrashManager startManager has finished.");
}

/**
 *  Creates a fake crash report because the app was killed while being in foreground
 */
- (void)createCrashReportForAppKill {
    NSString *fakeReportUUID = pres_UUID();
    NSString *fakeReporterKey = pres_appAnonID(NO) ?: @"???";
    
    NSString *fakeReportAppMarketingVersion = [[NSUserDefaults standardUserDefaults] objectForKey:kPRESAppMarketingVersion];
    
    NSString *fakeReportAppVersion = [[NSUserDefaults standardUserDefaults] objectForKey:kPRESAppVersion];
    if (!fakeReportAppVersion)
        return;
    
    NSString *fakeReportOSVersion = [[NSUserDefaults standardUserDefaults] objectForKey:kPRESAppOSVersion] ?: [[UIDevice currentDevice] systemVersion];
    
    NSString *fakeReportOSVersionString = fakeReportOSVersion;
    NSString *fakeReportOSBuild = [[NSUserDefaults standardUserDefaults] objectForKey:kPRESAppOSBuild] ?: [self osBuild];
    if (fakeReportOSBuild) {
        fakeReportOSVersionString = [NSString stringWithFormat:@"%@ (%@)", fakeReportOSVersion, fakeReportOSBuild];
    }
    
    NSString *fakeReportAppBundleIdentifier = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"];
    NSString *fakeReportDeviceModel = [self getDevicePlatform] ?: @"Unknown";
    NSString *fakeReportAppUUIDs = [[NSUserDefaults standardUserDefaults] objectForKey:kPRESAppUUIDs] ?: @"";
    
    NSString *fakeSignalName = kPRESCrashKillSignal;
    
    NSMutableString *fakeReportString = [NSMutableString string];
    
    [fakeReportString appendFormat:@"Incident Identifier: %@\n", fakeReportUUID];
    [fakeReportString appendFormat:@"CrashReporter Key:   %@\n", fakeReporterKey];
    [fakeReportString appendFormat:@"Hardware Model:      %@\n", fakeReportDeviceModel];
    [fakeReportString appendFormat:@"Identifier:      %@\n", fakeReportAppBundleIdentifier];
    
    NSString *fakeReportAppVersionString = fakeReportAppMarketingVersion ? [NSString stringWithFormat:@"%@ (%@)", fakeReportAppMarketingVersion, fakeReportAppVersion] : fakeReportAppVersion;
    
    [fakeReportString appendFormat:@"Version:         %@\n", fakeReportAppVersionString];
    [fakeReportString appendString:@"Code Type:       ARM\n"];
    [fakeReportString appendString:@"\n"];
    
    NSLocale *enUSPOSIXLocale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    NSDateFormatter *rfc3339Formatter = [[NSDateFormatter alloc] init];
    [rfc3339Formatter setLocale:enUSPOSIXLocale];
    [rfc3339Formatter setDateFormat:@"yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"];
    [rfc3339Formatter setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    NSString *fakeCrashTimestamp = [rfc3339Formatter stringFromDate:[NSDate date]];
    
    // we use the current date, since we don't know when the kill actually happened
    [fakeReportString appendFormat:@"Date/Time:       %@\n", fakeCrashTimestamp];
    [fakeReportString appendFormat:@"OS Version:      %@\n", fakeReportOSVersionString];
    [fakeReportString appendString:@"Report Version:  104\n"];
    [fakeReportString appendString:@"\n"];
    [fakeReportString appendFormat:@"Exception Type:  %@\n", fakeSignalName];
    [fakeReportString appendString:@"Exception Codes: 00000020 at 0x8badf00d\n"];
    [fakeReportString appendString:@"\n"];
    [fakeReportString appendString:@"Application Specific Information:\n"];
    [fakeReportString appendString:@"The application did not terminate cleanly but no crash occured."];
    if (self.didReceiveMemoryWarningInLastSession) {
        [fakeReportString appendString:@" The app received at least one Low Memory Warning."];
    }
    [fakeReportString appendString:@"\n\n"];
    
    NSString *fakeReportFilename = [NSString stringWithFormat: @"%.0f", [NSDate timeIntervalSinceReferenceDate]];
    
    NSError *error = nil;
    
    NSMutableDictionary *rootObj = [NSMutableDictionary dictionaryWithCapacity:2];
    [rootObj setObject:fakeReportUUID forKey:kPRESFakeCrashUUID];
    if (fakeReportAppMarketingVersion)
        [rootObj setObject:fakeReportAppMarketingVersion forKey:kPRESFakeCrashAppMarketingVersion];
    [rootObj setObject:fakeReportAppVersion forKey:kPRESFakeCrashAppVersion];
    [rootObj setObject:fakeReportAppBundleIdentifier forKey:kPRESFakeCrashAppBundleIdentifier];
    [rootObj setObject:fakeReportOSVersion forKey:kPRESFakeCrashOSVersion];
    [rootObj setObject:fakeReportDeviceModel forKey:kPRESFakeCrashDeviceModel];
    [rootObj setObject:fakeReportAppUUIDs forKey:kPRESFakeCrashAppBinaryUUID];
    [rootObj setObject:fakeReportString forKey:kPRESFakeCrashReport];
    
    _lastSessionCrashDetails = [[PRESCrashDetails alloc] initWithIncidentIdentifier:fakeReportUUID
                                                                        reporterKey:fakeReporterKey
                                                                             signal:fakeSignalName
                                                                      exceptionName:nil
                                                                    exceptionReason:nil
                                                                       appStartTime:nil
                                                                          crashTime:nil
                                                                          osVersion:fakeReportOSVersion
                                                                            osBuild:fakeReportOSBuild
                                                                         appVersion:fakeReportAppMarketingVersion
                                                                           appBuild:fakeReportAppVersion
                                                               appProcessIdentifier:[[NSProcessInfo processInfo] processIdentifier]
                                ];
    
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:(id)rootObj
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&error];
    if (plist) {
        if ([plist writeToFile:[_crashesDir stringByAppendingPathComponent:[fakeReportFilename stringByAppendingPathExtension:@"fake"]] atomically:YES]) {
            [self storeMetaDataForCrashReportFilename:fakeReportFilename];
        }
    } else {
        PRESLogError(@"ERROR: Writing fake crash report. %@", [error description]);
    }
}

/**
 *	 Send all approved crash reports
 *
 * Gathers all collected data and constructs the XML structure and starts the sending process
 */
- (void)sendNextCrashReport {
    NSError *error = NULL;
    
    _crashIdenticalCurrentVersion = NO;
    
    if ([_crashFiles count] == 0)
        return;
    
    NSString *crashXML = nil;
    PRESAttachment *attachment = nil;
    
    // we start sending always with the oldest pending one
    NSString *filename = [_crashFiles objectAtIndex:0];
    NSString *attachmentFilename = filename;
    NSString *cacheFilename = [filename lastPathComponent];
    NSData *crashData = [NSData dataWithContentsOfFile:filename];
    
    if ([crashData length] > 0) {
        BITPLCrashReport *report = nil;
        NSString *crashUUID = @"";
        NSString *installString = nil;
        NSString *crashLogString = nil;
        NSString *appBundleIdentifier = nil;
        NSString *appBundleMarketingVersion = nil;
        NSString *appBundleVersion = nil;
        NSString *osVersion = nil;
        NSString *deviceModel = nil;
        NSString *appBinaryUUIDs = nil;
        NSString *metaFilename = nil;
        
        NSPropertyListFormat format;
        
        if ([[cacheFilename pathExtension] isEqualToString:@"fake"]) {
            NSDictionary *fakeReportDict = (NSDictionary *)[NSPropertyListSerialization
                                                            propertyListWithData:crashData
                                                            options:NSPropertyListMutableContainersAndLeaves
                                                            format:&format
                                                            error:&error];
            
            crashLogString = [fakeReportDict objectForKey:kPRESFakeCrashReport];
            crashUUID = [fakeReportDict objectForKey:kPRESFakeCrashUUID];
            appBundleIdentifier = [fakeReportDict objectForKey:kPRESFakeCrashAppBundleIdentifier];
            appBundleMarketingVersion = [fakeReportDict objectForKey:kPRESFakeCrashAppMarketingVersion] ?: @"";
            appBundleVersion = [fakeReportDict objectForKey:kPRESFakeCrashAppVersion];
            appBinaryUUIDs = [fakeReportDict objectForKey:kPRESFakeCrashAppBinaryUUID];
            deviceModel = [fakeReportDict objectForKey:kPRESFakeCrashDeviceModel];
            osVersion = [fakeReportDict objectForKey:kPRESFakeCrashOSVersion];
            
            metaFilename = [cacheFilename stringByReplacingOccurrencesOfString:@".fake" withString:@".meta"];
            attachmentFilename = [attachmentFilename stringByReplacingOccurrencesOfString:@".fake" withString:@""];
            
            if ([appBundleVersion compare:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]] == NSOrderedSame) {
                _crashIdenticalCurrentVersion = YES;
            }
            
        } else {
            report = [[BITPLCrashReport alloc] initWithData:crashData error:&error];
        }
        
        if (report == nil && crashLogString == nil) {
            PRESLogWarning(@"WARNING: Could not parse crash report");
            // we cannot do anything with this report, so delete it
            [self cleanCrashReportWithFilename:filename];
            // we don't continue with the next report here, even if there are to prevent calling sendCrashReports from itself again
            // the next crash will be automatically send on the next app start/becoming active event
            return;
        }
        
        installString = pres_appAnonID(NO) ?: @"";
        
        if (report) {
            if (report.uuidRef != NULL) {
                crashUUID = (NSString *) CFBridgingRelease(CFUUIDCreateString(NULL, report.uuidRef));
            }
            metaFilename = [cacheFilename stringByAppendingPathExtension:@"meta"];
            crashLogString = [PRESCrashReportTextFormatter stringValueForCrashReport:report crashReporterKey:installString];
            appBundleIdentifier = report.applicationInfo.applicationIdentifier;
            appBundleMarketingVersion = report.applicationInfo.applicationMarketingVersion ?: @"";
            appBundleVersion = report.applicationInfo.applicationVersion;
            osVersion = report.systemInfo.operatingSystemVersion;
            deviceModel = [self getDevicePlatform];
            appBinaryUUIDs = [self extractAppUUIDs:report];
            if ([report.applicationInfo.applicationVersion compare:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]] == NSOrderedSame) {
                _crashIdenticalCurrentVersion = YES;
            }
        }
        
        if ([report.applicationInfo.applicationVersion compare:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]] == NSOrderedSame) {
            _crashIdenticalCurrentVersion = YES;
        }
        
        NSString *username = @"";
        NSString *useremail = @"";
        NSString *userid = @"";
        NSString *applicationLog = @"";
        NSString *description = @"";
        
        NSData *plist = [NSData dataWithContentsOfFile:[_crashesDir stringByAppendingPathComponent:metaFilename]];
        if (plist) {
            NSDictionary *metaDict = (NSDictionary *)[NSPropertyListSerialization
                                                      propertyListWithData:plist
                                                      options:NSPropertyListMutableContainersAndLeaves
                                                      format:&format
                                                      error:&error];
            
            username = [self stringValueFromKeychainForKey:[NSString stringWithFormat:@"%@.%@", attachmentFilename.lastPathComponent, kPRESCrashMetaUserName]] ?: @"";
            useremail = [self stringValueFromKeychainForKey:[NSString stringWithFormat:@"%@.%@", attachmentFilename.lastPathComponent, kPRESCrashMetaUserEmail]] ?: @"";
            userid = [self stringValueFromKeychainForKey:[NSString stringWithFormat:@"%@.%@", attachmentFilename.lastPathComponent, kPRESCrashMetaUserID]] ?: @"";
            applicationLog = [metaDict objectForKey:kPRESCrashMetaApplicationLog] ?: @"";
            description = [NSString stringWithContentsOfFile:[NSString stringWithFormat:@"%@.desc", [_crashesDir stringByAppendingPathComponent: cacheFilename]] encoding:NSUTF8StringEncoding error:&error];
            attachment = [self attachmentForCrashReport:attachmentFilename];
        } else {
            PRESLogError(@"ERROR: Reading crash meta data. %@", error);
        }
        
        if ([applicationLog length] > 0) {
            if ([description length] > 0) {
                description = [NSString stringWithFormat:@"%@\n\nLog:\n%@", description, applicationLog];
            } else {
                description = [NSString stringWithFormat:@"Log:\n%@", applicationLog];
            }
        }
        
        crashXML = [NSString stringWithFormat:@"<crashes><crash><applicationname><![CDATA[%@]]></applicationname><uuids>%@</uuids><bundleidentifier>%@</bundleidentifier><systemversion>%@</systemversion><platform>%@</platform><senderversion>%@</senderversion><versionstring>%@</versionstring><version>%@</version><uuid>%@</uuid><log><![CDATA[%@]]></log><userid>%@</userid><username>%@</username><contact>%@</contact><installstring>%@</installstring><description><![CDATA[%@]]></description></crash></crashes>",
                    [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"],
                    appBinaryUUIDs,
                    appBundleIdentifier,
                    osVersion,
                    deviceModel,
                    [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"],
                    appBundleMarketingVersion,
                    appBundleVersion,
                    crashUUID,
                    [crashLogString stringByReplacingOccurrencesOfString:@"]]>" withString:@"]]" @"]]><![CDATA[" @">" options:NSLiteralSearch range:NSMakeRange(0,crashLogString.length)],
                    userid,
                    username,
                    useremail,
                    installString,
                    [description stringByReplacingOccurrencesOfString:@"]]>" withString:@"]]" @"]]><![CDATA[" @">" options:NSLiteralSearch range:NSMakeRange(0,description.length)]];
        
        PRESLogDebug(@"INFO: Sending crash reports:\n%@", crashXML);
        [self sendCrashReportWithFilename:filename xml:crashXML attachment:attachment];
    } else {
        // we cannot do anything with this report, so delete it
        [self cleanCrashReportWithFilename:filename];
    }
}

#pragma mark - UIAlertView Delegate

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    switch (buttonIndex) {
        case 0:
            [self handleUserInput:PRESCrashManagerUserInputDontSend withUserProvidedMetaData:nil];
            break;
        case 1:
            [self handleUserInput:PRESCrashManagerUserInputSend withUserProvidedMetaData:nil];
            break;
        case 2:
            [self handleUserInput:PRESCrashManagerUserInputAlwaysSend withUserProvidedMetaData:nil];
            break;
    }
}
#pragma clang diagnostic pop

#pragma mark - Networking

- (NSData *)postBodyWithXML:(NSString *)xml attachment:(PRESAttachment *)attachment boundary:(NSString *)boundary {
    NSMutableData *postBody =  [NSMutableData data];
    
    //  [postBody appendData:[[NSString stringWithFormat:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [postBody appendData:[PRESNetworkClient dataWithPostValue:PRES_NAME
                                                       forKey:@"sdk"
                                                     boundary:boundary]];
    
    [postBody appendData:[PRESNetworkClient dataWithPostValue:[PRESVersion getSDKVersion]
                                                       forKey:@"sdk_version"
                                                     boundary:boundary]];
    
    [postBody appendData:[PRESNetworkClient dataWithPostValue:@"no"
                                                       forKey:@"feedbackEnabled"
                                                     boundary:boundary]];
    
    [postBody appendData:[PRESNetworkClient dataWithPostValue:[xml dataUsingEncoding:NSUTF8StringEncoding]
                                                       forKey:@"xml"
                                                  contentType:@"text/xml"
                                                     boundary:boundary
                                                     filename:@"crash.xml"]];
    
    if (attachment && attachment.hockeyAttachmentData) {
        NSString *attachmentFilename = attachment.filename;
        if (!attachmentFilename) {
            attachmentFilename = @"Attachment_0";
        }
        [postBody appendData:[PRESNetworkClient dataWithPostValue:attachment.hockeyAttachmentData
                                                           forKey:@"attachment0"
                                                      contentType:attachment.contentType
                                                         boundary:boundary
                                                         filename:attachmentFilename]];
    }
    
    [postBody appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    
    return postBody;
}

- (NSMutableURLRequest *)requestWithBoundary:(NSString *)boundary {
    NSString *postCrashPath = [NSString stringWithFormat:@"api/2/apps/%@/crashes", self.encodedAppIdentifier];
    
    NSMutableURLRequest *request = [self.hockeyAppClient requestWithMethod:@"POST"
                                                                      path:postCrashPath
                                                                parameters:nil];
    
    [request setCachePolicy: NSURLRequestReloadIgnoringLocalCacheData];
    [request setValue:@"PreSniffObjc/iOS" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
    
    NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
    [request setValue:contentType forHTTPHeaderField:@"Content-type"];
    
    return request;
}

// process upload response
- (void)processUploadResultWithFilename:(NSString *)filename responseData:(NSData *)responseData statusCode:(NSInteger)statusCode error:(NSError *)error {
    __block NSError *theError = error;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        _sendingInProgress = NO;
        
        if (nil == theError) {
            if (nil == responseData || [responseData length] == 0) {
                theError = [NSError errorWithDomain:kPRESCrashErrorDomain
                                               code:PRESCrashAPIReceivedEmptyResponse
                                           userInfo:@{
                                                      NSLocalizedDescriptionKey: @"Sending failed with an empty response!"
                                                      }
                            ];
            } else if (statusCode >= 200 && statusCode < 400) {
                [self cleanCrashReportWithFilename:filename];
                
                // PreSniff uses PList XML format
                NSMutableDictionary *response = [NSPropertyListSerialization propertyListWithData:responseData
                                                                                          options:NSPropertyListMutableContainersAndLeaves
                                                                                           format:nil
                                                                                            error:&theError];
                PRESLogDebug(@"INFO: Received API response: %@", response);
                
                if ([self.delegate respondsToSelector:@selector(crashManagerDidFinishSendingCrashReport:)]) {
                    [self.delegate crashManagerDidFinishSendingCrashReport:self];
                }
                
                // only if sending the crash report went successfully, continue with the next one (if there are more)
                [self sendNextCrashReport];
            } else if (statusCode == 400) {
                [self cleanCrashReportWithFilename:filename];
                
                theError = [NSError errorWithDomain:kPRESCrashErrorDomain
                                               code:PRESCrashAPIAppVersionRejected
                                           userInfo:@{
                                                      NSLocalizedDescriptionKey: @"The server rejected receiving crash reports for this app version!"
                                                      }
                            ];
            } else {
                theError = [NSError errorWithDomain:kPRESCrashErrorDomain
                                               code:PRESCrashAPIErrorWithStatusCode
                                           userInfo:@{
                                                      NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Sending failed with status code: %li", (long)statusCode]
                                                      }
                            ];
            }
        }
        
        if (theError) {
            if ([self.delegate respondsToSelector:@selector(crashManager:didFailWithError:)]) {
                [self.delegate crashManager:self didFailWithError:theError];
            }
            
            PRESLogError(@"ERROR: %@", [theError localizedDescription]);
        }
    });
}

/**
 *	 Send the XML data to the server
 *
 * Wraps the XML structure into a POST body and starts sending the data asynchronously
 *
 *	@param	xml	The XML data that needs to be send to the server
 */
- (void)sendCrashReportWithFilename:(NSString *)filename xml:(NSString*)xml attachment:(PRESAttachment *)attachment {
    BOOL sendingWithURLSession = NO;
    
    if ([PRESHelper isURLSessionSupported]) {
        NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
        __block NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfiguration];
        
        NSURLRequest *request = [self requestWithBoundary:kPRESNetworkClientBoundary];
        NSData *data = [self postBodyWithXML:xml attachment:attachment boundary:kPRESNetworkClientBoundary];
        
        if (request && data) {
            __weak typeof (self) weakSelf = self;
            NSURLSessionUploadTask *uploadTask = [session uploadTaskWithRequest:request
                                                                       fromData:data
                                                              completionHandler:^(NSData *responseData, NSURLResponse *response, NSError *error) {
                                                                  typeof (self) strongSelf = weakSelf;
                                                                  
                                                                  [session finishTasksAndInvalidate];
                                                                  
                                                                  NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*) response;
                                                                  NSInteger statusCode = [httpResponse statusCode];
                                                                  [strongSelf processUploadResultWithFilename:filename responseData:responseData statusCode:statusCode error:error];
                                                              }];
            
            [uploadTask resume];
            sendingWithURLSession = YES;
        }
    }
    
    if (!sendingWithURLSession) {
        NSMutableURLRequest *request = [self requestWithBoundary:kPRESNetworkClientBoundary];
        
        NSData *postBody = [self postBodyWithXML:xml attachment:attachment boundary:kPRESNetworkClientBoundary];
        [request setHTTPBody:postBody];
        
        __weak typeof (self) weakSelf = self;
        PRESHTTPOperation *operation = [self.hockeyAppClient
                                        operationWithURLRequest:request
                                        completion:^(PRESHTTPOperation *operation, NSData* responseData, NSError *error) {
                                            typeof (self) strongSelf = weakSelf;
                                            
                                            NSInteger statusCode = [operation.response statusCode];
                                            [strongSelf processUploadResultWithFilename:filename responseData:responseData statusCode:statusCode error:error];
                                        }];
        
        [self.hockeyAppClient enqeueHTTPOperation:operation];
    }
    
    if ([self.delegate respondsToSelector:@selector(crashManagerWillSendCrashReport:)]) {
        [self.delegate crashManagerWillSendCrashReport:self];
    }
    
    PRESLogDebug(@"INFO: Sending crash reports started.");
}

- (NSTimeInterval)timeintervalCrashInLastSessionOccured {
    return self.timeIntervalCrashInLastSessionOccurred;
}

@end
