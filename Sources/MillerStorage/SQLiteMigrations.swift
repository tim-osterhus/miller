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
        SQLiteMigration(
            version: 3,
            sql: """
            CREATE TABLE voice_sessions (
                id TEXT PRIMARY KEY,
                conversation_id TEXT
                    REFERENCES conversations(id) ON DELETE CASCADE,
                activation_source TEXT NOT NULL CHECK (
                    activation_source IN ('manual', 'wakeword')
                ),
                started_at TEXT NOT NULL,
                ended_at TEXT,
                terminal_outcome TEXT CHECK (
                    terminal_outcome IS NULL OR terminal_outcome IN (
                        'completed', 'stopped', 'failed', 'abandoned'
                    )
                ),
                save_choice TEXT NOT NULL CHECK (
                    save_choice IN ('save', 'discard')
                ),
                CHECK (
                    (ended_at IS NULL AND terminal_outcome IS NULL)
                    OR (ended_at IS NOT NULL AND terminal_outcome IS NOT NULL)
                ),
                CHECK (ended_at IS NULL OR ended_at >= started_at)
            );

            CREATE TABLE voice_entries (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL
                    REFERENCES voice_sessions(id) ON DELETE CASCADE,
                sequence INTEGER NOT NULL CHECK (sequence >= 0),
                role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
                text TEXT NOT NULL CHECK (
                    length(CAST(text AS BLOB)) <= 65536
                ),
                completion_state TEXT NOT NULL CHECK (
                    completion_state IN ('incomplete', 'complete')
                ),
                started_at TEXT NOT NULL,
                completed_at TEXT,
                UNIQUE (session_id, sequence),
                CHECK (
                    (completion_state = 'incomplete' AND completed_at IS NULL)
                    OR (completion_state = 'complete' AND completed_at IS NOT NULL)
                ),
                CHECK (completed_at IS NULL OR completed_at >= started_at)
            );

            CREATE TABLE capability_servers (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                transport TEXT NOT NULL CHECK (
                    transport IN ('stdio', 'streamable_http')
                ),
                command TEXT,
                endpoint TEXT,
                arguments_json TEXT NOT NULL CHECK (
                    json_valid(arguments_json)
                    AND json_type(arguments_json) = 'array'
                    AND length(CAST(arguments_json AS BLOB)) <= 65536
                ),
                enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
                default_policy TEXT NOT NULL CHECK (
                    default_policy IN (
                        'read_only_automatic',
                        'ask_before_changes',
                        'fully_trusted'
                    )
                ),
                stale_state TEXT NOT NULL CHECK (
                    stale_state IN ('current', 'stale')
                ),
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                CHECK (
                    (transport = 'stdio' AND command IS NOT NULL
                        AND endpoint IS NULL)
                    OR (transport = 'streamable_http' AND command IS NULL
                        AND endpoint LIKE 'https://%')
                )
            );

            CREATE TABLE capability_secret_bindings (
                id TEXT PRIMARY KEY,
                server_id TEXT NOT NULL
                    REFERENCES capability_servers(id) ON DELETE CASCADE,
                binding_kind TEXT NOT NULL CHECK (
                    binding_kind IN ('environment', 'header')
                ),
                binding_name TEXT NOT NULL,
                credential_ref TEXT NOT NULL CHECK (
                    length(credential_ref) = 36
                    AND substr(credential_ref, 9, 1) = '-'
                    AND substr(credential_ref, 14, 1) = '-'
                    AND substr(credential_ref, 19, 1) = '-'
                    AND substr(credential_ref, 24, 1) = '-'
                    AND length(replace(credential_ref, '-', '')) = 32
                    AND credential_ref NOT GLOB '*[^0-9a-f-]*'
                ),
                UNIQUE (server_id, binding_kind, binding_name)
            );

            CREATE TABLE provider_capability_settings (
                server_id TEXT NOT NULL
                    REFERENCES capability_servers(id) ON DELETE CASCADE,
                provider_profile_id TEXT NOT NULL
                    REFERENCES provider_profiles(id) ON DELETE CASCADE,
                enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
                PRIMARY KEY (server_id, provider_profile_id)
            );

            CREATE TABLE capability_tools (
                id TEXT PRIMARY KEY,
                server_id TEXT NOT NULL
                    REFERENCES capability_servers(id) ON DELETE CASCADE,
                source TEXT NOT NULL CHECK (
                    source IN ('codex_account', 'miller_mcp', 'provider_native')
                ),
                source_server_id TEXT NOT NULL,
                tool_name TEXT NOT NULL,
                display_name TEXT NOT NULL,
                summary TEXT NOT NULL CHECK (
                    length(CAST(summary AS BLOB)) <= 1024
                ),
                input_schema_json BLOB NOT NULL CHECK (
                    length(input_schema_json) <= 65536
                    AND json_valid(CAST(input_schema_json AS TEXT))
                    AND json_type(CAST(input_schema_json AS TEXT)) = 'object'
                ),
                read_only_hint INTEGER CHECK (read_only_hint IN (0, 1)),
                available INTEGER NOT NULL CHECK (available IN (0, 1)),
                stale_state TEXT NOT NULL CHECK (
                    stale_state IN ('current', 'stale')
                ),
                content_hash TEXT,
                reconciled_at TEXT NOT NULL,
                UNIQUE (source, source_server_id, tool_name)
            );

            CREATE TABLE capability_policy_overrides (
                tool_id TEXT PRIMARY KEY
                    REFERENCES capability_tools(id) ON DELETE CASCADE,
                policy TEXT NOT NULL CHECK (
                    policy IN (
                        'read_only_automatic',
                        'ask_before_changes',
                        'fully_trusted'
                    )
                ),
                updated_at TEXT NOT NULL
            );

            CREATE TABLE capability_audit (
                id TEXT PRIMARY KEY,
                conversation_id TEXT
                    REFERENCES conversations(id) ON DELETE CASCADE,
                turn_id TEXT REFERENCES turns(id) ON DELETE CASCADE,
                voice_session_id TEXT
                    REFERENCES voice_sessions(id) ON DELETE CASCADE,
                source TEXT NOT NULL CHECK (
                    source IN ('codex_account', 'miller_mcp', 'provider_native')
                ),
                source_server_id TEXT NOT NULL,
                tool_name TEXT NOT NULL,
                started_at TEXT NOT NULL,
                terminal_at TEXT,
                effective_policy TEXT NOT NULL CHECK (
                    effective_policy IN (
                        'read_only_automatic',
                        'ask_before_changes',
                        'fully_trusted'
                    )
                ),
                approval_requested INTEGER NOT NULL CHECK (
                    approval_requested IN (0, 1)
                ),
                approval_decision TEXT CHECK (
                    approval_decision IS NULL
                    OR approval_decision IN ('allow_once', 'decline')
                ),
                terminal_outcome TEXT CHECK (
                    terminal_outcome IS NULL OR terminal_outcome IN (
                        'succeeded', 'failed', 'declined', 'cancelled', 'timed_out'
                    )
                ),
                sanitized_summary TEXT CHECK (
                    sanitized_summary IS NULL OR (
                        length(CAST(sanitized_summary AS BLOB)) <= 1024
                        AND sanitized_summary IN (
                            'List calendar events.',
                            'Create a calendar event.',
                            'Search email metadata.',
                            'Read local files.',
                            'Change local files.',
                            'Run a local command.',
                            'Capability request declined by the user.',
                            'Capability request refused by policy.',
                            'Provider activity recorded without result details.'
                        )
                    )
                ),
                visibility TEXT NOT NULL CHECK (
                    visibility IN ('complete', 'opaque_provider_activity')
                ),
                CHECK (
                    (terminal_at IS NULL AND terminal_outcome IS NULL)
                    OR (terminal_at IS NOT NULL AND terminal_outcome IS NOT NULL)
                ),
                CHECK (
                    conversation_id IS NOT NULL
                    OR turn_id IS NOT NULL
                    OR voice_session_id IS NOT NULL
                ),
                CHECK (turn_id IS NULL OR voice_session_id IS NULL),
                CHECK (terminal_at IS NULL OR terminal_at >= started_at),
                CHECK (
                    (CASE
                        WHEN terminal_outcome IS NULL THEN
                            approval_decision IS NULL
                        WHEN approval_requested = 0 THEN
                            approval_decision IS NULL
                        WHEN terminal_outcome IN ('succeeded', 'failed') THEN
                            approval_decision IS NOT NULL
                            AND approval_decision = 'allow_once'
                        WHEN terminal_outcome = 'declined' THEN
                            approval_decision IS NOT NULL
                            AND approval_decision = 'decline'
                        WHEN terminal_outcome IN ('cancelled', 'timed_out') THEN
                            approval_decision IS NULL
                            OR approval_decision = 'allow_once'
                        ELSE 0
                    END) IS TRUE
                )
            );

            CREATE TABLE plugin_packages (
                id TEXT PRIMARY KEY,
                version TEXT,
                source_hash TEXT NOT NULL,
                supported_component_summary TEXT NOT NULL CHECK (
                    length(CAST(supported_component_summary AS BLOB)) <= 4096
                ),
                enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE (id, source_hash)
            );

            CREATE TABLE portable_skills (
                id TEXT PRIMARY KEY,
                plugin_id TEXT
                    REFERENCES plugin_packages(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                description TEXT NOT NULL,
                markdown_snapshot TEXT NOT NULL CHECK (
                    length(CAST(markdown_snapshot AS BLOB)) <= 65536
                ),
                source_hash TEXT NOT NULL,
                enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE (plugin_id, name)
            );

            CREATE TABLE provider_skill_settings (
                skill_id TEXT NOT NULL
                    REFERENCES portable_skills(id) ON DELETE CASCADE,
                provider_profile_id TEXT NOT NULL
                    REFERENCES provider_profiles(id) ON DELETE CASCADE,
                enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
                PRIMARY KEY (skill_id, provider_profile_id)
            );

            CREATE TABLE miller_preferences (
                key TEXT PRIMARY KEY CHECK (key IN (
                    'voice_transcript_saving_enabled',
                    'next_voice_session_saving_enabled',
                    'wakeword_enabled',
                    'remote_live_enabled',
                    'wake_phrase',
                    'wake_microphone_id',
                    'wake_detection_threshold',
                    'wake_keyword_score',
                    'selected_settings_tab',
                    'menu_bar_enabled',
                    'launch_at_login'
                )),
                value_json TEXT NOT NULL CHECK (
                    json_valid(value_json)
                    AND length(CAST(value_json AS BLOB)) <= 65536
                ),
                updated_at TEXT NOT NULL
            );

            CREATE INDEX voice_sessions_started_at
                ON voice_sessions(started_at);
            CREATE INDEX voice_entries_session_sequence
                ON voice_entries(session_id, sequence);
            CREATE INDEX capability_tools_server
                ON capability_tools(server_id, stale_state, tool_name);
            CREATE INDEX capability_audit_started_at
                ON capability_audit(started_at);
            """
        ),
        SQLiteMigration(
            version: 4,
            sql: """
            ALTER TABLE capability_tools
            ADD COLUMN accessible INTEGER NOT NULL DEFAULT 1
                CHECK (accessible IN (0, 1));

            ALTER TABLE capability_tools
            ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1
                CHECK (enabled IN (0, 1));

            ALTER TABLE capability_tools
            ADD COLUMN callable INTEGER NOT NULL DEFAULT 1
                CHECK (callable IN (0, 1));

            ALTER TABLE capability_tools
            ADD COLUMN visibility TEXT NOT NULL DEFAULT 'owner_managed'
                CHECK (visibility IN ('owner_managed', 'provider_managed'));

            UPDATE capability_tools
            SET visibility = 'provider_managed'
            WHERE source = 'codex_account';
            """
        ),
        SQLiteMigration(
            version: 5,
            sql: """
            ALTER TABLE capability_servers
            ADD COLUMN plugin_id TEXT
                REFERENCES plugin_packages(id) ON DELETE CASCADE;

            CREATE INDEX capability_servers_plugin_id
                ON capability_servers(plugin_id);

            CREATE TABLE plugin_mcp_components (
                plugin_id TEXT NOT NULL
                    REFERENCES plugin_packages(id) ON DELETE CASCADE,
                component_id TEXT NOT NULL,
                projected_server_id TEXT NOT NULL UNIQUE,
                transport TEXT NOT NULL CHECK (
                    transport IN ('stdio', 'streamable_http')
                ),
                absolute_command TEXT,
                endpoint TEXT,
                arguments_json TEXT NOT NULL CHECK (
                    json_valid(arguments_json)
                    AND json_type(arguments_json) = 'array'
                    AND length(CAST(arguments_json AS BLOB)) <= 65536
                ),
                relative_executable_path TEXT,
                unresolved_secret_names_json TEXT NOT NULL CHECK (
                    json_valid(unresolved_secret_names_json)
                    AND json_type(unresolved_secret_names_json) = 'array'
                    AND length(CAST(unresolved_secret_names_json AS BLOB)) <= 65536
                ),
                review_state TEXT NOT NULL CHECK (
                    review_state IN ('pending', 'approved')
                ),
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (plugin_id, component_id),
                CHECK (
                    (transport = 'stdio' AND endpoint IS NULL
                        AND ((absolute_command IS NOT NULL)
                            != (relative_executable_path IS NOT NULL)))
                    OR (transport = 'streamable_http'
                        AND absolute_command IS NULL
                        AND relative_executable_path IS NULL
                        AND endpoint LIKE 'https://%')
                )
            );

            CREATE TABLE plugin_app_metadata (
                plugin_id TEXT NOT NULL
                    REFERENCES plugin_packages(id) ON DELETE CASCADE,
                app_id TEXT NOT NULL,
                name TEXT NOT NULL,
                PRIMARY KEY (plugin_id, app_id)
            );
            """
        ),
        SQLiteMigration(
            version: 6,
            sql: """
            ALTER TABLE miller_preferences RENAME TO miller_preferences_v5;

            CREATE TABLE miller_preferences (
                key TEXT PRIMARY KEY CHECK (key IN (
                    'voice_transcript_saving_enabled',
                    'next_voice_session_saving_enabled',
                    'wakeword_enabled',
                    'remote_live_enabled',
                    'wake_phrase',
                    'wake_microphone_id',
                    'wake_detection_threshold',
                    'wake_keyword_score',
                    'selected_settings_tab',
                    'menu_bar_enabled',
                    'launch_at_login',
                    'avatar_enabled',
                    'avatar_selected_profile_id',
                    'avatar_reduce_motion'
                )),
                value_json TEXT NOT NULL CHECK (
                    json_valid(value_json)
                    AND length(CAST(value_json AS BLOB)) <= 65536
                ),
                updated_at TEXT NOT NULL
            );

            INSERT INTO miller_preferences(key, value_json, updated_at)
            SELECT key, value_json, updated_at FROM miller_preferences_v5;

            DROP TABLE miller_preferences_v5;
            """
        ),
        SQLiteMigration(
            version: 7,
            sql: """
            ALTER TABLE miller_preferences RENAME TO miller_preferences_v6;

            CREATE TABLE miller_preferences (
                key TEXT PRIMARY KEY CHECK (key IN (
                    'voice_transcript_saving_enabled',
                    'next_voice_session_saving_enabled',
                    'wakeword_enabled',
                    'remote_live_enabled',
                    'wake_phrase',
                    'wake_microphone_id',
                    'wake_detection_threshold',
                    'wake_keyword_score',
                    'selected_settings_tab',
                    'menu_bar_enabled',
                    'launch_at_login',
                    'avatar_enabled',
                    'avatar_selected_profile_id',
                    'avatar_reduce_motion',
                    'avatar_pane_widths'
                )),
                value_json TEXT NOT NULL CHECK (
                    json_valid(value_json)
                    AND length(CAST(value_json AS BLOB)) <= 65536
                ),
                updated_at TEXT NOT NULL
            );

            INSERT INTO miller_preferences(key, value_json, updated_at)
            SELECT key, value_json, updated_at FROM miller_preferences_v6;

            DROP TABLE miller_preferences_v6;
            """
        ),
    ]

    static let latestVersion = all.last?.version ?? 0
}
