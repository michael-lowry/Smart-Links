#!/usr/bin/env swift
import AppKit
import Foundation
 
func hexPreview(_ data: Data, max: Int = 128) -> String {
    let head = data.prefix(max)
    return head.map { String(format: "%02X", $0) }.joined(separator: " ")
}
 
let pb = NSPasteboard.general
guard let items = pb.pasteboardItems, !items.isEmpty else {
    print("Clipboard: empty")
    exit(0)
}
 
print("Items: \(items.count)\n")
 
for (idx, item) in items.enumerated() {
    let types = item.types.map { $0.rawValue }.sorted()
    print("=== Item \(idx) ===")
    print("Types (\(types.count)):")
    for t in types { print("  - \(t)") }
 
    // Common textual UTIs you may encounter
    let textTypes = [
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.plain-text",
        "public.rtf",
        "public.html",
        "net.daringfireball.markdown",
        "public.url",
        "public.file-url"
    ]
 
    for t in types {
        print("\n--- \(t) ---")
 
        // Try string first for known text-ish types
        if textTypes.contains(t), let s = item.string(forType: NSPasteboard.PasteboardType(t)) {
            let utf8Bytes = s.data(using: .utf8)?.count ?? 0
            print("Kind      : text")
            print("Chars     : \(s.count)")
            print("UTF8 bytes : \(utf8Bytes)")
            print("Content   :\n\(s)")
            continue
        }
 
        // Otherwise try raw data
        if let d = item.data(forType: NSPasteboard.PasteboardType(t)) {
            print("Kind      : binary")
            print("Bytes     : \(d.count)")
            print("Hex(128)  : \(hexPreview(d))")
        } else if let s = item.string(forType: NSPasteboard.PasteboardType(t)) {
            // Fallback: some types may still return a string
            let utf8Bytes = s.data(using: .utf8)?.count ?? 0
            print("Kind      : text (fallback)")
            print("Chars     : \(s.count)")
            print("UTF8 bytes : \(utf8Bytes)")
            print("Content   :\n\(s)")
        } else {
            print("Unable to read data for this type.")
        }
    }
    print("\n")
}
