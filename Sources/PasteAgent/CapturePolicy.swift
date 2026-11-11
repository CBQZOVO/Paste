import Foundation

/// Decisions that depend only on settings — no system APIs, no database.
public enum CapturePolicy {
    /// Compares the lowercased executable file name against the
    /// case-insensitive exclusion list. An empty executable name (source app
    /// unknown) can never match, so capture proceeds.
    public static func shouldCapture(
        paused: Bool,
        excludedApps: [String],
        executableName: String
    ) -> Bool {
        if paused { return false }
        guard !executableName.isEmpty else { return true }
        let exe = executableName.lowercased()
        return !excludedApps.contains { $0.lowercased() == exe }
    }

    /// `clips.created_at` is in milliseconds; retentionDays <= 0 means
    /// "keep forever", so no cutoff is returned. An absurdly large window
    /// must not trap on Int64 overflow — treat it as keep-forever too.
    public static func retentionCutoff(nowMs: Int64, days: Int64) -> Int64? {
        guard days > 0 else { return nil }
        let (windowMs, overflow) = days.multipliedReportingOverflow(by: 86_400_000)
        if overflow { return nil }
        return nowMs - windowMs
    }
}
