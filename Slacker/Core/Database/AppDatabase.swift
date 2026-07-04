import Foundation
import GRDB

/// Owns the GRDB connection and schema migrations.
///
/// Migrations are defined from day one and run on init (`docs/IMPLEMENTATION.md` §4).
/// M0 establishes the migrator + the single-row `appSettings` table; the message /
/// channel / item / label / summary / user tables are added in M2.
struct AppDatabase {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    /// Open the on-disk database in Application Support, creating the directory if needed.
    static func makeShared() throws -> AppDatabase {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Slacker", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("slacker.sqlite")
        let pool = try DatabasePool(path: dbURL.path)
        return try AppDatabase(pool)
    }

    /// In-memory database for tests.
    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // Re-run migrations from scratch when a migration definition changes (dev only).
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_appSettings") { db in
            try db.create(table: "appSettings") { t in
                t.primaryKey("id", .integer)
                t.column("stalenessHours", .integer).notNull()
                t.column("pollIntervalSeconds", .integer).notNull()
                t.column("manifestVariant", .text).notNull()
                t.column("llmProvider", .text).notNull()
                t.column("llmModel", .text).notNull()
                t.column("onboardingCompleted", .boolean).notNull()
            }
        }

        migrator.registerMigration("v2_channels") { db in
            try db.create(table: "channel") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("isPrivate", .boolean).notNull()
                t.column("isWatched", .boolean).notNull().defaults(to: false)
                t.column("sensitivity", .text).notNull().defaults(to: ChannelSensitivity.normal.rawValue)
                t.column("lastPolledTS", .text)
            }
            try db.create(indexOn: "channel", columns: ["isWatched"])
        }

        migrator.registerMigration("v3_users") { db in
            try db.create(table: "user") { t in
                t.primaryKey("id", .text)
                t.column("displayName", .text)
                t.column("realName", .text)
            }
        }

        migrator.registerMigration("v4_messages") { db in
            try db.create(table: "message") { t in
                t.primaryKey("id", .text)
                t.column("channelID", .text).notNull()
                    .references("channel", onDelete: .cascade)
                t.column("threadTS", .text)
                t.column("userID", .text)
                t.column("text", .text).notNull()
                t.column("ts", .text).notNull()
                t.column("reactionsJSON", .text)
                t.column("ingestedAt", .datetime).notNull()
            }
            try db.create(indexOn: "message", columns: ["channelID", "ts"])
            try db.create(indexOn: "message", columns: ["threadTS"])
        }

        migrator.registerMigration("v5_items") { db in
            try db.create(table: "item") { t in
                t.primaryKey("id", .text)
                t.column("channelID", .text).notNull()
                    .references("channel", onDelete: .cascade)
                t.column("rootMessageTS", .text).notNull()
                t.column("threadTS", .text)
                t.column("type", .text).notNull()
                t.column("state", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastEvaluatedAt", .datetime).notNull()
                t.column("snoozedUntil", .datetime)
                t.column("resolutionReason", .text)
            }
            try db.create(indexOn: "item", columns: ["state"])
            // One item per thread root, so detection re-evaluation is idempotent.
            try db.create(
                index: "idx_item_unique_root",
                on: "item",
                columns: ["channelID", "rootMessageTS"],
                unique: true
            )
        }

        migrator.registerMigration("v6_labels") { db in
            try db.create(table: "label") { t in
                t.primaryKey("id", .text)
                t.column("itemID", .text).references("item", onDelete: .setNull)
                t.column("messageTS", .text).notNull()
                t.column("channelID", .text).notNull()
                t.column("userVerdict", .text).notNull()
                t.column("source", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(indexOn: "label", columns: ["channelID"])
        }

        migrator.registerMigration("v7_summaries") { db in
            try db.create(table: "summary") { t in
                t.primaryKey("id", .text)
                t.column("channelID", .text).notNull()
                    .references("channel", onDelete: .cascade)
                t.column("date", .text).notNull()
                t.column("text", .text).notNull()
                t.column("generatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v8_settings_llm_endpoint") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "llmBaseURL", .text).notNull().defaults(to: "")
                t.add(column: "cliPathOverride", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v9_settings_team_id") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "teamID", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v10_item_thread_summary") { db in
            try db.alter(table: "item") { t in
                t.add(column: "threadSummary", .text)
                t.add(column: "summarizedReplyCount", .integer)
            }
        }

        migrator.registerMigration("v11_workspaces") { db in
            try db.create(table: "workspace") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("authUserID", .text).notNull()
                t.column("manifestVariant", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.alter(table: "channel") { t in
                t.add(column: "workspaceID", .text).notNull().defaults(to: "")
            }
            try db.create(indexOn: "channel", columns: ["workspaceID"])

            // Backfill: promote the existing single workspace (if onboarded) into a
            // workspace row and tag its channels.
            if let settings = try AppSettings.fetchOne(db, key: 1),
               settings.onboardingCompleted, !settings.teamID.isEmpty {
                try db.execute(sql: "UPDATE channel SET workspaceID = ?", arguments: [settings.teamID])
                try Workspace(
                    id: settings.teamID,
                    name: settings.teamID,           // real name filled in on next refresh
                    authUserID: "",
                    manifestVariant: settings.manifestVariant,
                    createdAt: Date()
                ).insert(db)
            }
        }

        migrator.registerMigration("v12_self_evolution") { db in
            // Learned rule-engine phrases (§7.5). channelID NULL = global. Detection
            // reads only status == approved, so proposals are inert until approved.
            try db.create(table: "learnedPattern") { t in
                t.primaryKey("id", .text)
                t.column("channelID", .text)              // NULL = global
                t.column("bucket", .text).notNull()
                t.column("phrase", .text).notNull()
                t.column("status", .text).notNull()
                t.column("source", .text).notNull()
                t.column("rationale", .text)
                t.column("supportingLabelCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("decidedAt", .datetime)
            }
            try db.create(indexOn: "learnedPattern", columns: ["channelID"])
            // Idempotent mining: never propose the same phrase twice for a scope+bucket.
            try db.create(
                index: "idx_learned_pattern_unique",
                on: "learnedPattern",
                columns: ["channelID", "bucket", "phrase"],
                unique: true
            )

            // Learned LLM "skill" guidance blocks (§7.5), versioned per scope.
            try db.create(table: "learnedGuidance") { t in
                t.primaryKey("id", .text)
                t.column("channelID", .text)              // NULL = global
                t.column("text", .text).notNull()
                t.column("status", .text).notNull()
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("createdAt", .datetime).notNull()
                t.column("decidedAt", .datetime)
            }
            try db.create(indexOn: "learnedGuidance", columns: ["channelID", "status"])

            // Cadence bookkeeping for the evolution loop (one row per channel).
            try db.create(table: "evolutionRun") { t in
                t.primaryKey("channelID", .text)
                t.column("lastRunAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v13_channel_detection_cursor") { db in
            try db.alter(table: "channel") { t in
                t.add(column: "lastDetectedTS", .text)
            }
            // Existing installs have already been running detection after each poll.
            // Seed the new cursor from the ingestion cursor so the first launch after
            // this migration does not reclassify the full local archive once.
            try db.execute(sql: "UPDATE channel SET lastDetectedTS = lastPolledTS WHERE lastPolledTS IS NOT NULL")
        }

        migrator.registerMigration("v14_summary_interval") { db in
            try db.alter(table: "appSettings") { t in
                t.add(column: "summaryRefreshIntervalMinutes", .integer)
                    .notNull()
                    .defaults(to: 360)
            }
        }

        migrator.registerMigration("v15_resolved_reaction_observed_at") { db in
            try db.alter(table: "message") { t in
                t.add(column: "resolvedReactionObservedAt", .datetime)
            }
        }

        return migrator
    }
}
