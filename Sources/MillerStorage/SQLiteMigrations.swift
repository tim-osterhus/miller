struct SQLiteMigration: Sendable {
    let version: Int
    let sql: String
}

enum SQLiteMigrations {
    static let all = [
        SQLiteMigration(
            version: 1,
            sql: """
            CREATE TABLE schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL
            );

            CREATE TABLE conversations (
                id TEXT PRIMARY KEY,
                title TEXT,
                state TEXT NOT NULL CHECK (state IN ('active', 'archived')),
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                archived_at TEXT
            );

            CREATE TABLE turns (
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL
                    REFERENCES conversations(id) ON DELETE CASCADE,
                sequence INTEGER NOT NULL,
                input_mode TEXT NOT NULL CHECK (input_mode IN ('text', 'voice')),
                user_text TEXT NOT NULL,
                assistant_text TEXT NOT NULL DEFAULT '',
                state TEXT NOT NULL CHECK (
                    state IN ('accepted', 'streaming', 'completed', 'stopped', 'failed')
                ),
                generation INTEGER NOT NULL,
                error_code TEXT,
                error_message TEXT,
                started_at TEXT NOT NULL,
                terminal_at TEXT,
                UNIQUE (conversation_id, sequence)
            );

            CREATE TABLE provider_profiles (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL CHECK (
                    kind IN ('codex_oauth', 'openai_compatible')
                ),
                label TEXT NOT NULL,
                base_url TEXT,
                model TEXT NOT NULL,
                credential_ref TEXT NOT NULL UNIQUE,
                is_selected INTEGER NOT NULL DEFAULT 0
                    CHECK (is_selected IN (0, 1)),
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE UNIQUE INDEX one_selected_provider_profile
            ON provider_profiles(is_selected)
            WHERE is_selected = 1;
            """
        ),
        SQLiteMigration(
            version: 2,
            sql: """
            ALTER TABLE provider_profiles
            ADD COLUMN credential_status TEXT NOT NULL DEFAULT 'unknown'
                CHECK (
                    credential_status IN ('unknown', 'valid', 'invalid')
                );
            """
        ),
    ]

    static let latestVersion = all.last?.version ?? 0
}
