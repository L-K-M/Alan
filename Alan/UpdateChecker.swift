//
//  UpdateChecker.swift
//  Alan
//
//  Created by Tyler Hall on 11/26/25.
//

import Foundation

// A dependency-free "is there a newer release?" check against the GitHub
// Releases API. Sparkle needs a stable Developer ID the ad-hoc release pipeline
// doesn't have, so this is a plain background URLSession GET, decoded by hand,
// failing silently on any error. Drives the manual "Check for Updates…" status
// menu item (which gives explicit up-to-date feedback); an automatic periodic
// check could be layered on later behind an opt-in preference.
enum UpdateChecker {

    static let releasesAPI = URL(string: "https://api.github.com/repos/L-K-M/Alan/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/L-K-M/Alan/releases/latest")!

    enum Outcome {
        case upToDate(version: String)
        case updateAvailable(version: String, url: URL)
        case failed
    }

    // Fetch the latest release and report the outcome on the main queue.
    static func check(completion: @escaping (Outcome) -> Void) {
        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let outcome = parse(data: data, response: response)
            DispatchQueue.main.async { completion(outcome) }
        }
        task.resume()
    }

    private static func parse(data: Data?, response: URLResponse?) -> Outcome {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            return .failed
        }
        let current = currentVersion()
        let urlString = (json["html_url"] as? String) ?? releasesPage.absoluteString
        let url = URL(string: urlString) ?? releasesPage
        if compareVersions(tag, current) > 0 {
            return .updateAvailable(version: displayVersion(tag), url: url)
        }
        return .upToDate(version: displayVersion(current))
    }

    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // Strip a leading "v" for display; keep any pre-release suffix as-is.
    private static func displayVersion(_ raw: String) -> String {
        var v = raw
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return v
    }

    // Component-wise numeric compare: returns 1 if a > b, -1 if a < b, 0 if
    // equal. A plain string compare mis-orders "2.10.0" before "2.9.0";
    // splitting on "." and comparing Ints avoids that. Missing or non-numeric
    // components count as 0, so "2.7" == "2.7.0".
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let ca = numericComponents(a)
        let cb = numericComponents(b)
        for i in 0..<max(ca.count, cb.count) {
            let x = i < ca.count ? ca[i] : 0
            let y = i < cb.count ? cb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    private static func numericComponents(_ raw: String) -> [Int] {
        var v = raw
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        // Drop a pre-release / build suffix: "2.7.0-beta.1" → "2.7.0".
        let core = v.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? v
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
}
