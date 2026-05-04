# Refinement Plan - Velora AIManager

## 1. Concurrent Optimization
Refactor `fixLibraryIssues` and its helpers (`enrichGenres`, `enrichAlbumMetadata`, etc.) to use `withTaskGroup` where appropriate. 
- Use a `concurrencyLimit` (e.g., 3-5) to avoid rate limiting from Gemini/Discogs.
- Implement thread-safe progress tracking using an `actor` or by returning counts from the group.

## 2. Robust Audit Result Handling
Ensure `AuditResult` accurately reflects the count of issues found.
Update `runLibraryAudit` to be more comprehensive.

## 3. Implementation Details
- Move `IssueType` and `AuditResult` to a dedicated `AIModels.swift` or keep them top-level but ensure they are well-structured.
- Ensure `AIManager` uses `AppLogger` for all major transitions.
- Fix the `solvedCount` thread-safety issue mentioned in the plan.

## 4. Specific Code Changes
- In `enrichGenres`, use `TaskGroup` with a semaphore or simple limit.
- Ensure `isProcessing` is handled correctly across concurrent tasks.
