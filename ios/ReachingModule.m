// ReachingModule.m
// Objective-C bridge for the ReachingModule Swift native module.

#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(ReachingModule, NSObject)

RCT_EXTERN_METHOD(startReaching:(NSDictionary *)params
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)

RCT_EXTERN_METHOD(stopReaching:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)

@end
