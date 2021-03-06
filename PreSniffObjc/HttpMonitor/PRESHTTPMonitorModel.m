//
//  PRESHTTPMonitorModel.m
//  PreSniffSDK
//
//  Created by WangSiyu on 15/03/2017.
//  Copyright © 2017 pre-engineering. All rights reserved.
//

#import "PRESHTTPMonitorModel.h"
#import "PRESUtilities.h"
#import <objc/runtime.h>

@implementation PRESHTTPMonitorModel

- (instancetype)init {
    if (self = [super init]) {
        self.platform = 1;
        self.appName = [PRESUtilities getAppName];
        self.appBundleId = [PRESUtilities getAppBundleId];
        self.osVersion = [PRESUtilities getOsVersion];
        self.deviceModel = [PRESUtilities getDeviceModel];
        self.deviceUUID = [PRESUtilities getDeviceUUID];
    }
    return self;
}

@end
