local DataStorage = require("datastorage")
local dump        = require("dump")
local logger      = require("logger")

local SETTINGS_DIR = DataStorage:getSettingsDir()

local Sync = {}

-- Temp paths used by syncBook.  Subprocesses override these with PID-unique
-- paths (Sync.TEMP_DL = sdir .. "/claudesync_dl_" .. pid .. ".tmp") so that
-- concurrent sibling subprocesses (launch syncAll + open syncCurrentBook) do
-- not clobber each other's temp files.
Sync.TEMP_DL = SETTINGS_DIR .. "/claudesync_dl.tmp"
Sync.TEMP_UL = SETTINGS_DIR .. "/claudesync_ul.tmp"

-- Load a progress .lua file from disk.
-- Returns a table on success, nil on any error (corrupt, missing, wrong type).
-- No repair logic — a corrupt remote file is simply replaced by local data.
function Sync.loadProgress(path)
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then
        return data
    end
    if not ok then
        logger.warn("ClaudeSync: could not load progress file:", path, data)
    end
    return nil
end

-- Write a progress table to path as valid Lua (loadable via dofile).
-- Returns true on success.
function Sync.saveProgress(path, data)
    local content = "return " .. dump(data, nil, true)
    local f, err = io.open(path, "w")
    if not f then
        logger.warn("ClaudeSync: could not write progress file:", path, err)
        return false
    end
    f:write(content)
    f:close()
    return true
end

-- Three-way merge for an annotations or bookmarks array.
-- local_list:    current device's array of annotation/bookmark tables.
-- snapshot_set:  set of datetime strings saved after the last successful sync
--                ({ ["2026-01-01 10:00:00"] = true, ... }), or nil on first sync.
-- remote_list:   array downloaded from the server.
-- Returns a new array sorted by datetime ascending.
--
-- With a snapshot (subsequent syncs):
--   - Item in snapshot but absent from local  → locally deleted  → propagate deletion.
--   - Item in snapshot but absent from remote → remotely deleted → propagate deletion.
--   - Item present on both sides              → pick winner via datetime_updated;
--                                               remote wins on tie / when field absent.
--   - New item (not in snapshot) on one side  → add it.
-- Without a snapshot (first sync): falls back to union merge (same as prior behaviour).
function Sync.mergeAnnotations(local_list, snapshot_set, remote_list)
    local local_map  = {}
    local remote_map = {}
    for _, item in ipairs(local_list  or {}) do
        if item.datetime then local_map[item.datetime]  = item end
    end
    for _, item in ipairs(remote_list or {}) do
        if item.datetime then remote_map[item.datetime] = item end
    end

    local all_dts = {}
    local seen = {}
    for dt in pairs(local_map)  do if not seen[dt] then seen[dt]=true; table.insert(all_dts, dt) end end
    for dt in pairs(remote_map) do if not seen[dt] then seen[dt]=true; table.insert(all_dts, dt) end end

    local result = {}
    for _, dt in ipairs(all_dts) do
        local l       = local_map[dt]
        local r       = remote_map[dt]
        local in_snap = snapshot_set and snapshot_set[dt]

        if snapshot_set == nil then
            -- First sync: no deletion history — union merge.
            local winner
            if l and r then
                local l_note = l.note and l.note ~= ""
                local r_note = r.note and r.note ~= ""
                winner = (l_note and not r_note) and l or r
            else
                winner = l or r
            end
            table.insert(result, winner)

        elseif in_snap then
            -- Known from last sync: detect deletions.
            if l and r then
                -- Present on both sides: pick winner by datetime_updated.
                local lu, ru = l.datetime_updated, r.datetime_updated
                local winner
                if     lu and ru  then winner = (lu >= ru) and l or r
                elseif lu         then winner = l
                elseif ru         then winner = r
                else                   winner = r  -- remote wins on tie
                end
                table.insert(result, winner)
            end
            -- Absent from local XOR remote → deletion on that side → skip.

        else
            -- New since last sync (or concurrent first add on both sides).
            if l and r then
                local lu, ru = l.datetime_updated, r.datetime_updated
                local winner
                if     lu and ru  then winner = (lu >= ru) and l or r
                elseif lu         then winner = l
                elseif ru         then winner = r
                else
                    local l_note = l.note and l.note ~= ""
                    local r_note = r.note and r.note ~= ""
                    winner = (l_note and not r_note) and l or r
                end
                table.insert(result, winner)
            elseif l then
                table.insert(result, l)
            else
                table.insert(result, r)
            end
        end
    end

    table.sort(result, function(a, b) return (a.datetime or "") < (b.datetime or "") end)
    return result
end

-- Merge reading position and annotations from local and remote progress tables.
-- pos_mode:  "furthest" (default) — take whichever device is further ahead.
--            "local"              — always keep local position; only merge annotations/bookmarks.
-- snap_anns: snapshot_set for annotations (see mergeAnnotations); nil on first sync.
-- snap_bms:  snapshot_set for bookmarks.
-- Returns the merged table (new object; does not mutate either input).
function Sync.mergeProgress(local_data, remote_data, pos_mode, snap_anns, snap_bms)
    local merged = {}

    -- Reading position.
    local winner
    if pos_mode == "local" then
        winner = local_data
    else  -- "furthest" (default)
        local local_pct  = local_data.percent_finished  or 0
        local remote_pct = remote_data.percent_finished or 0
        winner = remote_pct > local_pct and remote_data or local_data
    end

    merged.percent_finished         = winner.percent_finished
    merged.percent_finished_display = winner.percent_finished_display
    merged.last_xpointer            = winner.last_xpointer
    merged.last_page                = winner.last_page

    -- Summary: propagate "complete" status; otherwise keep winner's status.
    local local_status  = local_data.summary  and local_data.summary.status  or "reading"
    local remote_status = remote_data.summary and remote_data.summary.status or "reading"
    local merged_status
    if local_status == "complete" or remote_status == "complete" then
        merged_status = "complete"
    else
        merged_status = winner.summary and winner.summary.status or "reading"
    end
    merged.summary = {
        status   = merged_status,
        notes    = (winner.summary and winner.summary.notes) or "",
        modified = (winner.summary and winner.summary.modified) or "",
    }

    merged.annotations = Sync.mergeAnnotations(
        local_data.annotations, snap_anns, remote_data.annotations)
    merged.bookmarks   = Sync.mergeAnnotations(
        local_data.bookmarks,   snap_bms,  remote_data.bookmarks)

    return merged
end

-- Sync one book given its file path.
--
-- ds (optional): a pre-opened DocSettings object for the CURRENT book (i.e.
-- self.ui.doc_settings from a plugin event handler).  When provided, we read
-- and write the live in-memory object so that unsaved position advances are
-- captured.  When nil, we open a fresh DocSettings from disk (safe for books
-- that are not currently open, e.g. during syncAll).
--
-- mode: "auto" (default) | "push" | "pull"
--   auto — download + merge + write local + upload (bidirectional)
--   push — upload local data only; remote is overwritten, local DS unchanged
--   pull — download remote and apply to local DS; no upload
-- pos_mode: "furthest" (default) | "local" — controls position merge in auto mode only.
--
-- Returns true on success, or (false, err_string) on failure.
-- err_string format: "server_error:CODE" for HTTP errors.
function Sync.syncBook(backend, root, doc_path, ds, mode, pos_mode)
    mode = mode or "auto"
    -- Read temp paths at call time so subprocess overrides take effect.
    local TEMP_DL = Sync.TEMP_DL
    local TEMP_UL = Sync.TEMP_UL
    local DocSettings = require("docsettings")
    if not ds then
        ds = DocSettings:open(doc_path)
    end

    local md5 = ds:readSetting("partial_md5_checksum")
    if not md5 or md5 == "" then
        logger.dbg("ClaudeSync: no md5 for", doc_path, "— skipping")
        return false
    end

    local remote_path = root .. "/" .. md5 .. ".lua"

    -- Push: upload local data, skip download and local DS update.
    if mode == "push" then
        local local_data = {
            percent_finished         = ds:readSetting("percent_finished") or 0,
            percent_finished_display = ds:readSetting("percent_finished_display"),
            last_xpointer            = ds:readSetting("last_xpointer"),
            last_page                = ds:readSetting("last_page"),
            summary                  = ds:readSetting("summary")     or {},
            annotations              = ds:readSetting("annotations") or {},
            bookmarks                = ds:readSetting("bookmarks")   or {},
        }
        if not backend:ensureDir(root) then
            return false, "server_error:mkdir"
        end
        os.remove(TEMP_UL)
        Sync.saveProgress(TEMP_UL, local_data)
        local ul_ok, ul_code = backend:upload(remote_path, TEMP_UL)
        os.remove(TEMP_UL)
        if not ul_ok then
            logger.warn("ClaudeSync: push failed for", doc_path)
            return false, "server_error:" .. tostring(ul_code)
        end
        logger.dbg("ClaudeSync: pushed", doc_path)
        return true
    end

    -- Pull: download remote and apply to local DS, skip upload.
    if mode == "pull" then
        os.remove(TEMP_DL)
        local dl_ok, dl_code = backend:download(remote_path, TEMP_DL)
        local remote_data
        if dl_ok then
            remote_data = Sync.loadProgress(TEMP_DL)
        end
        os.remove(TEMP_DL)
        if not dl_ok then
            if dl_code == 404 then
                return true  -- no remote file yet; silent skip
            end
            return false, "server_error:" .. tostring(dl_code)
        end
        if not remote_data then
            -- Downloaded but corrupted — skip rather than overwrite local with garbage.
            logger.warn("ClaudeSync: remote corrupted for", doc_path, "— pull skipped")
            return true
        end
        ds:saveSetting("percent_finished",         remote_data.percent_finished)
        ds:saveSetting("percent_finished_display", remote_data.percent_finished_display)
        ds:saveSetting("last_xpointer",            remote_data.last_xpointer)
        ds:saveSetting("last_page",                remote_data.last_page)
        ds:saveSetting("summary",                  remote_data.summary)
        ds:saveSetting("annotations",              remote_data.annotations)
        ds:saveSetting("bookmarks",                remote_data.bookmarks)
        ds:saveSetting("last_sync",                os.time())
        -- Invalidate snapshot: the pulled state replaced local state without a merge,
        -- so the snapshot no longer represents what both sides agreed on.  The next
        -- auto-sync will treat all annotations as new (union merge), which is correct.
        ds:delSetting("claudesync_ann_snapshot")
        ds:delSetting("claudesync_bm_snapshot")
        ds:flush()
        logger.dbg("ClaudeSync: pulled", doc_path)
        return true
    end

    -- Auto: download + merge + write local + upload.
    local local_data = {
        percent_finished         = ds:readSetting("percent_finished") or 0,
        percent_finished_display = ds:readSetting("percent_finished_display"),
        last_xpointer            = ds:readSetting("last_xpointer"),
        last_page                = ds:readSetting("last_page"),
        summary                  = ds:readSetting("summary")     or {},
        annotations              = ds:readSetting("annotations") or {},
        bookmarks                = ds:readSetting("bookmarks")   or {},
    }
    -- Read per-book snapshots for three-way merge (nil on first sync → union fallback).
    local snap_anns = ds:readSetting("claudesync_ann_snapshot")
    local snap_bms  = ds:readSetting("claudesync_bm_snapshot")
    os.remove(TEMP_DL)
    local dl_ok, dl_code = backend:download(remote_path, TEMP_DL)
    local remote_data
    if dl_ok then
        remote_data = Sync.loadProgress(TEMP_DL)
        -- If loadProgress returns nil the remote file is corrupted; overwrite with local data.
    elseif dl_code ~= 404 then
        -- Real server error — not "file doesn't exist yet on first sync".
        os.remove(TEMP_DL)
        return false, "server_error:" .. tostring(dl_code)
    end
    os.remove(TEMP_DL)

    local merged = remote_data
        and Sync.mergeProgress(local_data, remote_data, pos_mode, snap_anns, snap_bms)
        or  local_data
    merged.last_sync = os.time()

    ds:saveSetting("percent_finished",         merged.percent_finished)
    ds:saveSetting("percent_finished_display", merged.percent_finished_display)
    ds:saveSetting("last_xpointer",            merged.last_xpointer)
    ds:saveSetting("last_page",                merged.last_page)
    ds:saveSetting("summary",                  merged.summary)
    ds:saveSetting("annotations",              merged.annotations)
    ds:saveSetting("bookmarks",                merged.bookmarks)
    -- Tell KOReader to re-sort annotations by document position on next open.
    -- Our merge sorts by datetime; KOReader's renderer requires position order.
    ds:makeTrue("annotations_externally_modified")
    ds:flush()

    if not backend:ensureDir(root) then
        return false, "server_error:mkdir"
    end

    os.remove(TEMP_UL)
    Sync.saveProgress(TEMP_UL, merged)
    local ul_ok, ul_code = backend:upload(remote_path, TEMP_UL)
    os.remove(TEMP_UL)

    if not ul_ok then
        logger.warn("ClaudeSync: upload failed for", doc_path)
        return false, "server_error:" .. tostring(ul_code)
    end

    -- Upload confirmed: save lightweight snapshot (datetime-key sets) so the next
    -- sync can detect deletions and edits via three-way merge.
    local new_ann_snap, new_bm_snap = {}, {}
    for _, a in ipairs(merged.annotations or {}) do
        if a.datetime then new_ann_snap[a.datetime] = true end
    end
    for _, b in ipairs(merged.bookmarks   or {}) do
        if b.datetime then new_bm_snap[b.datetime]  = true end
    end
    ds:saveSetting("claudesync_ann_snapshot", new_ann_snap)
    ds:saveSetting("claudesync_bm_snapshot",  new_bm_snap)
    ds:flush()

    logger.dbg("ClaudeSync: synced", doc_path)
    return true
end

-- Sync all books in ReadHistory.
-- mode:         "auto" (default) | "push" | "pull" — passed through to syncBook.
-- exclude_path: optional file path to skip (used to exclude the currently-open
--               book so the RD subprocess and FM subprocess don't race).
-- pos_mode:     "furthest" (default) | "local" — passed through to syncBook/mergeProgress.
-- Returns a table: { synced=N, skipped=N, errors=N, last_error=string|nil }
function Sync.syncAll(backend, root, mode, exclude_path, pos_mode)
    mode = mode or "auto"
    local ReadHistory = require("readhistory")
    local results = { synced = 0, skipped = 0, errors = 0, last_error = nil }

    for _, entry in ipairs(ReadHistory.hist) do
        if entry.file and not entry.dim and entry.file ~= exclude_path then
            local pcall_ok, book_ok, err_str = pcall(Sync.syncBook, backend, root, entry.file, nil, mode, pos_mode)
            if pcall_ok and book_ok then
                results.synced = results.synced + 1
            else
                results.errors = results.errors + 1
                if pcall_ok then
                    results.last_error = err_str
                    logger.warn("ClaudeSync: sync failed for", entry.file, err_str)
                else
                    logger.warn("ClaudeSync: error syncing", entry.file, book_ok)
                end
            end
        else
            results.skipped = results.skipped + 1
        end
    end

    logger.info(string.format(
        "ClaudeSync: syncAll done — mode=%s synced=%d skipped=%d errors=%d",
        mode, results.synced, results.skipped, results.errors))
    return results
end

-- Sync a single extra file from a pre-resolved entry { remote=string, local_path=string }.
-- mode: "push" (default) | "pull"
-- Returns true on success, or (false, err_string) on failure.
function Sync.syncExtraFile(backend, root, entry, mode)
    local remote     = root .. "/" .. entry.remote
    local local_path = entry.local_path
    local is_sqlite  = local_path:sub(-8) == ".sqlite3"
    if mode == "pull" then
        local ok, code = backend:download(remote, local_path)
        if not ok and code ~= 404 then
            return false, "server_error:" .. tostring(code)
        end
        if ok and is_sqlite then
            -- Remove any stale WAL/SHM files left over from the old database so
            -- SQLite does not apply old WAL frames to the newly-downloaded file.
            os.remove(local_path .. "-wal")
            os.remove(local_path .. "-shm")
        end
    else  -- push
        if is_sqlite then
            -- Force a full WAL checkpoint so the main .sqlite3 file is complete
            -- before we read it as raw bytes for upload.  Without this, recent
            -- writes that are still in the -wal sidecar file would be missing
            -- from the uploaded copy.
            local SQ3 = require("lua-ljsqlite3/init")
            local conn = SQ3.open(local_path)
            pcall(conn.exec, conn, "PRAGMA wal_checkpoint(FULL);")
            conn:close()
        end
        if not backend:ensureDir(root) then
            return false, "server_error:mkdir"
        end
        local ok, code = backend:upload(remote, local_path)
        if not ok then return false, "server_error:" .. tostring(code) end
    end
    return true
end

-- Binary file copy. Returns true on success.
function Sync.copyFile(src, dst)
    local r, err = io.open(src, "rb")
    if not r then
        logger.warn("ClaudeSync: copyFile: cannot open src:", src, err)
        return false
    end
    local w, err2 = io.open(dst, "wb")
    if not w then
        r:close()
        logger.warn("ClaudeSync: copyFile: cannot open dst:", dst, err2)
        return false
    end
    while true do
        local block = r:read(65536)
        if not block then break end
        w:write(block)
    end
    r:close()
    w:close()
    return true
end

-- Three-way merge for vocabulary_builder.sqlite3.
-- Ported from plugins/vocabbuilder.koplugin/db.lua :: VocabularyBuilder.onSync.
-- Returns true on success (or when income is absent/invalid — safe no-op).
function Sync.mergeVocabularyDb(local_path, cached_path, income_path)
    local SQ3 = require("lua-ljsqlite3/init")

    local conn_income = SQ3.open(income_path)
    local ok1, v1 = pcall(conn_income.rowexec, conn_income, "PRAGMA schema_version")
    if not ok1 or tonumber(v1) == 0 then
        logger.dbg("ClaudeSync: mergeVocabularyDb: income DB invalid:", v1)
        conn_income:close()
        return true
    end
    pcall(conn_income.exec, conn_income, "ALTER TABLE vocabulary ADD highlight TEXT;")
    conn_income:close()

    local sql = "attach '" .. income_path:gsub("'", "''") .. "' as income_db;"
    local attached_cache = false

    local conn_cached = SQ3.open(cached_path)
    local ok2, v2 = pcall(conn_cached.rowexec, conn_cached, "PRAGMA schema_version")
    if ok2 and tonumber(v2) ~= 0 then
        attached_cache = true
        sql = sql .. "attach '" .. cached_path:gsub("'", "''") .. [[' as cached_db;
            DELETE FROM income_db.vocabulary WHERE word IN (
                SELECT word FROM cached_db.vocabulary WHERE word NOT IN (
                    SELECT word FROM vocabulary
                )
            );
            DELETE FROM vocabulary WHERE word IN (
                SELECT word FROM cached_db.vocabulary WHERE word NOT IN (
                    SELECT word FROM income_db.vocabulary
                )
            );
        ]]
    else
        logger.dbg("ClaudeSync: mergeVocabularyDb: no cached DB (first sync):", v2)
    end
    conn_cached:close()

    local conn = SQ3.open(local_path)
    pcall(conn.exec, conn, "PRAGMA busy_timeout = 5000;")
    local ok3, v3 = pcall(conn.exec, conn, "PRAGMA schema_version")
    if not ok3 or tonumber(v3) == 0 then
        logger.err("ClaudeSync: mergeVocabularyDb: local DB invalid:", v3)
        conn:close()
        return false
    end

    sql = sql .. [[
        INSERT INTO title (name)
        SELECT name FROM income_db.title WHERE name NOT IN (SELECT name FROM title);

        UPDATE income_db.vocabulary SET title_id = ifnull(
            (SELECT mid FROM (
                SELECT m.id as mid, title_id as i_tid FROM title as m
                INNER JOIN income_db.title as i ON m.name = i.name
                LEFT JOIN income_db.vocabulary ON title_id = i.id
            ) WHERE income_db.vocabulary.title_id = i_tid
        ), title_id);

        INSERT INTO vocabulary
              (word, create_time, review_time, due_time, review_count, prev_context, next_context, title_id, streak_count, highlight)
        SELECT word, create_time, review_time, due_time, review_count, prev_context, next_context, title_id, streak_count, highlight
        FROM income_db.vocabulary WHERE true
        ON CONFLICT(word) DO UPDATE SET
        due_time = MAX(due_time, excluded.due_time),
        review_count = CASE
            WHEN create_time = excluded.create_time THEN MAX(review_count, excluded.review_count)
            ELSE review_count + excluded.review_count
        END,
        prev_context = ifnull(excluded.prev_context, prev_context),
        next_context = ifnull(excluded.next_context, next_context),
        highlight = ifnull(excluded.highlight, highlight),
        streak_count = CASE
            WHEN review_time > excluded.review_time THEN streak_count
            ELSE excluded.streak_count
        END,
        review_time = MAX(review_time, excluded.review_time),
        create_time = excluded.create_time,
        title_id = excluded.title_id
    ]]

    conn:exec(sql)
    pcall(conn.exec, conn, "COMMIT;")
    conn:exec("DETACH income_db;" .. (attached_cache and "DETACH cached_db;" or ""))
    conn:exec("PRAGMA temp_store = 2;")
    local ok_vac, vac_err = pcall(conn.exec, conn, "VACUUM;")
    if not ok_vac then
        logger.warn("ClaudeSync: mergeVocabularyDb: VACUUM failed:", vac_err)
    end
    conn:close()
    return true
end

-- Three-way merge for statistics.sqlite3.
-- Ported from plugins/statistics.koplugin/main.lua :: ReaderStatistics.onSync.
-- Returns true on success (or when income is absent/invalid — safe no-op).
function Sync.mergeStatisticsDb(local_path, cached_path, income_path)
    local SQ3 = require("lua-ljsqlite3/init")

    local conn_income = SQ3.open(income_path)
    local ok1, v1 = pcall(conn_income.rowexec, conn_income, "PRAGMA schema_version")
    if not ok1 or tonumber(v1) == 0 then
        logger.dbg("ClaudeSync: mergeStatisticsDb: income DB invalid:", v1)
        conn_income:close()
        return true
    end
    conn_income:close()

    local sql = "attach '" .. income_path:gsub("'", "''") .. "' as income_db;"
    local attached_cache = false

    local conn_cached = SQ3.open(cached_path)
    local ok2, v2 = pcall(conn_cached.rowexec, conn_cached, "PRAGMA schema_version")
    if ok2 and tonumber(v2) ~= 0 then
        attached_cache = true
        sql = sql .. "attach '" .. cached_path:gsub("'", "''") .. [[' as cached_db;
            DELETE FROM income_db.page_stat_data WHERE id_book IN (
                SELECT id FROM income_db.book WHERE (title, authors, md5) IN (
                    SELECT title, authors, md5 FROM cached_db.book WHERE (title, authors, md5) NOT IN (
                        SELECT title, authors, md5 FROM book
                    )
                )
            );
            DELETE FROM income_db.book WHERE (title, authors, md5) IN (
                SELECT title, authors, md5 FROM cached_db.book WHERE (title, authors, md5) NOT IN (
                    SELECT title, authors, md5 FROM book
                )
            );
            DELETE FROM page_stat_data WHERE id_book IN (
                SELECT id FROM book WHERE (title, authors, md5) IN (
                    SELECT title, authors, md5 FROM cached_db.book WHERE (title, authors, md5) NOT IN (
                        SELECT title, authors, md5 FROM income_db.book
                    )
                )
            );
            DELETE FROM book WHERE (title, authors, md5) IN (
                SELECT title, authors, md5 FROM cached_db.book WHERE (title, authors, md5) NOT IN (
                    SELECT title, authors, md5 FROM income_db.book
                )
            );
        ]]
    else
        logger.dbg("ClaudeSync: mergeStatisticsDb: no cached DB (first sync):", v2)
    end
    conn_cached:close()

    local conn = SQ3.open(local_path)
    pcall(conn.exec, conn, "PRAGMA busy_timeout = 5000;")
    local ok3, v3 = pcall(conn.exec, conn, "PRAGMA schema_version")
    if not ok3 or tonumber(v3) == 0 then
        logger.err("ClaudeSync: mergeStatisticsDb: local DB invalid:", v3)
        conn:close()
        return false
    end

    sql = sql .. [[
        UPDATE book AS b
        SET last_open = i.last_open
        FROM income_db.book AS i
        WHERE (b.title, b.authors, b.md5) = (i.title, i.authors, i.md5)
          AND i.last_open > b.last_open;

        INSERT INTO book (
            title, authors, notes, last_open, highlights, pages, series, language, md5, total_read_time, total_read_pages
        ) SELECT
            title, authors, notes, last_open, highlights, pages, series, language, md5, total_read_time, total_read_pages
        FROM income_db.book
        WHERE (title, authors, md5) NOT IN (
            SELECT title, authors, md5 FROM book
        );

        CREATE TEMP TABLE book_id_map AS
            SELECT m.id as mid, i.id as iid FROM book m
            INNER JOIN income_db.book i
            ON (m.title, m.authors, m.md5) = (i.title, i.authors, i.md5);
    ]]

    if attached_cache then
        sql = sql .. [[
        DELETE FROM income_db.page_stat_data WHERE (id_book, page, start_time) IN (
            SELECT map.iid, page, start_time FROM cached_db.page_stat_data
            INNER JOIN book_id_map AS map ON id_book = map.mid
            WHERE (id_book, page, start_time) NOT IN (
                SELECT id_book, page, start_time FROM page_stat_data
            )
        );
        DELETE FROM page_stat_data WHERE (id_book, page, start_time) IN (
            SELECT id_book, page, start_time FROM cached_db.page_stat_data WHERE (id_book, page, start_time) NOT IN (
                SELECT map.mid, page, start_time FROM income_db.page_stat_data
                LEFT JOIN book_id_map AS map ON id_book = map.iid
            )
        );
        ]]
    end

    sql = sql .. [[
        INSERT INTO page_stat_data (id_book, page, start_time, duration, total_pages)
            SELECT map.mid, page, start_time, duration, total_pages
            FROM income_db.page_stat_data
            INNER JOIN book_id_map AS map ON id_book = map.iid
            WHERE map.mid IS NOT null
        ON CONFLICT(id_book, page, start_time) DO UPDATE SET
        duration = MAX(duration, excluded.duration);

        UPDATE book SET (total_read_pages, total_read_time) =
        (SELECT count(DISTINCT page),
                sum(duration)
         FROM   page_stat
         WHERE  id_book = book.id);
    ]]

    conn:exec(sql)
    pcall(conn.exec, conn, "COMMIT;")
    conn:exec("DETACH income_db;" .. (attached_cache and "DETACH cached_db;" or ""))
    conn:close()
    return true
end

-- Three-way merge for profiles.lua (Lua table keyed by profile name).
-- Profile names are device-independent so merging across devices is safe.
-- Returns true on success.
function Sync.mergeProfilesFile(local_path, cached_path, income_path)
    local local_data  = Sync.loadProgress(local_path)  or {}
    local income_data = Sync.loadProgress(income_path) or {}
    local cached_data = Sync.loadProgress(cached_path)

    if cached_data then
        for name in pairs(cached_data) do
            -- This device deleted the profile → propagate deletion into income
            if local_data[name] == nil then
                income_data[name] = nil
            end
            -- Other device deleted the profile → propagate deletion into local
            if income_data[name] == nil then
                local_data[name] = nil
            end
        end
    end

    -- Add new profiles from income that local doesn't have yet (local wins on conflict)
    for name, profile in pairs(income_data) do
        if local_data[name] == nil then
            local_data[name] = profile
        end
    end

    return Sync.saveProgress(local_path, local_data)
end

-- Bidirectional sync for a mergeable extra file (vocabulary, statistics, profiles).
-- entry must have: remote (string), local_path (string), merge ("vocabulary"|"statistics"|"profiles")
-- sdir: settings directory (for temp file placement)
-- pid_str: unique string for temp file naming
-- Returns true on success, or (false, err_string) on failure.
function Sync.syncSmartFile(backend, root, entry, sdir, pid_str)
    local remote      = root .. "/" .. entry.remote
    local local_path  = entry.local_path
    local income_path = sdir .. "/claudesync_income_" .. pid_str .. ".tmp"
    local cached_path = local_path .. ".sync"

    -- Check if local file exists
    local lf = io.open(local_path, "r")
    local local_exists = lf ~= nil
    if lf then lf:close() end

    -- Download server version
    local dl_ok, dl_code = backend:download(remote, income_path)
    if not dl_ok then
        os.remove(income_path)
        if dl_code == 404 then
            -- Nothing on server yet
            if not local_exists then return true end  -- nothing on either side
            if not backend:ensureDir(root) then return false, "server_error:mkdir" end
            local ul_ok, ul_code = backend:upload(remote, local_path)
            if not ul_ok then return false, "server_error:" .. tostring(ul_code) end
            Sync.copyFile(local_path, cached_path)
            return true
        end
        return false, "server_error:" .. tostring(dl_code)
    end

    -- Server has data but local file is missing — accept server version as-is
    if not local_exists then
        Sync.copyFile(income_path, local_path)
        Sync.copyFile(local_path, cached_path)
        os.remove(income_path)
        return true
    end

    -- Both sides have data: three-way merge
    local merge_ok
    if entry.merge == "vocabulary" then
        merge_ok = Sync.mergeVocabularyDb(local_path, cached_path, income_path)
    elseif entry.merge == "statistics" then
        merge_ok = Sync.mergeStatisticsDb(local_path, cached_path, income_path)
    elseif entry.merge == "profiles" then
        merge_ok = Sync.mergeProfilesFile(local_path, cached_path, income_path)
    end
    os.remove(income_path)

    if not merge_ok then
        logger.warn("ClaudeSync: merge failed for", entry.remote)
        return false, "merge_error"
    end

    -- For SQLite databases: force a full WAL checkpoint so the main file is
    -- complete before we upload it as raw bytes.  (mergeVocabularyDb already
    -- runs VACUUM which checkpoints, but mergeStatisticsDb does not.)
    if entry.merge ~= "profiles" then
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(local_path)
        pcall(conn.exec, conn, "PRAGMA wal_checkpoint(FULL);")
        conn:close()
    end

    -- Upload merged result
    if not backend:ensureDir(root) then return false, "server_error:mkdir" end
    local ul_ok, ul_code = backend:upload(remote, local_path)
    if not ul_ok then return false, "server_error:" .. tostring(ul_code) end

    -- Save cached snapshot for next sync's deletion detection
    Sync.copyFile(local_path, cached_path)
    return true
end

return Sync
