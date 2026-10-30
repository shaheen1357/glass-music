import Foundation
import UIKit

/// Downloads you ask for run in a background URLSession, so they keep going when you
/// leave the app. iOS cancels them only on a force-quit. Each task is described
/// "<server id>\t<file name>". On finishing, the file is moved into the downloads
/// folder inside the callback itself, because iOS deletes the temporary file as soon
/// as it returns. Badges and rings read state back from disk via SubsonicSync, so a
/// download that finished while the app was suspended shows up correctly next time.
///
/// Background sessions don't support the async/await download calls, so this is
/// delegate-based. Whole collections are queued while the app is in the foreground:
/// tasks created from the background are treated as discretionary and can be held.
final class BackgroundDownloads: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloads()
    static let identifier = "com.local.music.downloads"

    /// Handed over by the app delegate when iOS wakes the app for finished downloads.
    var backgroundCompletion: (() -> Void)?
    /// Fraction downloaded for a server id, on the main actor.
    var onProgress: (@MainActor (String, Double) -> Void)?
    /// A task ended: server id, whether the file landed, whether it was cancelled, bytes.
    var onFinished: (@MainActor (String, Bool, Bool, Int64) -> Void)?

    private var lastReported: [String: Double] = [:]   // touched on the delegate queue only

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = true          // each request decides (Wi-Fi only by default)
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// Reconnect to tasks from a previous launch. Call once at startup.
    func start() { _ = session }

    func enqueue(id: String, fileName: String, url: URL, allowCellular: Bool) {
        var r = URLRequest(url: url)
        r.allowsCellularAccess = allowCellular  // false: the task waits for Wi-Fi
        let t = session.downloadTask(with: r)
        t.taskDescription = "\(id)\t\(fileName)"
        t.resume()
    }

    /// Server ids with a task still queued or running.
    func activeIDs() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }
            .compactMap { Self.parse($0)?.id })
    }

    func cancel(ids: Set<String>) {
        session.getAllTasks { tasks in
            for t in tasks where ids.contains(Self.parse(t)?.id ?? "") { t.cancel() }
        }
    }

    func cancelAll() { session.getAllTasks { $0.forEach { $0.cancel() } } }

    private static func parse(_ t: URLSessionTask) -> (id: String, fileName: String)? {
        let parts = (t.taskDescription ?? "").split(separator: "\t", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let info = Self.parse(downloadTask), totalBytesExpectedToWrite > 0 else { return }
        let f = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard f - (lastReported[info.id] ?? -1) >= 0.02 || f >= 1 else { return }
        lastReported[info.id] = f
        Task { @MainActor in self.onProgress?(info.id, f) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let info = Self.parse(downloadTask) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return                              // not moved: reported as a failure below
        }
        let fm = FileManager.default
        let dest = SubsonicCache.downloadsDir.appendingPathComponent(info.fileName)
        try? fm.removeItem(at: dest)
        guard (try? fm.moveItem(at: location, to: dest)) != nil else { return }
        SubsonicCache.link(SubsonicCache.dir.appendingPathComponent(info.fileName))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let info = Self.parse(task) else { return }
        lastReported[info.id] = nil
        let landed = SubsonicCache.isDownloaded(SubsonicCache.dir.appendingPathComponent(info.fileName))
        let cancelled = (error as? URLError)?.code == .cancelled
        let bytes = task.countOfBytesReceived
        Task { @MainActor in self.onFinished?(info.id, landed, cancelled, bytes) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

/// Lets iOS hand finished background downloads to the app, waking it if needed.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloads.identifier else { completionHandler(); return }
        BackgroundDownloads.shared.backgroundCompletion = completionHandler
        BackgroundDownloads.shared.start()
    }
}
