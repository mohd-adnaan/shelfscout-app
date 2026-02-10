// ImageOrientationFixer.m — Objective-C bridge for React Native

#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(ImageOrientationFixer, NSObject)

RCT_EXTERN_METHOD(fixOrientation:(NSString *)imagePath
                  maxDimension:(int)maxDimension
                  quality:(double)quality
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)

@end
