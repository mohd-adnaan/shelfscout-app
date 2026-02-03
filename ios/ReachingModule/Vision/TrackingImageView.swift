//
//  TrackingImageView.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-02-03.
//

import Foundation
import Vision
import AVFoundation
import UIKit

class TrackingImageView: UIView {
    
    var image: UIImage!

    var imageAreaRect = CGRect.zero
    
    var targetPoint = CGPoint.zero
    var targetHeight:CGFloat = 0
    var targetWidth:CGFloat = 0
    var handPoint = CGPoint.zero
    var trackingRect = CGRect.zero
    
    var CVpixelSize: CGSize = CGSize.zero
    
    var indicationMessage: String = "Look around for a target object"
    
    // Add predefined screen properties
    let screenSize: CGSize = UIScreen.main.bounds.size
    let screenScale: CGFloat = UIScreen.main.nativeScale
    let screenWidthInPixels: CGFloat
    let screenHeightInPixels: CGFloat
    
    let uncenteredOffset: CGFloat = 20
    
    init() {
        self.screenWidthInPixels = screenSize.width * screenScale
        self.screenHeightInPixels = screenSize.height * screenScale
        super.init(frame: .zero)
    }
    
    required init?(coder: NSCoder) {
        self.screenWidthInPixels = screenSize.width * screenScale
        self.screenHeightInPixels = screenSize.height * screenScale
        super.init(coder: coder)
    }

    // Rubber-banding setup
    var rubberbandingStart = CGPoint.zero
    var rubberbandingVector = CGPoint.zero
    var rubberbandingRect: CGRect {
        let pt1 = self.rubberbandingStart
        let pt2 = CGPoint(x: self.rubberbandingStart.x + self.rubberbandingVector.x, y: self.rubberbandingStart.y + self.rubberbandingVector.y)
        let rect = CGRect(x: min(pt1.x, pt2.x), y: min(pt1.y, pt2.y), width: abs(pt1.x - pt2.x), height: abs(pt1.y - pt2.y))
        
        return rect
    }

    var rubberbandingRectNormalized: CGRect {
        guard imageAreaRect.size.width > 0 && imageAreaRect.size.height > 0 else {
            return CGRect.zero
        }
        
        var rect = rubberbandingRect
        
        // Make it relative to imageAreaRect
        rect.origin.x = (rect.origin.x - self.imageAreaRect.origin.x) / self.imageAreaRect.size.width
        rect.origin.y = (rect.origin.y - self.imageAreaRect.origin.y) / self.imageAreaRect.size.height
        rect.size.width /= self.imageAreaRect.size.width
        rect.size.height /= self.imageAreaRect.size.height
        
        // Adjust to Vision.framework input requrement - origin at LLC
        rect.origin.y = 1.0 - rect.origin.y - rect.size.height
        
        return rect
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.setNeedsDisplay()
    }
    
    override func draw(_ rect: CGRect) {

        let ctx = UIGraphicsGetCurrentContext()!
        
        self.trackingRect = rect
        
        ctx.saveGState()
        
        ctx.clear(rect)
        ctx.setFillColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        ctx.setLineWidth(2.0)
        
        //Define the size of the point for the object and hand
        let pointSize: CGFloat = 10.0 // Adjust the size of the point as needed
        
        // Make sure image scaling is correctly applied
        // Aspect Fill to match CaptureSession preview setting
        guard scaleImage(to: rect.size, aspectFill: true) != nil else {
            return
        }
        
        //Draw the center of the detected object
        if self.targetPoint != CGPoint.zero {
            var targetCenter = CGPoint.zero
            if targetPoint.x < 1 {
                targetCenter = self.scale(cornerPoint: self.targetPoint)
            } else {
                targetCenter = self.targetPoint
            }
            
            let pointTargetRect = CGRect(x: targetCenter.x - pointSize / 2, y: targetCenter.y - pointSize / 2, width: pointSize, height: pointSize)
            ctx.setFillColor(UIColor.green.cgColor)
            ctx.fillEllipse(in: pointTargetRect)
            
            // Calculate the position to center the rectangle in the middle of rect
            let centerRect = CGRect(x: targetCenter.x - targetWidth/2, y: targetCenter.y - targetHeight/2, width: targetWidth, height: targetHeight)
            
            // Draw the centered rectangle contours
            ctx.setStrokeColor(UIColor.blue.cgColor) // Set the stroke color of the rectangle
            ctx.stroke(centerRect) // Stroke the rectangle
            
            if targetWidth > 0 && targetHeight > 0 {
                let uncenterRect = CGRect(x: targetCenter.x - targetWidth/2 - self.uncenteredOffset, y: targetCenter.y - targetHeight/2 - self.uncenteredOffset, width: targetWidth + 2*self.uncenteredOffset, height: targetHeight + 2*self.uncenteredOffset)
                
                // Draw the centered rectangle contours
                ctx.setStrokeColor(UIColor.cyan.cgColor) // Set the stroke color of the rectangle
                ctx.stroke(uncenterRect) // Stroke the rectangle
            }
        }
        
        //Draw the center of the detected object
        var referencePoint:CGPoint = CGPoint.zero
        if self.handPoint != CGPoint.zero {
            referencePoint = self.scale(cornerPoint: self.handPoint)
            let pointHandRect = CGRect(x: referencePoint.x - pointSize / 2, y: referencePoint.y - pointSize / 2, width: pointSize, height: pointSize)
            ctx.setFillColor(UIColor.yellow.cgColor)
            ctx.fillEllipse(in: pointHandRect)
        } else {
            // Draw a small point at the center of the image
            referencePoint = CGPoint(x: rect.midX, y: rect.midY)
            let pointRect = CGRect(x: referencePoint.x - pointSize / 2, y: referencePoint.y - pointSize / 2, width: pointSize, height: pointSize)
            ctx.setFillColor(UIColor.red.cgColor)
            ctx.fillEllipse(in: pointRect)
        }
        
        // Draw indication message
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.white
        ]
        let attributedString = NSAttributedString(string: self.indicationMessage, attributes: attributes)
        let stringSize = attributedString.size()
        let stringRect = CGRect(x: rect.midX - stringSize.width / 2, y: rect.midY - stringSize.height / 2, width: stringSize.width, height: stringSize.height)
        attributedString.draw(in: stringRect)
        
        ctx.restoreGState()
    }

    private func scaleImage(to viewSize: CGSize, aspectFill: Bool) -> UIImage? {
        guard self.image != nil && self.image.size != CGSize.zero else {
            return nil
        }

        self.imageAreaRect = CGRect.zero
        
        //Take the rotation into account
        //let imageAspectRatio = Double(self.image.size.width / self.image.size.height)
        let imageAspectRatio = self.image.size.height / self.image.size.width
        
        // AspectFill setting
        if (aspectFill) {
            // Force image.width = view.width
            
            let imageSizeAspectFill = CGSize(width: viewSize.width, height: floor(viewSize.width / imageAspectRatio))
            let imageX: CGFloat = 0
            let imageY = floor((viewSize.height - imageSizeAspectFill.height) / 2.0)
            self.imageAreaRect = CGRect(x: imageX,
                                        y: imageY,
                                        width: self.trackingRect.width,
                                        height: self.trackingRect.height)
        } else {
            // Here for future support, not used currently
            // There are two possible cases to fully fit self.image into the the ImageTrackingView area:
            // Option 1) image.width = view.width ==> image.height <= view.height
            // Option 2) image.height = view.height ==> image.width <= view.width
            
            // Check if we're in Option 1) case and initialize self.imageAreaRect accordingly
            let imageSizeOption1 = CGSize(width: viewSize.width, height: floor(viewSize.width / imageAspectRatio))
            if imageSizeOption1.height <= viewSize.height {
                let imageX: CGFloat = 0
                let imageY = floor((viewSize.height - imageSizeOption1.height) / 2.0)
                self.imageAreaRect = CGRect(x: imageX,
                                            y: imageY,
                                            width: imageSizeOption1.width,
                                            height: imageSizeOption1.height)
            }
            
            if self.imageAreaRect == CGRect.zero {
                // Check if we're in Option 2) case if Option 1) didn't work out and initialize imageAreaRect accordingly
                let imageSizeOption2 = CGSize(width: floor(viewSize.height * imageAspectRatio), height: viewSize.height)
                if imageSizeOption2.width <= viewSize.width {
                    let imageX = floor((viewSize.width - imageSizeOption2.width) / 2.0)
                    let imageY: CGFloat = 0
                    self.imageAreaRect = CGRect(x: imageX,
                                                y: imageY,
                                                width: imageSizeOption2.width,
                                                height: imageSizeOption2.height)
                }
            }
        }

        // In next line, pass 0.0 to use the current device's pixel scaling factor (and thus account for Retina resolution).
        // Pass 1.0 to force exact pixel size.
        UIGraphicsBeginImageContextWithOptions(self.imageAreaRect.size, false, 0.0)
        self.image.draw(in: CGRect(x: 0.0, y: 0.0, width: self.imageAreaRect.size.width, height: self.imageAreaRect.size.height))

        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return newImage // newImage
    }
    
    func scale(cornerPoint point: CGPoint) -> CGPoint {
        
        let scaleFactor = self.imageAreaRect.size
        let pointX = 1 - point.x
        
        //Compute the location where the QR code it outside of the trackingView
        let outsideFactor = ((CVpixelSize.width - self.screenWidthInPixels) / (2 * self.screenWidthInPixels))
        let scaledX = (pointX - outsideFactor) / (1 - (2 * outsideFactor))
        
        return CGPoint(x: scaledX * scaleFactor.width, y: point.y * scaleFactor.height)
    }
    
    func scaleRect(width: CGFloat, height: CGFloat) -> (CGFloat, CGFloat) {
        
        let scaleWidthFactor = self.CVpixelSize.width/self.screenWidthInPixels
        let scaleHeightFactor = self.CVpixelSize.height/self.screenHeightInPixels
        
        return (scaleWidthFactor * screenSize.width * width, scaleHeightFactor * screenSize.height * height)
    }
    
    func resetTracking() {
        
        self.targetPoint = CGPoint.zero
        self.targetHeight = 0
        self.targetWidth = 0
        self.handPoint = CGPoint.zero
        self.trackingRect = CGRect.zero
        
        self.CVpixelSize = CGSize.zero
        
        self.indicationMessage = "Look around for a target object"
    }
    
}
