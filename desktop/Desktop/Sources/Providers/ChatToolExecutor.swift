import AppKit
import Foundation
import GRDB

/// Executes tool calls from Gemini and returns results
/// Tools: execute_sql (read/write SQL on omi.db), semantic_search (vector similarity)
@MainActor
class ChatToolExecutor {

  // MARK: - Onboarding State

  /// Set by OnboardingChatView before starting the chat
  static var onboardingAppState: AppState?
  /// Called when AI invokes complete_onboarding
  static var onCompleteOnboarding: (() -> Void)?
  /// Called when AI invokes ask_followup — delivers quick-reply options to the UI
  static var onQuickReplyOptions: ((_ options: [String]) -> Void)?
  /// Called when AI invokes ask_followup — delivers the question text to the UI
  static var onQuickReplyQuestion: ((_ question: String) -> Void)?
  /// Called when AI invokes save_knowledge_graph — notifies the graph view to update
  static var onKnowledgeGraphUpdated: (() -> Void)?
  /// Called when scan_files completes — used to kick off parallel exploration
  static var onScanFilesCompleted: ((_ fileCount: Int) -> Void)?
  /// Called when request_permission returns "pending" — used to trigger the permission help timer
  static var onPermissionPending: ((_ permissionType: String) -> Void)?

  /// Email/calendar insights from background reading (set by OnboardingChatView)
  static var emailInsightsText: String?
  static var calendarInsightsText: String?

  private static var fileScanFileCount = 0
  private static var followupContinuation: CheckedContinuation<String, Never>?

  static func resumeFollowup(with reply: String) {
    followupContinuation?.resume(returning: reply)
    followupContinuation = nil
  }

  /// Execute a tool call and return the result as a string
  static func execute(_ toolCall: ToolCall) async -> String {
    log("Executing tool: \(toolCall.name) with args: \(toolCall.arguments)")

    switch toolCall.name {
    case "execute_sql":
      return await executeSQL(toolCall.arguments)

    case "semantic_search":
      return await executeSemanticSearch(toolCall.arguments)

    case "get_daily_recap":
      return await executeDailyRecap(toolCall.arguments)

    case "search_tasks":
      return await executeSearchTasks(toolCall.arguments)

    case "complete_task":
      return await executeCompleteTask(toolCall.arguments)

    case "delete_task":
      return await executeDeleteTask(toolCall.arguments)

    // Onboarding tools
    case "request_permission":
      let result = await executeRequestPermission(toolCall.arguments)
      let permType = toolCall.arguments["type"] as? String ?? "unknown"
      let granted = result.contains("granted")
      AnalyticsManager.shared.onboardingChatToolUsed(
        tool: "request_permission",
        properties: ["permission": permType, "result": granted ? "granted" : "pending"])
      if !granted {
        DispatchQueue.main.async { onPermissionPending?(permType) }
      }
      return result

    case "check_permission_status":
      let result = await executeCheckPermissionStatus(toolCall.arguments)
      AnalyticsManager.shared.onboardingChatToolUsed(tool: "check_permission_status")
      return result

    case "scan_files", "start_file_scan":
      AnalyticsManager.shared.onboardingChatToolUsed(tool: "scan_files")
      return await executeScanFiles(toolCall.arguments)

    case "get_file_scan_results":
      return await executeScanFiles(toolCall.arguments)

    case "set_user_preferences":
      let result = await executeSetUserPreferences(toolCall.arguments)
      var props: [String: Any] = [:]
      if let name = toolCall.arguments["name"] as? String {
        props["name_changed"] = true
        props["name"] = name
      }
      if let lang = toolCall.arguments["language"] as? String { props["language"] = lang }
      AnalyticsManager.shared.onboardingChatToolUsed(
        tool: "set_user_preferences", properties: props)
      return result

    case "ask_followup":
      let result = await executeAskFollowup(toolCall.arguments)
      let question = toolCall.arguments["question"] as? String ?? ""
      let optionCount = (toolCall.arguments["options"] as? [String])?.count ?? 0
      AnalyticsManager.shared.onboardingChatToolUsed(
        tool: "ask_followup",
        properties: ["question_length": question.count, "option_count": optionCount])
      return result

    case "complete_onboarding":
      if !OnboardingChatPersistence.isGoalCompleted {
        return
          "ERROR: Cannot complete onboarding yet. The user has NOT set their monthly goal. You MUST call ask_followup to ask about their top goal this month BEFORE calling complete_onboarding. Call get_email_insights first for context, then ask the goal question."
      }
      let result = await executeCompleteOnboarding(toolCall.arguments)
      AnalyticsManager.shared.onboardingChatToolUsed(tool: "complete_onboarding")
      return result

    case "save_knowledge_graph":
      let result = await executeSaveKnowledgeGraph(toolCall.arguments)
      let nodeCount = (toolCall.arguments["nodes"] as? [[String: Any]])?.count ?? 0
      let edgeCount = (toolCall.arguments["edges"] as? [[String: Any]])?.count ?? 0
      AnalyticsManager.shared.onboardingChatToolUsed(
        tool: "save_knowledge_graph", properties: ["nodes": nodeCount, "edges": edgeCount])
      return result

    case "get_email_insights":
      let result = executeGetEmailInsights()
      AnalyticsManager.shared.onboardingChatToolUsed(
        tool: "get_email_insights",
        properties: [
          "has_email": emailInsightsText != nil, "has_calendar": calendarInsightsText != nil,
        ])
      return result

    case "capture_screen":
      return await executeCaptureScreen()

    // Automation tools — desktop (AppleScript/cliclick) + browser (Playwright)
    case "run_applescript":
      return await executeRunAppleScript(toolCall.arguments)

    case "open_app":
      return await executeOpenApp(toolCall.arguments)

    case "open_url":
      return await executeOpenURL(toolCall.arguments)

    case "click_desktop":
      return await executeClickDesktop(toolCall.arguments)

    case "type_desktop":
      return await executeTypeDesktop(toolCall.arguments)

    case "browser_action":
      return await executeBrowserAction(toolCall.arguments)

    case "web_search":
      return await executeWebSearch(toolCall.arguments)

    case "spotify_control":
      return await executeSpotifyControl(toolCall.arguments)

    case "send_whatsapp":
      return await executeSendWhatsApp(toolCall.arguments)

    case "send_imessage":
      return await executeSendIMessage(toolCall.arguments)

    case "calendar_action":
      return await executeCalendarAction(toolCall.arguments)

    case "filesystem_action":
      return await executeFilesystemAction(toolCall.arguments)

    case "run_shortcut":
      return await executeRunShortcut(toolCall.arguments)

    case "send_email":
      return await executeSendEmail(toolCall.arguments)

    case "focus_mode":
      return await executeFocusMode(toolCall.arguments)

    // Backend RAG tools — call Python backend /v1/tools/* endpoints
    case "get_conversations":
      return await executeBackendTool(toolCall)
    case "search_conversations":
      return await executeBackendTool(toolCall)
    case "get_memories":
      return await executeBackendTool(toolCall)
    case "search_memories":
      return await executeBackendTool(toolCall)
    case "get_action_items":
      return await executeBackendTool(toolCall)
    case "create_action_item":
      return await executeBackendTool(toolCall)
    case "update_action_item":
      return await executeBackendTool(toolCall)

    // Google integrations — via backend Railway
    case "gmail_read":
      return await executeBackendTool(toolCall)

    case "gmail_send":
      return await executeBackendTool(toolCall)

    case "google_calendar_read":
      return await executeBackendTool(toolCall)

    case "google_calendar_action":
      return await executeBackendTool(toolCall)

    default:
      return "Unknown tool: \(toolCall.name)"
    }
  }

  /// Execute multiple tool calls and return results keyed by tool name
  static func executeAll(_ toolCalls: [ToolCall]) async -> [String: String] {
    var results: [String: String] = [:]

    for call in toolCalls {
      results[call.name] = await execute(call)
    }

    return results
  }

  // MARK: - Screen Capture

  /// Capture the current screen and return the file path
  private static func executeCaptureScreen() async -> String {
    guard CGPreflightScreenCaptureAccess() else {
      return "Error: Screen recording permission not granted. Ask the user to enable it in System Settings > Privacy & Security > Screen & System Audio Recording."
    }
    guard let fileURL = ScreenCaptureManager.captureScreen() else {
      return "Error: Failed to capture screen"
    }
    return fileURL.path
  }

  // MARK: - SQL Execution

  /// Blocked SQL keywords that are never allowed
  private static let blockedKeywords: Set<String> = [
    "DROP", "ALTER", "CREATE", "PRAGMA", "ATTACH", "DETACH", "VACUUM",
  ]

  /// Execute a SQL query on omi.db
  private static func executeSQL(_ args: [String: Any]) async -> String {
    guard let query = args["query"] as? String, !query.isEmpty else {
      return "Error: query is required"
    }

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let upper = trimmed.uppercased()

    // Block dangerous keywords
    for keyword in blockedKeywords {
      // Match keyword at word boundary (start of string or after whitespace/punctuation)
      if upper.range(of: "\\b\(keyword)\\b", options: .regularExpression) != nil {
        return "Error: \(keyword) statements are not allowed"
      }
    }

    // Block multi-statement queries (semicolon followed by another statement)
    let statements = trimmed.components(separatedBy: ";")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if statements.count > 1 {
      return "Error: multi-statement queries are not allowed. Send one statement at a time."
    }

    // Determine query type
    let isSelect = upper.hasPrefix("SELECT") || upper.hasPrefix("WITH")
    let isInsert = upper.hasPrefix("INSERT")
    let isUpdate = upper.hasPrefix("UPDATE")
    let isDelete = upper.hasPrefix("DELETE")

    // Block UPDATE/DELETE without WHERE
    if (isUpdate || isDelete) && !upper.contains("WHERE") {
      return "Error: \(isUpdate ? "UPDATE" : "DELETE") without WHERE clause is not allowed"
    }

    // Get database queue
    guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
      return "Error: database not available"
    }

    do {
      if isSelect {
        return try await executeSelectQuery(trimmed, upper: upper, dbQueue: dbQueue)
      } else if isInsert || isUpdate || isDelete {
        return try await executeWriteQuery(trimmed, dbQueue: dbQueue)
      } else {
        return "Error: only SELECT, INSERT, UPDATE, DELETE statements are allowed"
      }
    } catch {
      logError("Tool execute_sql failed", error: error)
      return "SQL Error: \(error.localizedDescription)\nFailed query: \(trimmed)"
    }
  }

  /// Execute a SELECT query and format results as text
  private static func executeSelectQuery(_ query: String, upper: String, dbQueue: DatabasePool)
    async throws -> String
  {
    // Auto-append LIMIT 200 if no LIMIT clause
    var finalQuery = query
    if !upper.contains("LIMIT") {
      // Remove trailing semicolon if present
      if finalQuery.hasSuffix(";") {
        finalQuery = String(finalQuery.dropLast())
      }
      finalQuery += " LIMIT 200"
    }

    let query = finalQuery
    let rows = try await dbQueue.read { db in
      try Row.fetchAll(db, sql: query)
    }

    if rows.isEmpty {
      return "No results"
    }

    // Get column names from first row
    let columns = Array(rows[0].columnNames)
    var lines: [String] = []

    // Header
    lines.append(columns.joined(separator: " | "))
    lines.append(String(repeating: "-", count: min(columns.count * 20, 120)))

    // Rows (max 200) — Row is RandomAccessCollection of (String, DatabaseValue)
    for row in rows.prefix(200) {
      let values = row.map { (_, dbValue) -> String in
        let value: String
        switch dbValue.storage {
        case .null:
          value = "NULL"
        case .int64(let i):
          value = String(i)
        case .double(let d):
          value = String(d)
        case .string(let s):
          value = s
        case .blob(let data):
          value = "<\(data.count) bytes>"
        }
        // Truncate long cell values
        if value.count > 500 {
          return String(value.prefix(500)) + "..."
        }
        return value
      }
      lines.append(values.joined(separator: " | "))
    }

    lines.append("\n\(rows.count) row(s)")
    log("Tool execute_sql returned \(rows.count) rows")
    return lines.joined(separator: "\n")
  }

  /// Execute a write (INSERT/UPDATE/DELETE) query
  private static func executeWriteQuery(_ query: String, dbQueue: DatabasePool) async throws
    -> String
  {
    let changes = try await dbQueue.write { db -> Int in
      try db.execute(sql: query)
      return db.changesCount
    }

    log("Tool execute_sql write: \(changes) row(s) affected")

    // If the query modified the action_items table, refresh TasksStore from local cache
    if changes > 0 {
      let upper = query.uppercased()
      if upper.contains("ACTION_ITEMS") {
        log("Tool execute_sql: action_items modified, refreshing TasksStore")
        await TasksStore.shared.reloadFromLocalCache()
        // Sync newly inserted action items to the backend (Firestore)
        if upper.contains("INSERT") {
          await TasksStore.shared.retryUnsyncedItems(includeRecent: true)
        }
      }
    }

    return "OK: \(changes) row(s) affected"
  }

  // MARK: - Daily Recap

  /// Get a pre-formatted daily activity recap
  private static func executeDailyRecap(_ args: [String: Any]) async -> String {
    let daysAgo = max(0, (args["days_ago"] as? Int) ?? 1)
    let dateLabel = daysAgo == 0 ? "Today" : daysAgo == 1 ? "Yesterday" : "Past \(daysAgo) days"

    guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
      return "Error: database not available"
    }

    // For today (daysAgo=0), upper bound is now; for past days, upper bound is start of today
    let upperBound =
      daysAgo == 0
      ? "datetime('now', 'localtime')"
      : "datetime('now', 'start of day', 'localtime')"

    do {
      return try await dbQueue.read { db in
        // Q1: App usage
        let apps = try Row.fetchAll(
          db,
          sql: """
            SELECT appName, COUNT(*) as screenshots, ROUND(COUNT(*) * 10.0 / 60, 1) as minutes,
                MIN(time(timestamp, 'localtime')) as first_seen, MAX(time(timestamp, 'localtime')) as last_seen
            FROM screenshots
            WHERE timestamp >= datetime('now', 'start of day', '-\(daysAgo) day', 'localtime')
                AND timestamp < \(upperBound)
                AND appName IS NOT NULL AND appName != ''
            GROUP BY appName ORDER BY screenshots DESC
            """)

        // Q2: Conversations
        let convos = try Row.fetchAll(
          db,
          sql: """
            SELECT title, overview, emoji, category, startedAt, finishedAt,
                ROUND((julianday(finishedAt) - julianday(startedAt)) * 1440, 1) as duration_min
            FROM transcription_sessions
            WHERE startedAt >= datetime('now', 'start of day', '-\(daysAgo) day', 'localtime')
                AND startedAt < \(upperBound)
                AND deleted = 0 AND discarded = 0
            ORDER BY startedAt DESC
            """)

        // Q3: Action items
        let tasks = try Row.fetchAll(
          db,
          sql: """
            SELECT description, completed, priority, createdAt FROM action_items
            WHERE createdAt >= datetime('now', 'start of day', '-\(daysAgo) day', 'localtime')
                AND createdAt < \(upperBound)
                AND deleted = 0
            ORDER BY createdAt DESC
            """)

        // Q4: Focus sessions
        let focusSessions = try Row.fetchAll(
          db,
          sql: """
            SELECT status, appOrSite, description, durationSeconds FROM focus_sessions
            WHERE createdAt >= datetime('now', 'start of day', '-\(daysAgo) day', 'localtime')
                AND createdAt < \(upperBound)
            ORDER BY createdAt DESC
            """)

        // Q5: Memories created
        let memories = try Row.fetchAll(
          db,
          sql: """
            SELECT content, category, source FROM memories
            WHERE createdAt >= datetime('now', 'start of day', '-\(daysAgo) day', 'localtime')
                AND createdAt < \(upperBound)
                AND deleted = 0
            ORDER BY createdAt DESC
            """)

        // Q6: Observations (screen context summaries)
        let observations = try Row.fetchAll(
          db,
          sql: """
            SELECT appName, currentActivity, contextSummary FROM observations
            WHERE createdAt >= datetime('now', 'start of day', '-\(daysAgo) day', 'localtime')
                AND createdAt < \(upperBound)
            ORDER BY createdAt DESC
            LIMIT 20
            """)

        // Format compact markdown
        var out = "# \(dateLabel) Recap\n\n"

        out += "## Apps (\(apps.count) apps)\n"
        if apps.isEmpty {
          out += "No screen activity recorded.\n"
        } else {
          for app in apps.prefix(20) {
            let name = app["appName"] as? String ?? "Unknown"
            let minutes = app["minutes"] as? Double ?? 0
            let screenshots = app["screenshots"] as? Int ?? 0
            let firstSeen = app["first_seen"] as? String ?? ""
            let lastSeen = app["last_seen"] as? String ?? ""
            out +=
              "- **\(name)**: \(minutes) min (\(screenshots) captures, \(firstSeen)–\(lastSeen))\n"
          }
          if apps.count > 20 { out += "- ...and \(apps.count - 20) more apps\n" }
        }

        out += "\n## Conversations (\(convos.count))\n"
        if convos.isEmpty {
          out += "No conversations recorded.\n"
        } else {
          for convo in convos {
            let title = convo["title"] as? String ?? "Untitled"
            let overview = convo["overview"] as? String ?? "No summary"
            let emoji = convo["emoji"] as? String ?? ""
            let durMin = convo["duration_min"] as? Double ?? 0
            let dur = durMin > 0 ? " (\(durMin) min)" : ""
            out += "- \(emoji) **\(title)**\(dur): \(overview)\n"
          }
        }

        out += "\n## Tasks (\(tasks.count))\n"
        if tasks.isEmpty {
          out += "No tasks created.\n"
        } else {
          for task in tasks {
            let desc = task["description"] as? String ?? ""
            let completed = (task["completed"] as? Int ?? 0) == 1
            let priority = task["priority"] as? String ?? ""
            let check = completed ? "[x]" : "[ ]"
            let pri = priority.isEmpty ? "" : " (\(priority))"
            out += "- \(check) \(desc)\(pri)\n"
          }
        }

        // Focus sessions
        let focused = focusSessions.filter { ($0["status"] as? String) == "focused" }
        let distracted = focusSessions.filter { ($0["status"] as? String) == "distracted" }
        if !focusSessions.isEmpty {
          out += "\n## Focus (\(focused.count) focused, \(distracted.count) distracted)\n"
          for session in focusSessions.prefix(10) {
            let status = session["status"] as? String ?? ""
            let app = session["appOrSite"] as? String ?? ""
            let desc = session["description"] as? String ?? ""
            let dur = session["durationSeconds"] as? Int ?? 0
            let durStr = dur > 0 ? " (\(dur / 60)m)" : ""
            let icon = status == "focused" ? "+" : "-"
            out += "- \(icon) \(app)\(durStr): \(desc)\n"
          }
          if focusSessions.count > 10 {
            out += "- ...and \(focusSessions.count - 10) more sessions\n"
          }
        }

        // Memories
        if !memories.isEmpty {
          out += "\n## Memories Learned (\(memories.count))\n"
          for memory in memories.prefix(10) {
            let content = memory["content"] as? String ?? ""
            let category = memory["category"] as? String ?? ""
            let catStr = category.isEmpty ? "" : " [\(category)]"
            out += "- \(content)\(catStr)\n"
          }
          if memories.count > 10 { out += "- ...and \(memories.count - 10) more\n" }
        }

        // Observations (context summaries)
        if !observations.isEmpty {
          out += "\n## Screen Context (\(observations.count) observations)\n"
          for obs in observations.prefix(10) {
            let app = obs["appName"] as? String ?? ""
            let activity = obs["currentActivity"] as? String ?? ""
            out += "- \(app): \(activity)\n"
          }
          if observations.count > 10 {
            out += "- ...and \(observations.count - 10) more observations\n"
          }
        }

        log(
          "Tool get_daily_recap: \(apps.count) apps, \(convos.count) convos, \(tasks.count) tasks, \(focusSessions.count) focus, \(memories.count) memories, \(observations.count) observations"
        )
        return out
      }
    } catch {
      logError("Tool get_daily_recap failed", error: error)
      return "Error: \(error.localizedDescription)"
    }
  }

  // MARK: - Semantic Search

  /// Search screenshots using vector similarity
  private static func executeSemanticSearch(_ args: [String: Any]) async -> String {
    guard let query = args["query"] as? String, !query.isEmpty else {
      return "Error: query is required"
    }

    let days = (args["days"] as? Int) ?? 7
    let appFilter = args["app_filter"] as? String

    let calendar = Calendar.current
    let endDate = Date()
    let startDate = calendar.date(byAdding: .day, value: -days, to: endDate) ?? endDate

    do {
      let vectorResults = try await OCREmbeddingService.shared.searchSimilar(
        query: query,
        startDate: startDate,
        endDate: endDate,
        appFilter: appFilter,
        topK: 20
      )

      log("Tool semantic_search: vector returned \(vectorResults.count) results")

      // Filter by similarity threshold and fetch screenshot details
      let dateFormatter = DateFormatter()
      dateFormatter.dateStyle = .medium
      dateFormatter.timeStyle = .short

      var lines: [String] = []
      var count = 0

      for result in vectorResults where result.similarity > 0.3 {
        guard
          let screenshot = try? await RewindDatabase.shared.getScreenshot(id: result.screenshotId)
        else {
          continue
        }

        count += 1
        let dateStr = dateFormatter.string(from: screenshot.timestamp)
        let windowTitle = screenshot.windowTitle ?? ""
        let titlePart = windowTitle.isEmpty ? "" : " - \(windowTitle)"
        lines.append(
          "\n\(count). [\(dateStr)] \(screenshot.appName)\(titlePart) (similarity: \(String(format: "%.2f", result.similarity)))"
        )

        // Include OCR text preview (truncated)
        if let ocrText = screenshot.ocrText, !ocrText.isEmpty {
          let preview = String(ocrText.prefix(300))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
          lines.append("   Content: \(preview)")
        }

        if count >= 15 { break }
      }

      if lines.isEmpty {
        return "No screenshots found matching \"\(query)\" in the last \(days) day(s)."
      }

      lines.insert("Found \(count) screenshot(s) matching \"\(query)\":", at: 0)

      log("Tool semantic_search returned \(count) results")
      return lines.joined(separator: "\n")

    } catch {
      logError("Tool semantic_search failed", error: error)
      return "Failed to search: \(error.localizedDescription)"
    }
  }

  // MARK: - Task Search

  /// Vector similarity search on action_items + staged_tasks using EmbeddingService
  private static func executeSearchTasks(_ args: [String: Any]) async -> String {
    guard let query = args["query"] as? String, !query.isEmpty else {
      return "Error: query is required"
    }

    let includeCompleted = (args["include_completed"] as? Bool) ?? false

    do {
      // Ensure index is loaded
      if !(await EmbeddingService.shared.indexLoaded) {
        await EmbeddingService.shared.loadIndex()
      }

      // Verify index actually has entries (loadIndex swallows errors)
      if !(await EmbeddingService.shared.indexLoaded) {
        return "Error: embedding index failed to load. Task vector search is unavailable."
      }

      // Embed the query text
      // EmbeddingService uses a shared Int64-keyed index for both action_items and staged_tasks.
      // loadIndex() loads action_items first, then staged_tasks — so for colliding IDs, the
      // staged_task embedding overwrites the action_item one. We check staged_tasks first to
      // match the actual embedding owner, then fall back to action_items for non-colliding IDs.
      let queryEmbedding = try await EmbeddingService.shared.embed(
        text: query, taskType: "RETRIEVAL_QUERY")

      // Search the in-memory index (action_items + staged_tasks share this index)
      let vectorResults = await EmbeddingService.shared.searchSimilar(
        query: queryEmbedding, topK: 15)

      var lines: [String] = []
      var count = 0

      for result in vectorResults where result.similarity > 0.3 {
        // Try staged_tasks first (their embeddings overwrite action_items on ID collision),
        // then fall back to action_items
        if let staged = try? await StagedTaskStorage.shared.getStagedTask(id: result.id) {
          if staged.deleted { continue }
          if !includeCompleted && staged.completed { continue }
          count += 1
          let check = staged.completed ? "[x]" : "[ ]"
          let sim = String(format: "%.2f", result.similarity)
          lines.append(
            "\(count). \(check) \(staged.description) (similarity: \(sim), id: \(result.id), source: staged_tasks)"
          )
        } else if let record = try? await ActionItemStorage.shared.getActionItem(id: result.id) {
          if record.deleted { continue }
          if !includeCompleted && record.completed { continue }
          count += 1
          let check = record.completed ? "[x]" : "[ ]"
          let pri = (record.priority ?? "").isEmpty ? "" : " [\(record.priority!)]"
          let sim = String(format: "%.2f", result.similarity)
          lines.append(
            "\(count). \(check) \(record.description)\(pri) (similarity: \(sim), id: \(result.id), source: action_items)"
          )
        }

        if count >= 10 { break }
      }

      if lines.isEmpty {
        return "No tasks found matching \"\(query)\". The embedding index may not be loaded yet, or no tasks have embeddings."
      }

      lines.insert("Found \(count) task(s) matching \"\(query)\":", at: 0)
      log("Tool search_tasks returned \(count) results")
      return lines.joined(separator: "\n")

    } catch {
      logError("Tool search_tasks failed", error: error)
      return "Error: \(error.localizedDescription)"
    }
  }

  // MARK: - Task Tools

  /// Toggle a task's completion status via TasksStore (handles local + API sync)
  private static func executeCompleteTask(_ args: [String: Any]) async -> String {
    guard let taskId = args["task_id"] as? String, !taskId.isEmpty else {
      return "Error: task_id is required"
    }

    do {
      guard let task = try await ActionItemStorage.shared.getLocalActionItem(byBackendId: taskId)
      else {
        return "Error: task not found with id '\(taskId)'"
      }

      if task.deleted == true {
        return "Error: task '\(task.description)' has been deleted"
      }

      let wasCompleted = task.completed
      await TasksStore.shared.toggleTask(task)

      let newState = wasCompleted ? "incomplete" : "completed"
      log("Tool complete_task: toggled '\(task.description)' to \(newState)")
      return "OK: task '\(task.description)' marked as \(newState)"
    } catch {
      logError("Tool complete_task failed", error: error)
      return "Error: \(error.localizedDescription)"
    }
  }

  /// Delete a task via TasksStore (handles local + API sync)
  private static func executeDeleteTask(_ args: [String: Any]) async -> String {
    guard let taskId = args["task_id"] as? String, !taskId.isEmpty else {
      return "Error: task_id is required"
    }

    do {
      guard let task = try await ActionItemStorage.shared.getLocalActionItem(byBackendId: taskId)
      else {
        return "Error: task not found with id '\(taskId)'"
      }

      if task.deleted == true {
        return "Error: task '\(task.description)' is already deleted"
      }

      await TasksStore.shared.deleteTask(task)

      log("Tool delete_task: deleted '\(task.description)'")
      return "OK: task '\(task.description)' deleted"
    } catch {
      logError("Tool delete_task failed", error: error)
      return "Error: \(error.localizedDescription)"
    }
  }

  // MARK: - Onboarding Tools

  /// Request a specific macOS permission
  private static func executeRequestPermission(_ args: [String: Any]) async -> String {
    guard let type = args["type"] as? String else {
      return
        "Error: 'type' parameter is required (screen_recording, microphone, accessibility, automation)"
    }

    guard let appState = onboardingAppState else {
      return "Error: onboarding not active"
    }

    AnalyticsManager.shared.permissionRequested(permission: type)

    switch type {
    case "screen_recording":
      appState.screenRecordingGrantAttempts += 1
      appState.triggerScreenRecordingPermission()
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
      {
        NSWorkspace.shared.open(url)
      }
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      appState.checkScreenRecordingPermission()
      try? await Task.sleep(nanoseconds: 500_000_000)
      if appState.hasScreenRecordingPermission {
        return "granted"
      } else {
        return
          "pending - user needs to toggle Screen Recording for Jarvis in System Settings, then quit and reopen the app"
      }

    case "microphone":
      appState.requestMicrophonePermission()
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      if appState.hasMicrophonePermission {
        return "granted"
      } else {
        return "pending - user needs to allow microphone access in the system dialog"
      }

    case "accessibility":
      appState.triggerAccessibilityPermission()
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      appState.checkAccessibilityPermission()
      try? await Task.sleep(nanoseconds: 500_000_000)
      if appState.hasAccessibilityPermission {
        return "granted"
      } else {
        return "pending - user needs to toggle Accessibility for Jarvis in System Settings"
      }

    case "automation":
      appState.triggerAutomationPermission()
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      appState.checkAutomationPermission()
      try? await Task.sleep(nanoseconds: 500_000_000)
      if appState.hasAutomationPermission {
        return "granted"
      } else {
        return "pending - user needs to toggle Automation for Jarvis in System Settings"
      }

    case "full_disk_access":
      // Open System Settings to Full Disk Access pane
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
      {
        NSWorkspace.shared.open(url)
      }
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      appState.checkFullDiskAccess()
      try? await Task.sleep(nanoseconds: 500_000_000)
      if appState.hasFullDiskAccess {
        return "granted"
      } else {
        return
          "pending - user needs to toggle Full Disk Access for Jarvis in System Settings > Privacy & Security > Full Disk Access"
      }

    default:
      return
        "Error: unknown permission type '\(type)'. Valid types: screen_recording, microphone, accessibility, automation, full_disk_access"
    }
  }

  /// Check status of all macOS permissions
  private static func executeCheckPermissionStatus(_ args: [String: Any]) async -> String {
    guard let appState = onboardingAppState else {
      return "Error: onboarding not active"
    }

    appState.checkAllPermissions()
    try? await Task.sleep(nanoseconds: 500_000_000)

    let statuses: [String: String] = [
      "screen_recording": appState.hasScreenRecordingPermission ? "granted" : "not_granted",
      "microphone": appState.hasMicrophonePermission ? "granted" : "not_granted",
      "accessibility": appState.hasAccessibilityPermission ? "granted" : "not_granted",
      "automation": appState.hasAutomationPermission ? "granted" : "not_granted",
      "full_disk_access": appState.hasFullDiskAccess ? "granted" : "not_granted",
    ]

    if let data = try? JSONSerialization.data(withJSONObject: statuses, options: .prettyPrinted),
      let json = String(data: data, encoding: .utf8)
    {
      return json
    }
    return
      "screen_recording: \(statuses["screen_recording"]!), microphone: \(statuses["microphone"]!), accessibility: \(statuses["accessibility"]!), automation: \(statuses["automation"]!)"
  }

  /// Scan files BLOCKING — triggers folder access dialogs, waits for scan, returns results
  private static func executeScanFiles(_ args: [String: Any]) async -> String {
    let fm = FileManager.default
    let homeDir = fm.homeDirectoryForCurrentUser
    let scanTargets: [(label: String, pathForUser: String, url: URL)] = {
      var targets: [(String, String, URL)] = []

      let homeFolders = ["Downloads", "Documents", "Desktop", "Developer", "Projects"]
      for folder in homeFolders {
        let url = homeDir.appendingPathComponent(folder)
        if fm.fileExists(atPath: url.path) {
          targets.append((folder, "~/\(folder)", url))
        }
      }

      let applicationsURL = URL(fileURLWithPath: "/Applications")
      if fm.fileExists(atPath: applicationsURL.path) {
        targets.append(("Applications", "/Applications", applicationsURL))
      }

      // Apple Notes local stores (container + group container)
      let notesCandidates: [(String, String, URL)] = [
        (
          "Apple Notes (Container)",
          "~/Library/Containers/com.apple.Notes/Data/Library/Notes",
          homeDir.appendingPathComponent("Library/Containers/com.apple.Notes/Data/Library/Notes")
        ),
        (
          "Apple Notes (Group)",
          "~/Library/Group Containers/group.com.apple.notes",
          homeDir.appendingPathComponent("Library/Group Containers/group.com.apple.notes")
        ),
      ]
      for candidate in notesCandidates where fm.fileExists(atPath: candidate.2.path) {
        targets.append(candidate)
      }

      return targets
    }()

    // Pre-check folder access — this triggers macOS TCC dialogs
    var deniedFolders: [String] = []
    var accessibleFolders: [URL] = []
    for target in scanTargets {
      do {
        _ = try fm.contentsOfDirectory(
          at: target.url,
          includingPropertiesForKeys: [.fileSizeKey],
          options: [.skipsHiddenFiles]
        )
        accessibleFolders.append(target.url)
      } catch {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == 257 {
          // Permission denied — TCC dialog was shown or already denied
          deniedFolders.append(target.pathForUser)
        } else {
          // Other error (e.g. folder doesn't exist) — skip silently
          log("FileIndexer: Pre-check failed for \(target.label): \(error.localizedDescription)")
        }
      }
    }

    // Actually scan accessible folders (blocking)
    let count = await FileIndexerService.shared.scanFolders(accessibleFolders)
    fileScanFileCount = count
    log(
      "Onboarding file scan completed: \(count) files indexed, \(deniedFolders.count) folders denied"
    )

    // Build results from database
    let resultsStr = await getFileScanResultsFromDB()

    var out = resultsStr

    if !deniedFolders.isEmpty {
      out += "\n\n## FOLDER ACCESS DENIED\n"
      out += "The following folders were NOT scanned because the user didn't grant access:\n"
      for folder in deniedFolders {
        out += "- \(folder)\n"
      }
      out +=
        "\nTell the user to click 'Allow' on the macOS dialogs, then call scan_files again to pick up those folders."
    }

    // Notify that scan completed — triggers parallel exploration
    onScanFilesCompleted?(count)

    return out
  }

  /// Get file scan results from the database
  private static func getFileScanResultsFromDB() async -> String {
    guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
      return "Error: database not available"
    }

    do {
      return try await dbQueue.read { db in
        // File type breakdown
        let typeBreakdown = try Row.fetchAll(
          db,
          sql: """
                SELECT fileType, COUNT(*) as count
                FROM indexed_files
                GROUP BY fileType
                ORDER BY count DESC
                LIMIT 10
            """)

        // Project indicators
        let projectIndicators = try Row.fetchAll(
          db,
          sql: """
                SELECT filename, path FROM indexed_files
                WHERE filename IN ('package.json', 'Cargo.toml', 'Podfile', 'go.mod',
                    'requirements.txt', 'Pipfile', 'setup.py', 'pyproject.toml',
                    'build.gradle', 'pom.xml', 'CMakeLists.txt', 'Makefile',
                    '.xcodeproj', '.xcworkspace', 'Package.swift', 'Gemfile',
                    'composer.json', 'mix.exs', 'pubspec.yaml')
                LIMIT 30
            """)

        // Recently modified files
        let recentFiles = try Row.fetchAll(
          db,
          sql: """
                SELECT filename, path, fileType, modifiedAt FROM indexed_files
                ORDER BY modifiedAt DESC
                LIMIT 15
            """)

        // Applications
        let apps = try Row.fetchAll(
          db,
          sql: """
                SELECT filename, path FROM indexed_files
                WHERE folder = '/Applications' AND fileExtension = 'app'
                ORDER BY filename
                LIMIT 30
            """)

        let totalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_files") ?? 0

        var out = "# File Scan Results (\(totalCount) files indexed)\n\n"

        out += "## File Types\n"
        for row in typeBreakdown {
          let type = row["fileType"] as? String ?? "unknown"
          let count = row["count"] as? Int ?? 0
          out += "- \(type): \(count) files\n"
        }

        out += "\n## Project Indicators (build files found)\n"
        if projectIndicators.isEmpty {
          out += "- No project build files found\n"
        } else {
          for row in projectIndicators {
            let filename = row["filename"] as? String ?? ""
            let path = row["path"] as? String ?? ""
            // Extract project directory name
            let dir = (path as NSString).deletingLastPathComponent
            let projectName = (dir as NSString).lastPathComponent
            out += "- \(projectName)/\(filename)\n"
          }
        }

        out += "\n## Recently Modified Files\n"
        for row in recentFiles {
          let filename = row["filename"] as? String ?? ""
          let fileType = row["fileType"] as? String ?? ""
          let modifiedAt = row["modifiedAt"] as? String ?? ""
          out += "- \(filename) (\(fileType)) — modified \(modifiedAt)\n"
        }

        if !apps.isEmpty {
          out += "\n## Installed Applications\n"
          let appNames = apps.compactMap {
            ($0["filename"] as? String)?.replacingOccurrences(of: ".app", with: "")
          }
          out += appNames.joined(separator: ", ")
          out += "\n"
        }

        let taskCandidates = try Row.fetchAll(
          db,
          sql: """
                SELECT description, priority, source
                FROM action_items
                WHERE deleted = 0 AND completed = 0
                ORDER BY
                    CASE priority
                        WHEN 'high' THEN 0
                        WHEN 'medium' THEN 1
                        ELSE 2
                    END,
                    COALESCE(relevanceScore, 999) ASC,
                    createdAt DESC
                LIMIT 8
            """)

        if !taskCandidates.isEmpty {
          out += "\n## Existing Task Candidates\n"
          for row in taskCandidates {
            let description = row["description"] as? String ?? ""
            let priority = row["priority"] as? String ?? "normal"
            let source = row["source"] as? String ?? "unknown"
            out += "- [\(priority)] \(description) (source: \(source))\n"
          }
        }

        log(
          "Tool get_file_scan_results: \(totalCount) files, \(projectIndicators.count) projects, \(apps.count) apps"
        )
        return out
      }
    } catch {
      logError("Tool get_file_scan_results failed", error: error)
      return "Error: \(error.localizedDescription)"
    }
  }

  /// Return email/calendar insights from background reading
  private static func executeGetEmailInsights() -> String {
    var sections: [String] = []

    if let email = emailInsightsText, !email.isEmpty {
      sections.append("## Email Insights\n\(email)")
    }
    if let calendar = calendarInsightsText, !calendar.isEmpty {
      sections.append("## Calendar Insights\n\(calendar)")
    }

    if sections.isEmpty {
      return
        "No email insights available yet. The background reading may still be in progress, or no browser with a Gmail session was found."
    }

    return sections.joined(separator: "\n\n")
  }

  /// Set user preferences (language, name)
  private static func executeSetUserPreferences(_ args: [String: Any]) async -> String {
    var results: [String] = []

    if let language = args["language"] as? String, !language.isEmpty {
      AssistantSettings.shared.transcriptionLanguage = language
      let supportsMulti = AssistantSettings.supportsAutoDetect(language)
      AssistantSettings.shared.transcriptionAutoDetect = supportsMulti
      Task {
        _ = try? await APIClient.shared.updateUserLanguage(language)
      }
      results.append("Language set to \(language)")
    }

    if let name = args["name"] as? String, !name.isEmpty {
      await AuthService.shared.updateGivenName(name)
      results.append("Name updated to \(name)")
    }

    if results.isEmpty {
      return
        "No preferences were changed. Provide 'language' (code like 'en', 'es', 'ja') and/or 'name' (string)."
    }
    return results.joined(separator: ". ") + "."
  }

  // MARK: - Knowledge Graph Tool

  /// Save a knowledge graph extracted by the AI during file exploration
  private static func executeSaveKnowledgeGraph(_ args: [String: Any]) async -> String {
    guard let nodesArray = args["nodes"] as? [[String: Any]] else {
      return "Error: 'nodes' array is required"
    }
    let edgesArray = args["edges"] as? [[String: Any]] ?? []

    let now = Date()
    var nodeRecords: [LocalKGNodeRecord] = []
    var edgeRecords: [LocalKGEdgeRecord] = []

    // Deduplicate nodes by label (case-insensitive)
    var seenLabels: [String: String] = [:]  // lowercase label → nodeId
    var idRemap: [String: String] = [:]  // original id → canonical id

    for node in nodesArray {
      guard let id = node["id"] as? String,
        let label = node["label"] as? String
      else { continue }

      let nodeType = node["node_type"] as? String ?? "concept"
      let aliases = node["aliases"] as? [String] ?? []
      let lowerLabel = label.lowercased()

      if let existingId = seenLabels[lowerLabel] {
        idRemap[id] = existingId
        continue
      }

      seenLabels[lowerLabel] = id
      idRemap[id] = id

      var aliasesJson: String?
      if !aliases.isEmpty, let data = try? JSONEncoder().encode(aliases) {
        aliasesJson = String(data: data, encoding: .utf8)
      }

      nodeRecords.append(
        LocalKGNodeRecord(
          nodeId: id,
          label: label,
          nodeType: nodeType,
          aliasesJson: aliasesJson,
          sourceFileIds: nil,
          createdAt: now,
          updatedAt: now
        ))
    }

    for edge in edgesArray {
      guard let sourceId = edge["source_id"] as? String,
        let targetId = edge["target_id"] as? String,
        let label = edge["label"] as? String
      else { continue }

      let remappedSource = idRemap[sourceId] ?? sourceId
      let remappedTarget = idRemap[targetId] ?? targetId

      // Skip self-referencing edges
      guard remappedSource != remappedTarget else { continue }

      let edgeId =
        "\(remappedSource)_\(remappedTarget)_\(label.lowercased().replacingOccurrences(of: " ", with: "_"))"
      edgeRecords.append(
        LocalKGEdgeRecord(
          edgeId: edgeId,
          sourceNodeId: remappedSource,
          targetNodeId: remappedTarget,
          label: label,
          createdAt: now
        ))
    }

    do {
      try await KnowledgeGraphStorage.shared.mergeGraph(nodes: nodeRecords, edges: edgeRecords)
      log("Local graph built with \(nodeRecords.count) nodes, \(edgeRecords.count) edges")
      DispatchQueue.main.async { onKnowledgeGraphUpdated?() }
      return
        "OK: saved \(nodeRecords.count) nodes and \(edgeRecords.count) edges to local knowledge graph"
    } catch {
      logError("Tool save_knowledge_graph failed", error: error)
      return "Error: \(error.localizedDescription)"
    }
  }

  /// Present a follow-up question with quick-reply options to the user
  private static func executeAskFollowup(_ args: [String: Any]) async -> String {
    guard let question = args["question"] as? String else {
      return "Error: 'question' parameter is required"
    }
    let options = (args["options"] as? [String]) ?? []

    // Notify the UI to render quick-reply buttons
    onQuickReplyOptions?(options)
    onQuickReplyQuestion?(question)

    return "Presented to user: \"\(question)\" with options: \(options.joined(separator: ", "))"
  }

  /// Complete the onboarding process
  private static func executeCompleteOnboarding(_ args: [String: Any]) async -> String {
    guard let appState = onboardingAppState else {
      return "Error: onboarding not active"
    }

    // Log analytics for each permission
    let permissions: [(String, Bool)] = [
      ("screen_recording", appState.hasScreenRecordingPermission),
      ("microphone", appState.hasMicrophonePermission),
      ("accessibility", appState.hasAccessibilityPermission),
      ("automation", appState.hasAutomationPermission),
    ]
    for (name, granted) in permissions {
      if granted {
        AnalyticsManager.shared.permissionGranted(permission: name)
      } else {
        AnalyticsManager.shared.permissionSkipped(permission: name)
      }
    }

    // Mark that the tool was called so the "Continue to App" button shows even after restart
    OnboardingChatPersistence.markToolCompleted()

    // Call the completion callback
    onCompleteOnboarding?()

    // Clean up state
    onboardingAppState = nil
    onCompleteOnboarding = nil
    onQuickReplyOptions = nil
    onQuickReplyQuestion = nil
    onKnowledgeGraphUpdated = nil
    onScanFilesCompleted = nil
    onPermissionPending = nil
    fileScanFileCount = 0

    return "Onboarding completed successfully! The app is now set up."
  }

  // MARK: - Date Validation

  /// Validates an ISO 8601 date string has a timezone offset by parsing it.
  /// Catches format errors (missing timezone, garbage input). Calendar validity
  /// (e.g. Feb 30 -> Mar 1 normalization) is left to the backend's datetime parser.
  static func validateISODate(_ dateStr: String, paramName: String) -> (valid: String?, error: String?) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if formatter.date(from: dateStr) != nil {
      return (dateStr, nil)
    }
    formatter.formatOptions = [.withInternetDateTime]
    if formatter.date(from: dateStr) != nil {
      return (dateStr, nil)
    }
    return (
      nil,
      "Error: \(paramName) must be ISO format with timezone offset (e.g. 2024-01-19T15:00:00-08:00 or 2024-01-19T15:00:00+07:00). Got: \(dateStr)"
    )
  }

  // MARK: - Backend RAG Tools

  private static func executeBackendTool(_ toolCall: ToolCall) async -> String {
    do {
      let api = APIClient.shared
      let args = toolCall.arguments

      // Validate date parameters before sending to backend
      var validatedStartDate: String? = nil
      var validatedEndDate: String? = nil
      if let sd = args["start_date"] as? String {
        let result = validateISODate(sd, paramName: "start_date")
        if let error = result.error { return error }
        validatedStartDate = result.valid
      }
      if let ed = args["end_date"] as? String {
        let result = validateISODate(ed, paramName: "end_date")
        if let error = result.error { return error }
        validatedEndDate = result.valid
      }

      switch toolCall.name {
      case "get_conversations":
        let resp = try await api.toolGetConversations(
          startDate: validatedStartDate,
          endDate: validatedEndDate,
          limit: args["limit"] as? Int ?? 20,
          offset: args["offset"] as? Int ?? 0,
          includeTranscript: args["include_transcript"] as? Bool ?? true
        )
        return resp.resultText

      case "search_conversations":
        guard let query = args["query"] as? String, !query.isEmpty else {
          return "Error: query is required"
        }
        let resp = try await api.toolSearchConversations(
          query: query,
          startDate: validatedStartDate,
          endDate: validatedEndDate,
          limit: args["limit"] as? Int ?? 5,
          includeTranscript: args["include_transcript"] as? Bool ?? true
        )
        return resp.resultText

      case "get_memories":
        let resp = try await api.toolGetMemories(
          limit: args["limit"] as? Int ?? 50,
          offset: args["offset"] as? Int ?? 0,
          startDate: validatedStartDate,
          endDate: validatedEndDate
        )
        return resp.resultText

      case "search_memories":
        guard let query = args["query"] as? String, !query.isEmpty else {
          return "Error: query is required"
        }
        let resp = try await api.toolSearchMemories(
          query: query,
          limit: args["limit"] as? Int ?? 5
        )
        return resp.resultText

      case "get_action_items":
        var validatedDueStart: String? = nil
        var validatedDueEnd: String? = nil
        if let ds = args["due_start_date"] as? String {
          let result = validateISODate(ds, paramName: "due_start_date")
          if let error = result.error { return error }
          validatedDueStart = result.valid
        }
        if let de = args["due_end_date"] as? String {
          let result = validateISODate(de, paramName: "due_end_date")
          if let error = result.error { return error }
          validatedDueEnd = result.valid
        }
        let resp = try await api.toolGetActionItems(
          limit: args["limit"] as? Int ?? 50,
          offset: args["offset"] as? Int ?? 0,
          completed: args["completed"] as? Bool,
          startDate: validatedStartDate,
          endDate: validatedEndDate,
          dueStartDate: validatedDueStart,
          dueEndDate: validatedDueEnd
        )
        return resp.resultText

      case "create_action_item":
        guard let desc = args["description"] as? String, !desc.isEmpty else {
          return "Error: description is required"
        }
        var validatedDueAt: String? = nil
        if let da = args["due_at"] as? String {
          let result = validateISODate(da, paramName: "due_at")
          if let error = result.error { return error }
          validatedDueAt = result.valid
        }
        let resp = try await api.toolCreateActionItem(
          description: desc,
          dueAt: validatedDueAt,
          conversationId: args["conversation_id"] as? String
        )
        return resp.resultText

      case "update_action_item":
        guard let itemId = args["action_item_id"] as? String, !itemId.isEmpty else {
          return "Error: action_item_id is required"
        }
        var validatedUpdateDueAt: String? = nil
        if let da = args["due_at"] as? String {
          let result = validateISODate(da, paramName: "due_at")
          if let error = result.error { return error }
          validatedUpdateDueAt = result.valid
        }
        let resp = try await api.toolUpdateActionItem(
          id: itemId,
          completed: args["completed"] as? Bool,
          description: args["description"] as? String,
          dueAt: validatedUpdateDueAt
        )
        return resp.resultText

      case "gmail_read":
        let resp = try await api.toolGmailRead(
          query: args["query"] as? String,
          maxResults: args["max_results"] as? Int ?? 10,
          label: args["label"] as? String
        )
        return resp.resultText

      case "gmail_send":
        guard let to = args["to"] as? String, !to.isEmpty else { return "Error: 'to' obrigatório" }
        guard let subject = args["subject"] as? String else { return "Error: 'subject' obrigatório" }
        guard let body = args["body"] as? String else { return "Error: 'body' obrigatório" }
        let resp = try await api.toolGmailSend(
          to: to,
          subject: subject,
          body: body,
          replyToMessageId: args["reply_to_message_id"] as? String,
          threadId: args["thread_id"] as? String
        )
        return resp.resultText

      case "google_calendar_read":
        let resp = try await api.toolCalendarGoogleRead(
          startDate: args["start_date"] as? String,
          endDate: args["end_date"] as? String,
          limit: args["limit"] as? Int ?? 10,
          query: args["query"] as? String
        )
        return resp.resultText

      case "google_calendar_action":
        guard let action = args["action"] as? String else { return "Error: 'action' obrigatório (create/update/delete)" }
        let resp = try await api.toolCalendarGoogleAction(
          action: action,
          eventId: args["event_id"] as? String,
          title: args["title"] as? String,
          start: args["start"] as? String,
          end: args["end"] as? String,
          description: args["description"] as? String,
          attendees: args["attendees"] as? [String],
          location: args["location"] as? String
        )
        return resp.resultText

      default:
        return "Unknown backend tool: \(toolCall.name)"
      }
    } catch {
      log("Backend tool error (\(toolCall.name)): \(error)")
      return "Error calling backend: \(error.localizedDescription)"
    }
  }

  // MARK: - Automation: Desktop (AppleScript + cliclick)

  /// Run AppleScript via osascript
  private static func executeRunAppleScript(_ args: [String: Any]) async -> String {
    guard let script = args["script"] as? String, !script.isEmpty else {
      return "Error: script is required"
    }
    // Block dangerous patterns
    let blocked = ["do shell script", "delete", "move to trash"]
    let lower = script.lowercased()
    for pattern in blocked {
      if lower.contains(pattern) {
        return "Error: script contains blocked operation '\(pattern)'"
      }
    }
    return await runProcess("/usr/bin/osascript", args: ["-e", script])
  }

  /// Open a macOS application by name
  private static func executeOpenApp(_ args: [String: Any]) async -> String {
    guard let appName = args["name"] as? String, !appName.isEmpty else {
      return "Error: name is required"
    }
    // Sanitize — only allow alphanumeric, spaces, dots, dashes
    let safe = appName.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "." || $0 == "-" }
    guard safe == appName else {
      return "Error: app name contains invalid characters"
    }
    return await runProcess("/usr/bin/open", args: ["-a", appName])
  }

  /// Open a URL in the default browser
  private static func executeOpenURL(_ args: [String: Any]) async -> String {
    guard let urlString = args["url"] as? String, !urlString.isEmpty else {
      return "Error: url is required"
    }
    guard urlString.hasPrefix("https://") || urlString.hasPrefix("http://") else {
      return "Error: only http/https URLs are allowed"
    }
    return await runProcess("/usr/bin/open", args: [urlString])
  }

  /// Click at screen coordinates using cliclick
  /// Requires: brew install cliclick
  private static func executeClickDesktop(_ args: [String: Any]) async -> String {
    guard let x = args["x"] as? Int, let y = args["y"] as? Int else {
      return "Error: x and y (integer screen coordinates) are required"
    }
    guard x >= 0, y >= 0, x <= 7680, y <= 4320 else {
      return "Error: coordinates out of valid range"
    }
    let cliclick = "/opt/homebrew/bin/cliclick"
    guard FileManager.default.fileExists(atPath: cliclick) else {
      return "Error: cliclick not found at \(cliclick). Install with: brew install cliclick"
    }
    return await runProcess(cliclick, args: ["c:\(x),\(y)"])
  }

  /// Type text using cliclick
  private static func executeTypeDesktop(_ args: [String: Any]) async -> String {
    guard let text = args["text"] as? String, !text.isEmpty else {
      return "Error: text is required"
    }
    guard text.count <= 500 else {
      return "Error: text too long (max 500 chars)"
    }
    let cliclick = "/opt/homebrew/bin/cliclick"
    guard FileManager.default.fileExists(atPath: cliclick) else {
      return "Error: cliclick not found at \(cliclick). Install with: brew install cliclick"
    }
    return await runProcess(cliclick, args: ["t:\(text)"])
  }

  // MARK: - Automation: Browser (Playwright)

  /// Run a browser action via a Playwright Node.js one-liner
  /// Supported actions: navigate, click, type, screenshot, get_text
  private static func executeBrowserAction(_ args: [String: Any]) async -> String {
    guard let action = args["action"] as? String else {
      return "Error: action is required (navigate | click | type | screenshot | get_text)"
    }

    // Find node
    let nodePaths = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    guard let nodePath = nodePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
      return "Error: Node.js not found. Install with: brew install node"
    }

    // Playwright lives in ~/jarvis-tools (installed via npm)
    let jarvisTools = "\(NSHomeDirectory())/jarvis-tools"
    let playwrightPath = "\(jarvisTools)/node_modules/playwright"
    guard FileManager.default.fileExists(atPath: playwrightPath) else {
      return "Error: Playwright not found. Run: cd ~/jarvis-tools && npm install playwright && npx playwright install chromium"
    }

    let script = buildPlaywrightScript(action: action, args: args, jarvisTools: jarvisTools)
    guard let script = script else {
      return "Error: unsupported action '\(action)'. Use: navigate | click | type | screenshot | get_text"
    }

    // Write CommonJS script to ~/jarvis-tools so require('playwright') resolves correctly
    let tmpScript = URL(fileURLWithPath: jarvisTools)
      .appendingPathComponent("_jarvis_run_\(UUID().uuidString).js")
    do {
      try script.write(to: tmpScript, atomically: true, encoding: .utf8)
    } catch {
      return "Error writing temp script: \(error.localizedDescription)"
    }
    defer { try? FileManager.default.removeItem(at: tmpScript) }

    return await runProcess(nodePath, args: [tmpScript.path], workingDirectory: jarvisTools, timeoutSeconds: 30)
  }

  /// Build a Playwright CommonJS script for the given action (runs from ~/jarvis-tools)
  private static func buildPlaywrightScript(action: String, args: [String: Any], jarvisTools: String) -> String? {
    // CommonJS require — resolves from jarvisTools/node_modules
    let header = "const { chromium } = require('playwright');"
    let launchArgs = "headless: false"

    // Helper to wrap async body in an IIFE (CommonJS has no top-level await)
    func iife(_ body: String) -> String {
      """
      \(header)
      (async () => {
        \(body)
      })().catch(e => { console.error(e.message); process.exit(1); });
      """
    }

    switch action {
    case "navigate":
      guard let url = args["url"] as? String, url.hasPrefix("http") else { return nil }
      let escaped = url.replacingOccurrences(of: "'", with: "\\'")
      return iife("""
        const b = await chromium.launch({ \(launchArgs) });
        const p = await b.newPage();
        await p.goto('\(escaped)', { waitUntil: 'domcontentloaded', timeout: 15000 });
        const title = await p.title();
        console.log('Navigated to: ' + title);
        await b.close();
        """)

    case "click":
      guard let selector = args["selector"] as? String else { return nil }
      let escapedSel = selector.replacingOccurrences(of: "'", with: "\\'")
      let urlPart = (args["url"] as? String).map {
        "await p.goto('\($0.replacingOccurrences(of: "'", with: "\\'"))', { waitUntil: 'domcontentloaded' });"
      } ?? ""
      return iife("""
        const b = await chromium.launch({ \(launchArgs) });
        const p = await b.newPage();
        \(urlPart)
        await p.click('\(escapedSel)', { timeout: 10000 });
        console.log('Clicked: \(escapedSel)');
        await b.close();
        """)

    case "type":
      guard let selector = args["selector"] as? String,
            let text = args["text"] as? String else { return nil }
      let escapedSel = selector.replacingOccurrences(of: "'", with: "\\'")
      let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
      let urlPart = (args["url"] as? String).map {
        "await p.goto('\($0.replacingOccurrences(of: "'", with: "\\'"))', { waitUntil: 'domcontentloaded' });"
      } ?? ""
      return iife("""
        const b = await chromium.launch({ \(launchArgs) });
        const p = await b.newPage();
        \(urlPart)
        await p.fill('\(escapedSel)', '\(escapedText)');
        console.log('Typed into: \(escapedSel)');
        await b.close();
        """)

    case "screenshot":
      let url = (args["url"] as? String) ?? ""
      let urlPart = url.hasPrefix("http")
        ? "await p.goto('\(url.replacingOccurrences(of: "'", with: "\\'"))', { waitUntil: 'domcontentloaded' });"
        : ""
      let outPath = "\(NSTemporaryDirectory())jarvis_browser_\(Int(Date().timeIntervalSince1970)).png"
      return iife("""
        const b = await chromium.launch({ \(launchArgs) });
        const p = await b.newPage();
        \(urlPart)
        await p.screenshot({ path: '\(outPath)', fullPage: false });
        console.log('Screenshot saved: \(outPath)');
        await b.close();
        """)

    case "get_text":
      guard let selector = args["selector"] as? String else { return nil }
      let escapedSel = selector.replacingOccurrences(of: "'", with: "\\'")
      let urlPart = (args["url"] as? String).map {
        "await p.goto('\($0.replacingOccurrences(of: "'", with: "\\'"))', { waitUntil: 'domcontentloaded' });"
      } ?? ""
      return iife("""
        const b = await chromium.launch({ \(launchArgs) });
        const p = await b.newPage();
        \(urlPart)
        const text = await p.textContent('\(escapedSel)');
        console.log(text);
        await b.close();
        """)

    default:
      return nil
    }
  }

  // MARK: - iMessage (AppleScript via Messages app)

  private static func executeSendIMessage(_ args: [String: Any]) async -> String {
    guard let recipient = args["to"] as? String, !recipient.isEmpty else {
      return "Error: 'to' is required (phone number e.g. +5561999999999, or email for iMessage)"
    }
    guard let message = args["message"] as? String, !message.isEmpty else {
      return "Error: 'message' is required"
    }
    let escapedRecipient = recipient.replacingOccurrences(of: "\"", with: "\\\"")
    let escapedMessage = message.replacingOccurrences(of: "\"", with: "\\\"")
    // Try iMessage first, fall back to SMS service
    let script = """
      tell application "Messages"
        set targetBuddy to "\(escapedRecipient)"
        set targetMessage to "\(escapedMessage)"
        set iMessageService to 1st service whose service type = iMessage
        set theBuddy to buddy targetBuddy of iMessageService
        send targetMessage to theBuddy
      end tell
      """
    let result = await runProcess("/usr/bin/osascript", args: ["-e", script])
    if result.lowercased().contains("error") {
      // Fallback: open Messages with URL scheme
      let encoded = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
      let digits = recipient.filter { $0.isNumber }
      return await runProcess("/usr/bin/open", args: ["sms://\(digits)&body=\(encoded)"])
    }
    return "iMessage sent to \(recipient)"
  }

  // MARK: - Email (AppleScript via Mail.app)

  private static func executeSendEmail(_ args: [String: Any]) async -> String {
    guard let to = args["to"] as? String, !to.isEmpty else {
      return "Error: 'to' is required (email address)"
    }
    guard let subject = args["subject"] as? String, !subject.isEmpty else {
      return "Error: 'subject' is required"
    }
    let body = (args["body"] as? String) ?? ""
    let escapedTo = to.replacingOccurrences(of: "\"", with: "\\\"")
    let escapedSubject = subject.replacingOccurrences(of: "\"", with: "\\\"")
    let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    let script = """
      tell application "Mail"
        set newMsg to make new outgoing message with properties {subject:"\(escapedSubject)", content:"\(escapedBody)", visible:true}
        tell newMsg
          make new to recipient with properties {address:"\(escapedTo)"}
        end tell
        send newMsg
        activate
      end tell
      """
    let result = await runProcess("/usr/bin/osascript", args: ["-e", script])
    if result.lowercased().contains("error") {
      // Fallback: open mailto link so user can send manually
      let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
      let subjectEncoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
      _ = await runProcess("/usr/bin/open", args: ["mailto:\(to)?subject=\(subjectEncoded)&body=\(encoded)"])
      return "Opened Mail.app compose window to \(to) — press Send to confirm."
    }
    return "Email sent to \(to) — subject: \"\(subject)\""
  }

  // MARK: - Calendar (AppleScript via Calendar.app)

  private static func executeCalendarAction(_ args: [String: Any]) async -> String {
    guard let action = args["action"] as? String else {
      return "Error: action is required (list_today | list_week | create)"
    }

    switch action {
    case "list_today":
      let script = """
        tell application "Calendar"
          set today to current date
          set startOfDay to today - (time of today)
          set endOfDay to startOfDay + (86399)
          set eventList to ""
          repeat with c in calendars
            set evts to (every event of c whose start date ≥ startOfDay and start date ≤ endOfDay)
            repeat with e in evts
              set eventList to eventList & summary of e & " @ " & (start date of e as string) & "\n"
            end repeat
          end repeat
          if eventList is "" then return "No events today"
          return eventList
        end tell
        """
      return await runProcess("/usr/bin/osascript", args: ["-e", script])

    case "list_week":
      let script = """
        tell application "Calendar"
          set today to current date
          set startOfDay to today - (time of today)
          set endOfWeek to startOfDay + (7 * 86400)
          set eventList to ""
          repeat with c in calendars
            set evts to (every event of c whose start date ≥ startOfDay and start date ≤ endOfWeek)
            repeat with e in evts
              set eventList to eventList & summary of e & " @ " & (start date of e as string) & "\n"
            end repeat
          end repeat
          if eventList is "" then return "No events this week"
          return eventList
        end tell
        """
      return await runProcess("/usr/bin/osascript", args: ["-e", script])

    case "create":
      guard let title = args["title"] as? String, !title.isEmpty else {
        return "Error: title is required for create"
      }
      guard let startDate = args["start_date"] as? String, !startDate.isEmpty else {
        return "Error: start_date is required (e.g. 'Friday, April 25, 2026 at 3:00 PM')"
      }
      let endDate = (args["end_date"] as? String) ?? ""
      let calName = (args["calendar"] as? String) ?? "Home"
      let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
      let escapedCal = calName.replacingOccurrences(of: "\"", with: "\\\"")
      let escapedStart = startDate.replacingOccurrences(of: "\"", with: "\\\"")

      var endPart = ""
      if !endDate.isEmpty {
        let escapedEnd = endDate.replacingOccurrences(of: "\"", with: "\\\"")
        endPart = ", end date:date \"\(escapedEnd)\""
      }

      let script = """
        tell application "Calendar"
          tell calendar "\(escapedCal)"
            make new event with properties {summary:"\(escapedTitle)", start date:date "\(escapedStart)"\(endPart)}
          end tell
        end tell
        return "Event created: \(escapedTitle)"
        """
      return await runProcess("/usr/bin/osascript", args: ["-e", script])

    default:
      return "Error: unknown action '\(action)'. Use: list_today | list_week | create"
    }
  }

  // MARK: - Filesystem (read / write / list — sandboxed to user home)

  /// Allowed base paths — prevents access outside home directory
  private static let allowedBasePaths: [String] = {
    let home = NSHomeDirectory()
    return [
      "\(home)/Documents", "\(home)/Downloads", "\(home)/Desktop",
      "\(home)/Developer", "\(home)/Projects", "\(home)/Notes",
    ]
  }()

  private static func executeFilesystemAction(_ args: [String: Any]) async -> String {
    guard let action = args["action"] as? String else {
      return "Error: action is required (read | write | list | exists)"
    }
    guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
      return "Error: path is required"
    }

    // Expand ~ and resolve path
    let expandedPath = rawPath.replacingOccurrences(of: "~", with: NSHomeDirectory())
    let resolvedPath = URL(fileURLWithPath: expandedPath).standardized.path

    // Security: must be under an allowed base path
    let isAllowed = allowedBasePaths.contains { resolvedPath.hasPrefix($0) }
    guard isAllowed else {
      return "Error: path '\(resolvedPath)' is outside allowed directories (Documents, Downloads, Desktop, Developer, Projects, Notes)"
    }

    let fm = FileManager.default

    switch action {
    case "read":
      guard fm.fileExists(atPath: resolvedPath) else {
        return "Error: file not found at \(resolvedPath)"
      }
      do {
        let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        // Truncate large files
        if content.count > 8000 {
          return String(content.prefix(8000)) + "\n\n[...truncated — file is \(content.count) chars total]"
        }
        return content
      } catch {
        return "Error reading file: \(error.localizedDescription)"
      }

    case "write":
      guard let content = args["content"] as? String else {
        return "Error: content is required for write"
      }
      do {
        // Create parent directories if needed
        let dir = URL(fileURLWithPath: resolvedPath).deletingLastPathComponent().path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
        return "Written \(content.count) chars to \(resolvedPath)"
      } catch {
        return "Error writing file: \(error.localizedDescription)"
      }

    case "list":
      do {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedPath, isDirectory: &isDir), isDir.boolValue else {
          return "Error: '\(resolvedPath)' is not a directory"
        }
        let items = try fm.contentsOfDirectory(atPath: resolvedPath)
        let lines = items.sorted().prefix(100).map { name -> String in
          let full = resolvedPath + "/" + name
          var d: ObjCBool = false
          fm.fileExists(atPath: full, isDirectory: &d)
          return d.boolValue ? "\(name)/" : name
        }
        return "\(lines.count) item(s) in \(resolvedPath):\n" + lines.joined(separator: "\n")
      } catch {
        return "Error listing directory: \(error.localizedDescription)"
      }

    case "exists":
      let exists = fm.fileExists(atPath: resolvedPath)
      return exists ? "exists: \(resolvedPath)" : "not found: \(resolvedPath)"

    default:
      return "Error: unknown action '\(action)'. Use: read | write | list | exists"
    }
  }

  // MARK: - Apple Shortcuts

  private static func executeRunShortcut(_ args: [String: Any]) async -> String {
    guard let name = args["name"] as? String, !name.isEmpty else {
      return "Error: name is required (the Shortcut name as it appears in the Shortcuts app)"
    }
    // Sanitize name — block shell injection
    let safe = name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" || $0 == "'" }
    guard safe == name else {
      return "Error: shortcut name contains invalid characters"
    }
    // Use `shortcuts run` CLI (available on macOS 12+)
    let result = await runProcess("/usr/bin/shortcuts", args: ["run", name])
    if result.lowercased().contains("error") || result.lowercased().contains("not found") {
      return "Error running shortcut '\(name)': \(result)"
    }
    return "Shortcut '\(name)' executed successfully"
  }

  // MARK: - WhatsApp (URL scheme — opens WhatsApp Desktop with pre-filled message)

  private static func executeSendWhatsApp(_ args: [String: Any]) async -> String {
    guard let phone = args["phone"] as? String, !phone.isEmpty else {
      return "Error: phone is required (international format, e.g. +5561999999999)"
    }
    // Strip non-digits except leading +
    let digits = phone.filter { $0.isNumber }
    guard digits.count >= 8 else {
      return "Error: phone number too short — use international format e.g. +5561999999999"
    }
    let message = (args["message"] as? String) ?? ""
    var urlString = "whatsapp://send?phone=\(digits)"
    if !message.isEmpty, let encoded = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
      urlString += "&text=\(encoded)"
    }
    // open the URL scheme — WhatsApp Desktop handles it
    let result = await runProcess("/usr/bin/open", args: [urlString])
    if result.lowercased().contains("error") { return result }
    return "WhatsApp opened\(message.isEmpty ? "" : " with message pre-filled"). Press Send to confirm."
  }

  // MARK: - Web Search (Tavily AI search API — real-time results)

  private static func executeWebSearch(_ args: [String: Any]) async -> String {
    guard let query = args["query"] as? String, !query.isEmpty else {
      return "Error: query is required"
    }
    guard query.count <= 400 else { return "Error: query too long (max 400 chars)" }

    // Read Tavily API key from environment (loaded from ~/.omi.env or bundle .env)
    guard let apiKeyCStr = getenv("TAVILY_API_KEY"),
          let apiKey = String(validatingCString: apiKeyCStr), !apiKey.isEmpty else {
      return await executeWebSearchFallback(query: query)
    }

    guard let url = URL(string: "https://api.tavily.com/search") else {
      return "Error: could not build search URL"
    }

    let body: [String: Any] = [
      "api_key": apiKey,
      "query": query,
      "search_depth": "basic",
      "max_results": 5,
      "include_answer": true,
    ]
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
      return "Error: could not serialize search request"
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = bodyData

    do {
      let (data, _) = try await URLSession.shared.data(for: request)
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return "Error: failed to parse search response"
      }

      var lines: [String] = ["Search: \(query)\n"]

      // Direct AI answer
      if let answer = json["answer"] as? String, !answer.isEmpty {
        lines.append("Answer: \(answer)\n")
      }

      // Top results
      if let results = json["results"] as? [[String: Any]], !results.isEmpty {
        lines.append("Sources:")
        for r in results.prefix(5) {
          let title = (r["title"] as? String) ?? ""
          let url = (r["url"] as? String) ?? ""
          let content = (r["content"] as? String) ?? ""
          let snippet = content.count > 200 ? String(content.prefix(200)) + "..." : content
          lines.append("• \(title)\n  \(url)\n  \(snippet)")
        }
      }

      let result = lines.joined(separator: "\n")
      return result.count > 20 ? result : "No results found for: \(query)"
    } catch {
      return await executeWebSearchFallback(query: query)
    }
  }

  // Fallback: DuckDuckGo Instant Answers (no key required)
  private static func executeWebSearchFallback(query: String) async -> String {
    var components = URLComponents(string: "https://api.duckduckgo.com/")!
    components.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "format", value: "json"),
      URLQueryItem(name: "no_html", value: "1"),
      URLQueryItem(name: "skip_disambig", value: "1"),
    ]
    guard let url = components.url else { return "Error: could not build search URL" }
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return "Error: failed to parse search response"
      }
      var lines: [String] = ["Search: \(query)\n"]
      if let abstract = json["AbstractText"] as? String, !abstract.isEmpty {
        lines.append("Answer: \(abstract)")
        if let src = json["AbstractSource"] as? String, !src.isEmpty { lines.append("Source: \(src)") }
        lines.append("")
      }
      if let answer = json["Answer"] as? String, !answer.isEmpty {
        lines.append("Instant Answer: \(answer)")
      }
      if let topics = json["RelatedTopics"] as? [[String: Any]] {
        let results = topics.compactMap { t -> String? in
          guard let text = t["Text"] as? String, !text.isEmpty else { return nil }
          return "• \(text)"
        }.prefix(4)
        if !results.isEmpty { lines.append("Related:"); lines.append(contentsOf: results) }
      }
      let result = lines.joined(separator: "\n")
      return result.count > 20 ? result : "No results found for: \(query)"
    } catch {
      return "Search error: \(error.localizedDescription)"
    }
  }

  // MARK: - Spotify Control (AppleScript shortcuts)

  private static func executeSpotifyControl(_ args: [String: Any]) async -> String {
    guard let command = args["command"] as? String else {
      return "Error: command is required (play | pause | next | previous | play_track | get_current | set_volume)"
    }

    switch command {
    case "play":
      return await runProcess("/usr/bin/osascript", args: ["-e", "tell application \"Spotify\" to play"])
    case "pause":
      return await runProcess("/usr/bin/osascript", args: ["-e", "tell application \"Spotify\" to pause"])
    case "next":
      return await runProcess("/usr/bin/osascript", args: ["-e", "tell application \"Spotify\" to next track"])
    case "previous":
      return await runProcess("/usr/bin/osascript", args: ["-e", "tell application \"Spotify\" to previous track"])
    case "get_current":
      let script = """
        tell application "Spotify"
          set t to name of current track
          set a to artist of current track
          set s to player state as string
          return s & " — " & a & " — " & t
        end tell
        """
      return await runProcess("/usr/bin/osascript", args: ["-e", script])
    case "play_track":
      guard let track = args["track"] as? String, !track.isEmpty else {
        return "Error: track name required for play_track"
      }
      let escaped = track.replacingOccurrences(of: "\"", with: "\\\"")
      let script = """
        tell application "Spotify"
          set searchUrl to "spotify:search:" & "\(escaped)"
          play track searchUrl
        end tell
        """
      return await runProcess("/usr/bin/osascript", args: ["-e", script])
    case "set_volume":
      guard let volume = args["volume"] as? Int, (0...100).contains(volume) else {
        return "Error: volume must be an integer 0–100"
      }
      let script = "tell application \"Spotify\" to set sound volume to \(volume)"
      return await runProcess("/usr/bin/osascript", args: ["-e", script])
    default:
      return "Error: unknown command '\(command)'. Use: play | pause | next | previous | play_track | get_current | set_volume"
    }
  }

  // MARK: - Focus Mode

  /// Ativa/desativa o Modo Foco: DND ligado, Spotify com playlist, notificações silenciadas.
  /// args: action ("on" | "off"), playlist (opcional, nome da playlist Spotify)
  private static func executeFocusMode(_ args: [String: Any]) async -> String {
    let action = (args["action"] as? String ?? "on").lowercased()

    if action == "off" {
      // Desliga DND via osascript
      let dndOff = """
        tell application "System Events"
          tell process "Control Center"
            try
              key code 100 using {command down, option down}
            end try
          end tell
        end tell
        """
      _ = await runProcess("/usr/bin/osascript", args: ["-e", dndOff])

      // Pausa Spotify
      _ = await runProcess("/usr/bin/osascript", args: ["-e", "tell application \"Spotify\" to pause"])

      return "Modo Foco desativado. Notificações restauradas."
    }

    // Modo Foco ON
    var results: [String] = []

    // 1. Liga DND via Shortcuts (mais confiável que simular cliques)
    let dndScript = """
      tell application "Shortcuts"
        run shortcut "Focus Mode On"
      end tell
      """
    let dndResult = await runProcess("/usr/bin/osascript", args: ["-e", dndScript])
    // Fallback: tenta via defaults se o shortcut não existir
    if dndResult.lowercased().contains("error") {
      _ = await runProcess("/usr/bin/defaults", args: ["write", "com.apple.ncprefs", "dnd_prefs", "-dict-add", "userPref", "1"])
    }
    results.append("DND ativado")

    // 2. Spotify — toca playlist de foco se fornecida, senão continua o que estava tocando
    if let playlist = args["playlist"] as? String, !playlist.isEmpty {
      let escaped = playlist.replacingOccurrences(of: "\"", with: "\\\"")
      let spotScript = """
        tell application "Spotify"
          play track "spotify:search:\(escaped)"
          set sound volume to 40
        end tell
        """
      _ = await runProcess("/usr/bin/osascript", args: ["-e", spotScript])
      results.append("Spotify: \(playlist)")
    } else {
      // Somente ajusta volume para 40 e continua
      _ = await runProcess("/usr/bin/osascript", args: ["-e", "tell application \"Spotify\" to set sound volume to 40"])
      results.append("Spotify: volume ajustado para foco")
    }

    // 3. Notificação de confirmação
    let notif = "display notification \"Modo Foco ativo. Bom trabalho, Sr. Matheus.\" with title \"JARVIS\" sound name \"Morse\""
    _ = await runProcess("/usr/bin/osascript", args: ["-e", notif])

    return "Modo Foco ativado: " + results.joined(separator: ", ")
  }

  // MARK: - Process Runner

  /// Run an external process and return its stdout (trimmed), or stderr on failure
  private static func runProcess(
    _ executable: String,
    args: [String],
    workingDirectory: String? = nil,
    timeoutSeconds: Double = 10
  ) async -> String {
    await withCheckedContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = args
      if let wd = workingDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: wd)
      }

      let stdout = Pipe()
      let stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr

      var timedOut = false
      let timer = DispatchWorkItem {
        timedOut = true
        process.terminate()
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timer)

      do {
        try process.run()
        process.waitUntilExit()
        timer.cancel()
      } catch {
        continuation.resume(returning: "Error launching process: \(error.localizedDescription)")
        return
      }

      if timedOut {
        continuation.resume(returning: "Error: process timed out after \(Int(timeoutSeconds))s")
        return
      }

      let outData = stdout.fileHandleForReading.readDataToEndOfFile()
      let errData = stderr.fileHandleForReading.readDataToEndOfFile()
      let outStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

      if process.terminationStatus != 0 {
        let detail = errStr.isEmpty ? outStr : errStr
        continuation.resume(returning: "Error (exit \(process.terminationStatus)): \(detail)")
      } else {
        continuation.resume(returning: outStr.isEmpty ? "OK" : outStr)
      }
    }
  }
}
