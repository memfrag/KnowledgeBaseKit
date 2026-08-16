import Foundation
import GRDB

/// The database schema, as GRDB migrations.
///
/// Vector tables are deliberately *not* here: their column type embeds the embedding
/// dimension, which comes from configuration and can change. They are created and recreated
/// by ``VectorIndex/ensureSchema(in:dimensions:)`` under the version-drift rules instead.
public enum Schema {
    /// Bumped when a migration is added. Stored as the `schema` version key.
    public static let version = 1

    public static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE store_metadata (
                        key   TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    );

                    CREATE TABLE documents (
                        id            TEXT PRIMARY KEY,
                        relative_path TEXT NOT NULL UNIQUE,
                        content_hash  TEXT NOT NULL,
                        modified_at   DOUBLE NOT NULL,
                        title         TEXT,
                        metadata_json TEXT NOT NULL
                    );

                    CREATE TABLE chunks (
                        id              TEXT PRIMARY KEY,
                        document_id     TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                        ordinal         INTEGER NOT NULL,
                        heading_path    TEXT NOT NULL,
                        heading_display TEXT NOT NULL,
                        content         TEXT NOT NULL,
                        content_hash    TEXT NOT NULL,
                        occurrence      INTEGER NOT NULL,
                        -- The content hash as of the last successful embed/extract. NULL means
                        -- never done; a value different from content_hash means stale. This is
                        -- what makes coverage reportable and re-indexing resumable.
                        embedded_hash   TEXT,
                        extracted_hash  TEXT
                    );
                    CREATE INDEX chunks_document ON chunks(document_id);
                    CREATE INDEX chunks_embedded ON chunks(embedded_hash);
                    CREATE INDEX chunks_extracted ON chunks(extracted_hash);

                    -- Standalone rather than external-content FTS5. External content avoids
                    -- duplicating the text, but couples the index to chunks.rowid and needs
                    -- exactly-right delete triggers. At this corpus size the duplication is a
                    -- few tens of megabytes and correctness is worth more.
                    CREATE VIRTUAL TABLE chunks_fts USING fts5(
                        chunk_id UNINDEXED,
                        heading,
                        content,
                        tokenize = 'porter unicode61'
                    );

                    CREATE TRIGGER chunks_fts_insert AFTER INSERT ON chunks BEGIN
                        INSERT INTO chunks_fts(chunk_id, heading, content)
                        VALUES (new.id, new.heading_display, new.content);
                    END;

                    CREATE TRIGGER chunks_fts_update AFTER UPDATE OF content, heading_display ON chunks BEGIN
                        UPDATE chunks_fts
                           SET heading = new.heading_display, content = new.content
                         WHERE chunk_id = new.id;
                    END;

                    CREATE TRIGGER chunks_fts_delete AFTER DELETE ON chunks BEGIN
                        DELETE FROM chunks_fts WHERE chunk_id = old.id;
                    END;

                    CREATE TABLE entities (
                        id              TEXT PRIMARY KEY,
                        type            TEXT NOT NULL,
                        canonical_name  TEXT NOT NULL,
                        normalized_name TEXT NOT NULL
                    );
                    CREATE INDEX entities_normalized ON entities(normalized_name);

                    CREATE TABLE aliases (
                        entity_id       TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                        name            TEXT NOT NULL,
                        normalized_name TEXT NOT NULL,
                        PRIMARY KEY (entity_id, normalized_name)
                    );
                    CREATE INDEX aliases_normalized ON aliases(normalized_name);

                    -- `source` records who asserted the mention. Re-extracting a chunk
                    -- clears what the model said about it, but must not erase what the
                    -- document itself declared in its front matter.
                    CREATE TABLE mentions (
                        entity_id    TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                        chunk_id     TEXT NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
                        surface_form TEXT NOT NULL,
                        source       TEXT NOT NULL DEFAULT 'extraction',
                        PRIMARY KEY (entity_id, chunk_id, surface_form)
                    );
                    CREATE INDEX mentions_chunk ON mentions(chunk_id);

                    -- One row per (triple, supporting chunk). A claim asserted by three chunks
                    -- is three rows, which is what lets the collector delete a fact when its
                    -- last support disappears without erasing it while other chunks assert it.
                    CREATE TABLE relations (
                        id                  TEXT PRIMARY KEY,
                        source_id           TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                        type                TEXT NOT NULL,
                        target_id           TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                        supporting_chunk_id TEXT NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
                        confidence          DOUBLE NOT NULL
                    );
                    CREATE INDEX relations_source ON relations(source_id);
                    CREATE INDEX relations_target ON relations(target_id);
                    CREATE INDEX relations_chunk ON relations(supporting_chunk_id);

                    CREATE TABLE jobs (
                        id         INTEGER PRIMARY KEY AUTOINCREMENT,
                        kind       TEXT NOT NULL,
                        target_id  TEXT NOT NULL,
                        state      TEXT NOT NULL,
                        attempts   INTEGER NOT NULL DEFAULT 0,
                        next_after DOUBLE NOT NULL DEFAULT 0,
                        last_error TEXT,
                        created_at DOUBLE NOT NULL,
                        UNIQUE (kind, target_id)
                    );
                    CREATE INDEX jobs_ready ON jobs(state, next_after);

                    -- A job outlives nothing: deleting a chunk retires its pending work.
                    CREATE TRIGGER jobs_chunk_delete AFTER DELETE ON chunks BEGIN
                        DELETE FROM jobs WHERE target_id = old.id;
                    END;
                    """
            )
        }

        return migrator
    }()
}

// MARK: - Column names

/// Table and column names, so the repositories are not a field of string literals.
enum T {
    static let documents = "documents"
    static let chunks = "chunks"
    static let chunksFTS = "chunks_fts"
    static let entities = "entities"
    static let aliases = "aliases"
    static let mentions = "mentions"
    static let relations = "relations"
    static let jobs = "jobs"
    static let metadata = "store_metadata"
    static let chunkEmbeddings = "chunk_embeddings"
    static let entityEmbeddings = "entity_embeddings"
}
