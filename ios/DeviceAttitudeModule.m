// DeviceAttitudeModule.m
// Objective-C bridge for the DeviceAttitudeModule Swift native module.

#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(DeviceAttitudeModule, NSObject)

RCT_EXTERN_METHOD(start:(NSDictionary *)options
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)

RCT_EXTERN_METHOD(stop:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)

RCT_EXTERN_METHOD(getAttitude:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)

@end
