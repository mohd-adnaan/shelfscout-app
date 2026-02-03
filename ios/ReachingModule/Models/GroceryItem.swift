//
//  GroceryItem.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-02-03.
//

import Foundation

/**
 * GroceryItem - Model for object physical dimensions
 *
 * Used by the reaching system to estimate real-world distances
 * based on apparent size in camera frame.
 *
 * Note: With Qwen backend detection, these are approximations.
 * The system primarily relies on ARKit depth estimation now.
 */
struct GroceryItem {
    /// Display name of the item
    let name: String
    
    /// Real-world height in meters
    let height: Float
    
    /// Real-world width in meters
    let width: Float
    
    /// Real-world depth in meters (optional)
    let depth: Float?
    
    /// Category for grouping similar items
    let category: String
    
    init(name: String, height: Float, width: Float, depth: Float? = nil, category: String = "general") {
        self.name = name
        self.height = height
        self.width = width
        self.depth = depth
        self.category = category
    }
}

// MARK: - Common Items Library

extension GroceryItem {
    
    /// Default item when object type is unknown
    static let defaultItem = GroceryItem(
        name: "Unknown Object",
        height: 0.15,  // 15cm default
        width: 0.10,   // 10cm default
        category: "general"
    )
    
    /// Common household and grocery items
    static let commonItems: [String: GroceryItem] = [
        // Fruits
        "banana": GroceryItem(name: "Banana", height: 0.20, width: 0.04, category: "fruit"),
        "apple": GroceryItem(name: "Apple", height: 0.08, width: 0.08, category: "fruit"),
        "orange": GroceryItem(name: "Orange", height: 0.08, width: 0.08, category: "fruit"),
        
        // Bottles & Containers
        "bottle": GroceryItem(name: "Bottle", height: 0.25, width: 0.07, category: "container"),
        "water bottle": GroceryItem(name: "Water Bottle", height: 0.22, width: 0.065, category: "container"),
        "cup": GroceryItem(name: "Cup", height: 0.12, width: 0.08, category: "container"),
        "mug": GroceryItem(name: "Mug", height: 0.10, width: 0.08, category: "container"),
        "glass": GroceryItem(name: "Glass", height: 0.15, width: 0.07, category: "container"),
        
        // Electronics
        "phone": GroceryItem(name: "Phone", height: 0.15, width: 0.07, category: "electronics"),
        "remote": GroceryItem(name: "Remote", height: 0.20, width: 0.05, category: "electronics"),
        "laptop": GroceryItem(name: "Laptop", height: 0.02, width: 0.35, category: "electronics"),
        
        // Kitchen Items
        "plate": GroceryItem(name: "Plate", height: 0.02, width: 0.25, category: "kitchen"),
        "bowl": GroceryItem(name: "Bowl", height: 0.08, width: 0.15, category: "kitchen"),
        "fork": GroceryItem(name: "Fork", height: 0.02, width: 0.20, category: "kitchen"),
        "spoon": GroceryItem(name: "Spoon", height: 0.02, width: 0.18, category: "kitchen"),
        "knife": GroceryItem(name: "Knife", height: 0.02, width: 0.22, category: "kitchen"),
        
        // Personal Items
        "keys": GroceryItem(name: "Keys", height: 0.06, width: 0.03, category: "personal"),
        "wallet": GroceryItem(name: "Wallet", height: 0.02, width: 0.10, category: "personal"),
        "glasses": GroceryItem(name: "Glasses", height: 0.04, width: 0.14, category: "personal"),
        
        // Office
        "pen": GroceryItem(name: "Pen", height: 0.015, width: 0.14, category: "office"),
        "book": GroceryItem(name: "Book", height: 0.03, width: 0.20, category: "office"),
        "notebook": GroceryItem(name: "Notebook", height: 0.02, width: 0.22, category: "office"),
        
        // QR Code (for backward compatibility)
        "qrcode": GroceryItem(name: "QR Code", height: 0.05, width: 0.05, category: "marker"),
        "qr code": GroceryItem(name: "QR Code", height: 0.05, width: 0.05, category: "marker"),
    ]
    
    /// Find item by name (case-insensitive)
    static func find(byName name: String) -> GroceryItem {
        let normalizedName = name.lowercased().trimmingCharacters(in: .whitespaces)
        
        // Direct match
        if let item = commonItems[normalizedName] {
            return item
        }
        
        // Partial match
        for (key, item) in commonItems {
            if normalizedName.contains(key) || key.contains(normalizedName) {
                return item
            }
        }
        
        // Return default with the provided name
        return GroceryItem(
            name: name,
            height: defaultItem.height,
            width: defaultItem.width,
            category: "unknown"
        )
    }
}

// MARK: - Distance Estimation

extension GroceryItem {
    
    /**
     * Estimate distance based on apparent size in camera frame
     *
     * Uses pinhole camera model: distance = (realSize * focalLength) / apparentSize
     *
     * - Parameters:
     *   - apparentHeight: Height of object in pixels
     *   - apparentWidth: Width of object in pixels
     *   - focalLength: Camera focal length in pixels
     * - Returns: Estimated distance in meters
     */
    func estimateDistance(apparentHeight: Float, apparentWidth: Float, focalLength: Float) -> Float {
        // Use the larger dimension for more stable estimate
        let useHeight = apparentHeight > apparentWidth
        
        let realSize = useHeight ? height : width
        let apparentSize = useHeight ? apparentHeight : apparentWidth
        
        guard apparentSize > 0 else { return 1.0 } // Default 1 meter if no size
        
        let distance = (realSize * focalLength) / apparentSize
        
        // Clamp to reasonable range (0.1m to 10m)
        return max(0.1, min(10.0, distance))
    }
}
