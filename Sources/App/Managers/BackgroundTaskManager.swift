import Foundation
import BackgroundTasks
import UIKit

@MainActor
final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    
    private let auditTaskId = "com.velora.library.audit"
    private let metadataTaskId = "com.velora.library.metadata"
    
    func registerTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: auditTaskId, using: nil) { task in
            self.handleLibraryAudit(task: task as! BGProcessingTask)
        }
        
        BGTaskScheduler.shared.register(forTaskWithIdentifier: metadataTaskId, using: nil) { task in
            self.handleMetadataSync(task: task as! BGAppRefreshTask)
        }
    }
    
    func scheduleTasks() {
        scheduleLibraryAudit()
        scheduleMetadataSync()
    }
    
    private func scheduleLibraryAudit() {
        let request = BGProcessingTaskRequest(identifier: auditTaskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true // Only audit when charging to save battery
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60) // Once a day
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLogger.shared.log("BGTaskManager: Could not schedule library audit: \(error)", level: .error)
        }
    }
    
    private func scheduleMetadataSync() {
        let request = BGAppRefreshTaskRequest(identifier: metadataTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60) // Every 4 hours
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLogger.shared.log("BGTaskManager: Could not schedule metadata sync: \(error)", level: .error)
        }
    }
    
    private func handleLibraryAudit(task: BGProcessingTask) {
        scheduleLibraryAudit() // Reschedule for next time
        
        task.expirationHandler = {
            SyncManager.shared.stopAudit()
        }
        
        Task {
            let success = await SyncManager.shared.startDeepAudit()
            task.setTaskCompleted(success: success)
        }
    }
    
    private func handleMetadataSync(task: BGAppRefreshTask) {
        scheduleMetadataSync() // Reschedule
        
        task.expirationHandler = {
            SyncManager.shared.stopMetadataSync()
        }
        
        Task {
            let success = await SyncManager.shared.startMetadataSync()
            task.setTaskCompleted(success: success)
        }
    }
}
