local ConfirmBox        = require("ui/widget/confirmbox")
local DataStorage       = require("datastorage")
local Dispatcher        = require("dispatcher")
local Event             = require("ui/event")
local Font              = require("ui/font")
local Geom              = require("ui/geometry")
local HorizontalGroup   = require("ui/widget/horizontalgroup")
local HorizontalSpan    = require("ui/widget/horizontalspan")
local ImageWidget       = require("ui/widget/imagewidget")
local InfoMessage       = require("ui/widget/infomessage")
local LeftContainer     = require("ui/widget/container/leftcontainer")
local MultiInputDialog  = require("ui/widget/multiinputdialog")
local NetworkMgr        = require("ui/network/manager")
local Notification      = require("ui/widget/notification")
local Screen            = require("device").screen
local TextWidget        = require("ui/widget/textwidget")
local UIManager         = require("ui/uimanager")
local WidgetContainer   = require("ui/widget/container/widgetcontainer")
local logger            = require("logger")
local _                 = require("gettext")

local ClaudeSync = WidgetContainer:extend{
    name        = "claudesync",
    is_doc_only = false,
}

local DEFAULTS = {
    enabled             = false,
    address             = "",
    username            = "",
    password            = "",
    root_folder         = "koreader-sync",
    auto_sync_enabled   = true,   -- master gate for all auto-sync triggers
    auto_sync_on_open   = true,   -- sync current book when opening
    auto_sync_on_launch = true,   -- full syncAll on KOReader launch
    auto_sync_on_close  = true,   -- sync current book when closing
    auto_sync_on_wifi   = false,  -- full syncAll when WiFi connects
    auto_sync_on_resume    = false,  -- full syncAll when device wakes
    position_sync_mode     = "furthest",   -- "furthest" | "local"
    status_location     = "corner",         -- "footer" | "corner" | "none"
    status_format       = "icon_text",    -- "icon_text" | "icon" | "text"
    -- Auto-sync options: what gets included in Sync now and auto-sync (books always on)
    auto_sync_statistics  = false,
    auto_sync_vocabulary  = false,
    auto_sync_profiles    = false,
    auto_sync_collections = false,
    auto_sync_history     = false,
    -- Push / Pull: what gets included in manual push/pull (all default off)
    push_pull_books       = false,
    push_pull_statistics  = false,
    push_pull_vocabulary  = false,
    push_pull_profiles    = false,
    push_pull_collections = false,
    push_pull_history     = false,
    push_pull_koreader    = false,
}

local STATUS_ICONS = { syncing = "⟳", complete = "✓", no_wifi = "⚠", server_error = "⚠" }
local STATUS_TEXT  = { syncing = "Syncing...", complete = "Sync Successful", no_wifi = "Device Offline" }

local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@?(.+/)") or ""
local STATUS_ICON_FILES = {
    syncing_a    = PLUGIN_DIR .. "icons/sync-a.svg",
    syncing_b    = PLUGIN_DIR .. "icons/sync-b.svg",
    syncing_c    = PLUGIN_DIR .. "icons/sync-c.svg",
    syncing_d    = PLUGIN_DIR .. "icons/sync-d.svg",
    complete     = PLUGIN_DIR .. "icons/sync-success.svg",
    no_wifi      = PLUGIN_DIR .. "icons/no-wifi.svg",
    server_error = PLUGIN_DIR .. "icons/sync-error.svg",
}

local SYNCING_FRAMES = { "syncing_a", "syncing_b", "syncing_c", "syncing_d" }

-- Shared across FM and RD instances (same Lua module cache).
-- Tracks the path of the book currently open in the reader, so that the FM
-- instance's syncAll subprocess can skip it (the RD instance handles it via
-- _syncCurrentBook instead).
local _open_book_path = nil

-- Ordered list of extra syncable files (books are handled separately via sync.lua).
-- remote: filename inside root_folder on the server.
-- local_path: function returning the absolute local path.
local EXTRA_FILES = {
    { id = "statistics",  remote = "statistics.sqlite3",         merge = "statistics", local_path = function() return DataStorage:getSettingsDir() .. "/statistics.sqlite3"        end },
    { id = "vocabulary",  remote = "vocabulary_builder.sqlite3", merge = "vocabulary", local_path = function() return DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3" end },
    { id = "profiles",    remote = "profiles.lua",               merge = "profiles",   local_path = function() return DataStorage:getSettingsDir() .. "/profiles.lua"              end },
    { id = "collections", remote = "collection.lua",             local_path = function() return DataStorage:getSettingsDir() .. "/collection.lua"            end },
    { id = "history",     remote = "history.lua",                local_path = function() return DataStorage:getDataDir()     .. "/history.lua"               end },
    { id = "koreader",    remote = "settings.reader.lua",        local_path = function() return DataStorage:getSettingsDir() .. "/settings.reader.lua"       end },
}

-- ── Corner icon widget ───────────────────────────────────────────────────────

local CORNER_ICON_SIZE = Screen:scaleBySize(32)
local CORNER_TEXT_SIZE = 14

local CornerIconWidget = WidgetContainer:extend{}

function CornerIconWidget:init()
    self[1] = LeftContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = CORNER_ICON_SIZE },
        WidgetContainer:new{ dimen = Geom:new{ w = 0, h = 0 } },
    }
end

function CornerIconWidget:resetLayout()
    self[1].dimen.w = Screen:getWidth()
end

function CornerIconWidget:paintTo(bb, x, y)
    local status = self.plugin._bar_status
    if not status then return end
    -- Yield to CRE re-render icons when both are active simultaneously
    if self.ui.rolling and self.ui.rolling.rendering_state then return end
    local base   = status:match("^([^:]+)") or status
    local detail = status:match(":(.+)")
    local fmt    = self.plugin.settings.status_format or "icon_text"

    local function get_text_widget()
        local tc = self.plugin._corner_text_cache
        if not tc[status] then
            local text
            if base == "server_error" then
                text = "Server error" .. (detail and (": " .. detail) or "")
            else
                text = STATUS_TEXT[base] or "Sync error"
            end
            tc[status] = TextWidget:new{
                text = text,
                face = Font:getFace("cfont", CORNER_TEXT_SIZE),
            }
        end
        return tc[status]
    end

    if fmt == "text" then
        self[1][1] = get_text_widget()
    else
        local file_key = base == "syncing"
            and SYNCING_FRAMES[(self.plugin._sync_anim_frame % 4) + 1]
            or  base
        local file = STATUS_ICON_FILES[file_key]
        if not file then return end
        local ic = self.plugin._corner_icon_cache
        if not ic[file_key] then
            ic[file_key] = ImageWidget:new{
                file   = file,
                width  = CORNER_ICON_SIZE,
                height = CORNER_ICON_SIZE,
                alpha  = true,
            }
        end
        if fmt == "icon_text" then
            self[1][1] = HorizontalGroup:new{
                ic[file_key],
                HorizontalSpan:new{ width = Screen:scaleBySize(4) },
                get_text_widget(),
            }
        else
            self[1][1] = ic[file_key]
        end
    end
    WidgetContainer.paintTo(self, bb, x, y)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

function ClaudeSync:init()
    local saved = G_reader_settings:readSetting("claudesync") or {}
    self.settings = {}
    for k, v in pairs(DEFAULTS) do
        if saved[k] ~= nil then
            self.settings[k] = saved[k]
        else
            self.settings[k] = v
        end
    end
    self.pending_sync = false

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    -- Launch sync only fires from the FileManager instance.  Every book open
    -- creates a new ReaderUI plugin instance whose init() would also fire here,
    -- triggering a full syncAll that then *excludes* the current book (via the
    -- _open_book_path guard) and blocks _syncCurrentBook via _sync_pid — so the
    -- book the user just opened would never actually get synced.
    if self.ui.name == "filemanager"
       and self.settings.enabled and self.settings.auto_sync_enabled
       and self.settings.auto_sync_on_launch then
        UIManager:nextTick(function()
            self:syncIfOnline()
        end)
    end
end

-- ── Dispatcher integration ────────────────────────────────────────────────────

function ClaudeSync:onDispatcherRegisterActions()
    Dispatcher:registerAction("claudesync_sync_now", {
        category = "none",
        event    = "ClaudeSyncSyncNow",
        title    = _("ClaudeSync: sync now"),
        general  = true,
    })
    Dispatcher:registerAction("claudesync_toggle_auto", {
        category = "none",
        event    = "ClaudeSyncToggleAuto",
        title    = _("ClaudeSync: toggle auto-sync"),
        general  = true,
    })
end

function ClaudeSync:onClaudeSyncSyncNow()
    self:syncIfOnline()
end

function ClaudeSync:onClaudeSyncToggleAuto()
    self.settings.auto_sync_enabled = not self.settings.auto_sync_enabled
    self:_saveSettings()
    UIManager:show(Notification:new{
        text = self.settings.auto_sync_enabled
            and _("ClaudeSync auto-sync: on")
            or  _("ClaudeSync auto-sync: off"),
        timeout = 2,
    })
end

-- ── Event hooks ──────────────────────────────────────────────────────────────

function ClaudeSync:onReaderReady()
    _open_book_path = self.ui and self.ui.document and self.ui.document.file or nil
    self:_registerBarContent()
    if not self.settings.enabled or not self.settings.auto_sync_enabled
       or not self.settings.auto_sync_on_open then return end
    if not self:_isConfigured() then return end
    UIManager:nextTick(function()
        self:_syncCurrentBook()
    end)
end

function ClaudeSync:onCloseDocument()
    _open_book_path = nil
    self:_cancelSyncSubprocess()
    if self.settings.enabled and self.settings.auto_sync_enabled
       and self.settings.auto_sync_on_close and self:_isConfigured() then
        -- ReaderUI:onClose fires CloseDocument BEFORE saveSettings() (because
        -- self.dialog == self, so the early saveSettings branch is skipped).
        -- ReaderRolling's onSaveSettings writes the current xpointer/percent to
        -- doc_settings; without it, flush() would write the stale OPEN position
        -- and the subprocess would upload that instead of where the user stopped.
        self.ui:handleEvent(Event:new("SaveSettings"))
        self:_syncCurrentBook(true)
    end
    self:_unregisterBarContent()
    self._bar_status = nil
end

function ClaudeSync:onNetworkConnected()
    if self.pending_sync then
        self.pending_sync = false
        UIManager:nextTick(function() self:_doSyncAll() end)
    elseif self.settings.enabled and self.settings.auto_sync_enabled
           and self.settings.auto_sync_on_wifi and self:_isConfigured() then
        UIManager:nextTick(function() self:_doSyncAll() end)
    end
end

function ClaudeSync:onSuspend()
    self:_cancelSyncSubprocess()
    self.pending_sync = false
end

function ClaudeSync:onResume()
    if self.settings.enabled and self.settings.auto_sync_enabled
       and self.settings.auto_sync_on_resume and self:_isConfigured() then
        if NetworkMgr:isConnected() then
            UIManager:nextTick(function() self:_doSyncAll() end)
        else
            self.pending_sync = true
        end
    end
end

-- ── Status indicator ─────────────────────────────────────────────────────────

function ClaudeSync:_statusLabel(status, wide_sep)
    -- status may be a compound string like "server_error:401"
    local base   = status:match("^([^:]+)") or status
    local detail = status:match(":(.+)")
    local fmt    = self.settings.status_format or "icon_text"
    local icon   = STATUS_ICONS[base] or "⚠"
    local text
    if base == "server_error" then
        text = "Server error" .. (detail and (": " .. detail) or "")
    else
        text = STATUS_TEXT[base] or "Sync error"
    end
    if fmt == "text"          then return text
    elseif fmt == "icon_text" then return icon .. (wide_sep and "  " or " ") .. text
    else                           return icon
    end
end

-- Route to the active display channel.
function ClaudeSync:_setStatus(status, clear_after)
    local loc = self.settings.status_location or "none"
    if     loc == "footer" then self:_setBarStatus(status, clear_after)
    elseif loc == "corner" then self:_setCornerStatus(status, clear_after)
    end
end

-- ── Bar channel (footer) ──────────────────────────────────────────────────────

-- Register status display. Called from onReaderReady each time a book opens.
function ClaudeSync:_registerBarContent()
    local loc = self.settings.status_location or "none"
    self:_unregisterBarContent()
    if loc == "footer" then
        if not (self.ui.view and self.ui.view.footer) then return end
        local func = function()
            return self._bar_status and self:_statusLabel(self._bar_status, true)
        end
        self.ui.view.footer:addAdditionalFooterContent(func)
        self._bar_func = func
    elseif loc == "corner" then
        if not (self.ui.view and self.ui.view.registerViewModule) then return end
        self._corner_icon_cache = {}
        self._corner_text_cache = {}
        local w = CornerIconWidget:new{ plugin = self }
        self.ui.view:registerViewModule("claudesync", w)
        self._corner_widget = w
    end
end

function ClaudeSync:_unregisterBarContent()
    if self._bar_func then
        if self.ui.view and self.ui.view.footer then
            self.ui.view.footer:removeAdditionalFooterContent(self._bar_func)
        end
        self._bar_func = nil
    end
    if self._corner_widget then
        if self.ui.view and self.ui.view.view_modules then
            self.ui.view.view_modules["claudesync"] = nil
        end
        self._corner_widget     = nil
        self._corner_icon_cache = nil
        self._corner_text_cache = nil
    end
end

function ClaudeSync:_updateBar()
    if self._bar_func and self.ui.view and self.ui.view.footer then
        self.ui.view.footer:onUpdateFooter(true)
    end
end

function ClaudeSync:_updateCorner()
    if self._corner_widget and self.ui then
        UIManager:setDirty(self.ui, "ui")
    end
end

function ClaudeSync:_setCornerStatus(status, clear_after)
    self._bar_status = status
    self:_updateCorner()
    if clear_after then
        UIManager:scheduleIn(clear_after, function()
            self._bar_status = nil
            self:_updateCorner()
        end)
    end
end

function ClaudeSync:_setBarStatus(status, clear_after)
    self._bar_status = status
    self:_updateBar()
    if clear_after then
        UIManager:scheduleIn(clear_after, function()
            self._bar_status = nil
            if self._bar_func then
                self:_updateBar()
            end
        end)
    end
end

-- ── Internal sync helpers ────────────────────────────────────────────────────

function ClaudeSync:_isConfigured()
    return self.settings.enabled
        and self.settings.address ~= ""
        and self.settings.username ~= ""
        and (self.settings.root_folder or "") ~= ""
end

-- ── Background subprocess infrastructure ─────────────────────────────────────

-- Shared across all instances (FM and RD share the same Lua module cache).
-- Prevents concurrent sync subprocesses from racing to upload the same files
-- (which causes HTTP 423 Locked responses from the WebDAV server).
-- When the subprocess that owns a PID finishes or is cancelled it clears this;
-- if the owning instance is GC'd before that happens, the next would-be starter
-- detects the orphaned pid via isSubProcessDone and clears it automatically.
local _sync_any_pid = nil

-- Returns true if subprocess was started, false if blocked or fork failed.
function ClaudeSync:_runSyncSubprocess(work_fn, done_fn)
    if self._sync_pid then return false end
    local ffiutil = require("ffi/util")
    -- Cross-instance guard: don't start if any other instance's subprocess is
    -- still alive.  pcall guards against bad PIDs (already reaped, invalid).
    if _sync_any_pid then
        local ok, done = pcall(ffiutil.isSubProcessDone, _sync_any_pid)
        if ok and not done then
            return false  -- still running
        end
        _sync_any_pid = nil  -- done or error: clear stale PID
    end
    local pid, read_fd = ffiutil.runInSubProcess(work_fn, true)
    if not pid then
        logger.warn("ClaudeSync: subprocess fork failed")
        return false
    end
    self._sync_pid        = pid
    self._sync_read_fd    = read_fd
    self._sync_anim_frame = 0
    _sync_any_pid         = pid
    self:_pollSyncSubprocess(done_fn)
    return true
end

function ClaudeSync:_pollSyncSubprocess(done_fn)
    if not self._sync_pid then return end  -- cancelled between ticks
    local ffiutil = require("ffi/util")
    self._sync_anim_frame = (self._sync_anim_frame + 1) % 4
    self:_updateCorner()

    if ffiutil.getNonBlockingReadSize(self._sync_read_fd) ~= 0 then
        local result = ffiutil.readAllFromFD(self._sync_read_fd)
        if _sync_any_pid == self._sync_pid then _sync_any_pid = nil end
        self._sync_pid        = nil
        self._sync_read_fd    = nil
        self._sync_anim_frame = 0
        done_fn(result)
        return
    end

    if ffiutil.isSubProcessDone(self._sync_pid) then
        ffiutil.readAllFromFD(self._sync_read_fd)
        if _sync_any_pid == self._sync_pid then _sync_any_pid = nil end
        self._sync_pid        = nil
        self._sync_read_fd    = nil
        self._sync_anim_frame = 0
        done_fn(nil)
        return
    end

    UIManager:scheduleIn(1, function()
        self:_pollSyncSubprocess(done_fn)
    end)
end

function ClaudeSync:_cancelSyncSubprocess()
    if not self._sync_pid then return end
    local ffiutil = require("ffi/util")
    ffiutil.terminateSubProcess(self._sync_pid)
    if self._sync_read_fd then
        ffiutil.readAllFromFD(self._sync_read_fd)
    end
    if _sync_any_pid == self._sync_pid then _sync_any_pid = nil end
    self._sync_pid        = nil
    self._sync_read_fd    = nil
    self._sync_anim_frame = 0
end

function ClaudeSync:_syncCurrentBook(closing)
    if not NetworkMgr:isConnected() then return end
    if not self.ui or not self.ui.document then return end
    local doc_path = self.ui.document.file
    if not doc_path then return end
    if self._sync_pid then return end
    if self.ui.doc_settings then
        self.ui.doc_settings:flush()
    end
    self:_setStatus("syncing")
    local root        = self.settings.root_folder
    local sdir        = DataStorage:getSettingsDir()
    local backend_cfg = {
        address  = self.settings.address,
        username = self.settings.username,
        password = self.settings.password,
    }
    local pos_mode = self.settings.position_sync_mode or "furthest"
    if not self:_runSyncSubprocess(
        function(pid, write_fd)
            local ffiutil = require("ffi/util")
            local WebDAV  = require("webdav")
            local Sync    = require("sync")
            local pid_str = (pid and pid > 0) and tostring(pid) or tostring(os.time())
            Sync.TEMP_DL  = sdir .. "/claudesync_dl_" .. pid_str .. ".tmp"
            Sync.TEMP_UL  = sdir .. "/claudesync_ul_" .. pid_str .. ".tmp"
            local backend = WebDAV:new(backend_cfg.address, backend_cfg.username, backend_cfg.password)
            local pcall_ok, book_ok, err_str = pcall(Sync.syncBook, backend, root, doc_path, nil, "auto", pos_mode)
            local out
            if pcall_ok and book_ok then
                out = "ok"
            elseif pcall_ok then
                out = "error:" .. tostring(err_str or "unknown")
            else
                out = "crash"
            end
            ffiutil.writeToFD(write_fd, out, true)
        end,
        function(result)
            if closing then return end
            if result == "ok"
               and self.ui and self.ui.document
               and self.ui.document.file == doc_path
               and self.ui.doc_settings then
                local DocSettings = require("docsettings")
                local synced = DocSettings:open(doc_path)
                local ann = synced:readSetting("annotations")
                local bm  = synced:readSetting("bookmarks")
                if ann then self.ui.doc_settings:saveSetting("annotations", ann) end
                if bm  then self.ui.doc_settings:saveSetting("bookmarks",  bm)  end
            end
            if result == "ok" then
                self._menu_sync_state = "ok"
                self:_setStatus("complete", 4)
            else
                self._menu_sync_state = "error"
                local err_str = result and result:match("^error:(.+)") or nil
                self:_setStatus(err_str, err_str and 5 or nil)
            end
        end
    ) then
        self:_setStatus(nil)
    end
end

function ClaudeSync:_doSyncAll(include_open_book)
    if self._sync_pid then return end
    self:_setStatus("syncing")
    local root        = self.settings.root_folder
    local sdir        = DataStorage:getSettingsDir()
    local backend_cfg = {
        address  = self.settings.address,
        username = self.settings.username,
        password = self.settings.password,
    }
    local open_book_path = _open_book_path
    local exclude_path = include_open_book and nil or open_book_path
    local extra_entries = {}
    for _, f in ipairs(EXTRA_FILES) do
        if self.settings["auto_sync_" .. f.id] then
            table.insert(extra_entries, { remote = f.remote, local_path = f.local_path(), merge = f.merge })
        end
    end
    local pos_mode = self.settings.position_sync_mode or "furthest"
    if not self:_runSyncSubprocess(
        function(pid, write_fd)
            local ffiutil = require("ffi/util")
            local WebDAV  = require("webdav")
            local Sync    = require("sync")
            local pid_str = (pid and pid > 0) and tostring(pid) or tostring(os.time())
            Sync.TEMP_DL  = sdir .. "/claudesync_dl_" .. pid_str .. ".tmp"
            Sync.TEMP_UL  = sdir .. "/claudesync_ul_" .. pid_str .. ".tmp"
            local backend = WebDAV:new(backend_cfg.address, backend_cfg.username, backend_cfg.password)
            local pcall_ok, results = pcall(Sync.syncAll, backend, root, nil, exclude_path, pos_mode)
            if not pcall_ok then
                ffiutil.writeToFD(write_fd, "crash", true)
                return
            end
            local errors, last_error = results.errors, results.last_error
            for _, entry in ipairs(extra_entries) do
                local ok, err
                if entry.merge then
                    ok, err = Sync.syncSmartFile(backend, root, entry, sdir, pid_str)
                else
                    ok, err = Sync.syncExtraFile(backend, root, entry, "push")
                end
                if not ok then
                    errors     = errors + 1
                    last_error = err
                end
            end
            ffiutil.writeToFD(write_fd, errors == 0 and "ok" or (last_error or "error"), true)
        end,
        function(result)
            if result == "ok"
               and include_open_book
               and open_book_path
               and self.ui and self.ui.document
               and self.ui.document.file == open_book_path
               and self.ui.doc_settings then
                -- Re-read the sidecar the subprocess just wrote and push
                -- the merged annotations into the live in-memory array.
                -- Without this, onSaveSettings on close writes the stale
                -- pre-sync array back to disk, erasing what was just merged.
                local DocSettings = require("docsettings")
                local synced = DocSettings:open(open_book_path)
                local ann = synced:readSetting("annotations")
                local bm  = synced:readSetting("bookmarks")
                if ann then
                    if self.ui.annotation then
                        self.ui.annotation.annotations = ann
                    end
                    self.ui.doc_settings:saveSetting("annotations", ann)
                end
                if bm then self.ui.doc_settings:saveSetting("bookmarks", bm) end
            end
            if result == "ok" then
                self._menu_sync_state = "ok"
                self:_setStatus("complete", 4)
                UIManager:scheduleIn(4, function()
                    if self._menu_sync_state == "ok" then self._menu_sync_state = nil end
                end)
            else
                self._menu_sync_state = "error"
                local err_str = (result and result ~= "crash") and result or nil
                self:_setStatus(err_str, err_str and 5 or nil)
            end
        end
    ) then
        self:_setStatus(nil)
    end
end

-- Manual Push / Pull: syncs books (if checked) and any checked extra files.
function ClaudeSync:_doSyncWithItems(mode, touchmenu_instance)
    if self._sync_pid then return end
    self:_setStatus("syncing")
    local root            = self.settings.root_folder
    local sdir            = DataStorage:getSettingsDir()
    local backend_cfg     = {
        address  = self.settings.address,
        username = self.settings.username,
        password = self.settings.password,
    }
    local push_pull_books = self.settings.push_pull_books
    -- Push includes the currently-open book (flush first so in-memory position is captured).
    -- Pull excludes it — mid-read position changes are surprising; next open pulls it anyway.
    -- SaveSettings must fire before flush: CloseDocument fires before saveSettings() in
    -- ReaderUI:onClose (self.dialog == self branch), so doc_settings may not yet hold the
    -- current reader position.  Same issue applies here when the user navigates mid-read.
    if mode == "push" and self.ui.doc_settings then
        self.ui:handleEvent(Event:new("SaveSettings"))
        self.ui.doc_settings:flush()
    end
    local exclude_path  = (mode == "pull") and _open_book_path or nil
    local extra_entries = {}
    for _, f in ipairs(EXTRA_FILES) do
        if self.settings["push_pull_" .. f.id] then
            table.insert(extra_entries, { remote = f.remote, local_path = f.local_path() })
        end
    end
    local pos_mode = self.settings.position_sync_mode or "furthest"
    if not self:_runSyncSubprocess(
        function(pid, write_fd)
            local ffiutil = require("ffi/util")
            local WebDAV  = require("webdav")
            local Sync    = require("sync")
            local pid_str = (pid and pid > 0) and tostring(pid) or tostring(os.time())
            Sync.TEMP_DL  = sdir .. "/claudesync_dl_" .. pid_str .. ".tmp"
            Sync.TEMP_UL  = sdir .. "/claudesync_ul_" .. pid_str .. ".tmp"
            local backend = WebDAV:new(backend_cfg.address, backend_cfg.username, backend_cfg.password)
            local errors, last_error = 0, nil
            if push_pull_books then
                local pcall_ok, results = pcall(Sync.syncAll, backend, root, mode, exclude_path, pos_mode)
                if not pcall_ok then
                    ffiutil.writeToFD(write_fd, "crash", true)
                    return
                end
                errors     = results.errors
                last_error = results.last_error
            end
            for _, entry in ipairs(extra_entries) do
                local ok, err = Sync.syncExtraFile(backend, root, entry, mode)
                if not ok then
                    errors     = errors + 1
                    last_error = err or last_error
                end
            end
            ffiutil.writeToFD(write_fd, errors == 0 and "ok" or (last_error or "error"), true)
        end,
        function(result)
            local state_key = (mode == "push") and "_push_state" or "_pull_state"
            if result == "ok" then
                self[state_key] = "ok"
                self:_setStatus("complete", 4)
                UIManager:scheduleIn(4, function()
                    if self[state_key] == "ok" then self[state_key] = nil end
                end)
            else
                self[state_key] = "error"
                local err_str = (result and result ~= "crash") and result or nil
                self:_setStatus(err_str, err_str and 5 or nil)
            end
            if touchmenu_instance then
                pcall(touchmenu_instance.updateItems, touchmenu_instance)
            end
        end
    ) then
        self:_setStatus(nil)
    end
end

-- ── Public sync entry point ───────────────────────────────────────────────────

function ClaudeSync:syncIfOnline()
    if self._sync_pid then return end
    if not self:_isConfigured() then
        self._menu_sync_state = "error"
        UIManager:show(InfoMessage:new{
            text    = _("ClaudeSync is not configured.\nPlease enter your server settings."),
            timeout = 4,
        })
        return
    end
    if not NetworkMgr:isConnected() then
        self._menu_sync_state = "error"
        self.pending_sync = true
        self:_setStatus("no_wifi", 4)
        return
    end
    local include_open_book = false
    if self.ui.doc_settings then
        self.ui:handleEvent(Event:new("SaveSettings"))
        self.ui.doc_settings:flush()
        include_open_book = true
    end
    self:_doSyncAll(include_open_book)
end

-- ── Settings ─────────────────────────────────────────────────────────────────

function ClaudeSync:_saveSettings()
    G_reader_settings:saveSetting("claudesync", self.settings)
end

function ClaudeSync:_showSettings(touchmenu_instance)
    local dialog
    dialog = MultiInputDialog:new{
        title  = _("ClaudeSync server settings"),
        fields = {
            {
                description = _("WebDAV server address"),
                text        = self.settings.address,
                hint        = _("https://your.server/remote.php/dav/files/Username"),
            },
            {
                description = _("Username"),
                text        = self.settings.username,
                hint        = _("username"),
            },
            {
                description = _("Password"),
                text        = self.settings.password,
                hint        = _("password"),
                text_type   = "password",
            },
            {
                description = _("Remote folder (relative to server root)"),
                text        = self.settings.root_folder,
                hint        = _("koreader-sync"),
            },
        },
        buttons = {
            {
                {
                    text     = _("Cancel"),
                    id       = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text     = _("Save"),
                    callback = function()
                        local fields = dialog:getFields()
                        self.settings.address     = fields[1]:gsub("%s+", "")
                        self.settings.username    = fields[2]
                        self.settings.password    = fields[3]
                        self.settings.root_folder = fields[4] ~= "" and fields[4]
                                                    or DEFAULTS.root_folder
                        self.settings.enabled     = self.settings.address ~= ""
                                                    and self.settings.username ~= ""
                        self:_saveSettings()
                        UIManager:close(dialog)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                        if self.settings.enabled then
                            UIManager:show(Notification:new{
                                text    = _("ClaudeSync: settings saved."),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ── Menu ─────────────────────────────────────────────────────────────────────

function ClaudeSync:addToMainMenu(menu_items)
    local function loc() return self.settings.status_location or "none"      end
    local function fmt() return self.settings.status_format   or "icon_text" end

    local WARN_PATHS = "Book collections and reading history store absolute file paths. " ..
        "These may not match on other devices if your books are stored in different locations."
    local WARN_KOREADER = "KOReader settings contains device-specific values such as screen DPI " ..
        "and frontlight levels.\n\nSyncing these to a different device may cause unexpected behavior. " ..
        "Only use this when migrating to a new device."

    -- Helper: build a checkbox menu item that toggles settings[prefix.."_"..key].
    -- sep:  if true, draw a separator line after this item.
    -- warn: if set, show a confirmation popup when checking the item ON.
    local function item(label, key, prefix, sep, warn)
        return {
            text         = _(label),
            checked_func = function() return self.settings[prefix .. "_" .. key] end,
            separator    = sep,
            callback     = function()
                local current = self.settings[prefix .. "_" .. key]
                if not current and warn then
                    UIManager:show(ConfirmBox:new{
                        text        = _(warn),
                        ok_text     = _("Enable"),
                        ok_callback = function()
                            self.settings[prefix .. "_" .. key] = true
                            self:_saveSettings()
                        end,
                    })
                else
                    self.settings[prefix .. "_" .. key] = not current
                    self:_saveSettings()
                end
            end,
        }
    end

    -- enabled_func for Push / Pull buttons: at least one item must be checked.
    local function any_push_pull()
        local p = self.settings
        return p.push_pull_books or p.push_pull_statistics or p.push_pull_vocabulary
            or p.push_pull_profiles or p.push_pull_collections
            or p.push_pull_history  or p.push_pull_koreader
    end

    menu_items.claudesync = {
        text         = _("ClaudeSync"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text_func = function()
                    local state = self._menu_sync_state
                    local icon
                    if     state == "syncing" then icon = "⟳"
                    elseif state == "ok"      then icon = "✓"
                    elseif state == "error"   then icon = "⚠"
                    end
                    return icon and (_("Sync now") .. "  " .. icon) or _("Sync now")
                end,
                keep_menu_open = true,
                enabled_func   = function() return not self._sync_pid end,
                callback = function(touchmenu_instance)
                    self._menu_sync_state = "syncing"
                    touchmenu_instance:updateItems()
                    self:syncIfOnline()
                end,
            },
            {
                text_func    = function()
                    return self.settings.auto_sync_enabled
                        and _("Auto-sync: on") or _("Auto-sync: off")
                end,
                enabled_func = function() return self:_isConfigured() end,
                checked_func = function() return self.settings.auto_sync_enabled end,
                callback     = function()
                    self.settings.auto_sync_enabled = not self.settings.auto_sync_enabled
                    self:_saveSettings()
                end,
            },
            {
                text = _("Auto-sync options"),
                sub_item_table = {
                    {
                        text         = _("What to auto-sync."),
                        enabled_func = function() return false end,
                        separator    = true,
                    },
                    {
                        text         = _("Book progress & annotations"),
                        checked_func = function() return true end,
                        enabled_func = function() return false end,
                    },
                    item("Reading statistics",  "statistics",  "auto_sync"),
                    item("Vocabulary builder",  "vocabulary",  "auto_sync"),
                    item("Reading profiles",    "profiles",    "auto_sync", true),
                    item("Book collections  ⚠", "collections", "auto_sync", false, WARN_PATHS),
                    item("Reading history  ⚠",  "history",     "auto_sync", true,  WARN_PATHS),
                    {
                        text = _("When to auto-sync"),
                        sub_item_table = {
                            {
                                text         = _("When to auto-sync."),
                                enabled_func = function() return false end,
                                separator    = true,
                            },
                            {
                                text         = _("When opening a book"),
                                checked_func = function() return self.settings.auto_sync_on_open end,
                                callback     = function()
                                    self.settings.auto_sync_on_open = not self.settings.auto_sync_on_open
                                    self:_saveSettings()
                                end,
                            },
                            {
                                text         = _("When closing a book"),
                                checked_func = function() return self.settings.auto_sync_on_close end,
                                callback     = function()
                                    self.settings.auto_sync_on_close = not self.settings.auto_sync_on_close
                                    self:_saveSettings()
                                end,
                            },
                            {
                                text         = _("On KOReader launch"),
                                checked_func = function() return self.settings.auto_sync_on_launch end,
                                callback     = function()
                                    self.settings.auto_sync_on_launch = not self.settings.auto_sync_on_launch
                                    self:_saveSettings()
                                end,
                            },
                            {
                                text         = _("When WiFi connects"),
                                checked_func = function() return self.settings.auto_sync_on_wifi end,
                                callback     = function()
                                    self.settings.auto_sync_on_wifi = not self.settings.auto_sync_on_wifi
                                    self:_saveSettings()
                                end,
                            },
                            {
                                text         = _("On device wake"),
                                checked_func = function() return self.settings.auto_sync_on_resume end,
                                callback     = function()
                                    self.settings.auto_sync_on_resume = not self.settings.auto_sync_on_resume
                                    self:_saveSettings()
                                end,
                            },
                        },
                    },
                    {
                        text      = _("Reading position sync mode"),
                        separator = true,
                        sub_item_table = {
                            {
                                text         = _("How your reading position is synced across devices."),
                                enabled_func = function() return false end,
                                separator    = true,
                            },
                            {
                                text         = _("Furthest page read wins"),
                                checked_func = function()
                                    return (self.settings.position_sync_mode or "furthest") == "furthest"
                                end,
                                callback     = function()
                                    self.settings.position_sync_mode = "furthest"
                                    self:_saveSettings()
                                end,
                            },
                            {
                                text         = _("Keep my current position"),
                                checked_func = function()
                                    return self.settings.position_sync_mode == "local"
                                end,
                                callback     = function()
                                    self.settings.position_sync_mode = "local"
                                    self:_saveSettings()
                                end,
                            },
                        },
                    },
                },
            },
            {
                text = _("Push / Pull"),
                sub_item_table = {
                    {
                        text         = _("Manually overwrite data."),
                        enabled_func = function() return false end,
                        separator    = true,
                    },
                    item("Book progress & annotations", "books",       "push_pull"),
                    item("Reading statistics",         "statistics",  "push_pull"),
                    item("Vocabulary builder",         "vocabulary",  "push_pull"),
                    item("Reading profiles",           "profiles",    "push_pull", true),
                    item("Book collections  ⚠",       "collections", "push_pull", false, WARN_PATHS),
                    item("Reading history  ⚠",        "history",     "push_pull"),
                    item("KOReader settings  ⚠",      "koreader",    "push_pull", true,  WARN_KOREADER),
                    {
                        text_func = function()
                            local state = self._push_state
                            local icon = state == "syncing" and "⟳"
                                      or state == "ok"      and "✓"
                                      or state == "error"   and "⚠"
                                      or nil
                            return icon and (_("Push to server") .. "  " .. icon) or _("Push to server")
                        end,
                        keep_menu_open = true,
                        enabled_func   = function() return any_push_pull() and not self._sync_pid end,
                        callback       = function(touchmenu_instance)
                            UIManager:show(ConfirmBox:new{
                                text    = _("Push selected data to the server, overwriting remote?\n\nThis cannot be undone."),
                                ok_text = _("Push"),
                                ok_callback = function()
                                    self._push_state = "syncing"
                                    self._pull_state = nil
                                    touchmenu_instance:updateItems()
                                    self:_doSyncWithItems("push", touchmenu_instance)
                                end,
                            })
                        end,
                    },
                    {
                        text_func = function()
                            local state = self._pull_state
                            local icon = state == "syncing" and "⟳"
                                      or state == "ok"      and "✓"
                                      or state == "error"   and "⚠"
                                      or nil
                            return icon and (_("Pull from server") .. "  " .. icon) or _("Pull from server")
                        end,
                        keep_menu_open = true,
                        enabled_func   = function() return any_push_pull() and not self._sync_pid end,
                        callback       = function(touchmenu_instance)
                            UIManager:show(ConfirmBox:new{
                                text    = _("Pull selected data from the server, overwriting local?\n\nThis cannot be undone."),
                                ok_text = _("Pull"),
                                ok_callback = function()
                                    self._pull_state = "syncing"
                                    self._push_state = nil
                                    touchmenu_instance:updateItems()
                                    self:_doSyncWithItems("pull", touchmenu_instance)
                                end,
                            })
                        end,
                    },
                },
            },
            {
                text = _("Status indicator"),
                sub_item_table = {
                    {
                        text         = _("Status indicator options"),
                        enabled_func = function() return false end,
                        separator    = true,
                    },
                    {
                        text         = _("Corner icon  (top-left overlay)"),
                        checked_func = function() return loc() == "corner" end,
                        callback     = function()
                            self.settings.status_location = "corner"
                            self:_saveSettings()
                        end,
                    },
                    {
                        text         = _("Status bar  (displays as the external content item)"),
                        checked_func = function() return loc() == "footer" end,
                        callback     = function()
                            self.settings.status_location = "footer"
                            self:_saveSettings()
                        end,
                    },
                    {
                        text         = _("None"),
                        checked_func = function() return loc() == "none" end,
                        separator    = true,
                        callback     = function()
                            self.settings.status_location = "none"
                            self:_saveSettings()
                        end,
                    },
                    {
                        text         = _("Icon and text"),
                        checked_func = function() return fmt() == "icon_text" end,
                        enabled_func = function() return loc() ~= "none" end,
                        callback     = function()
                            self.settings.status_format = "icon_text"
                            self:_saveSettings()
                        end,
                    },
                    {
                        text         = _("Icon only"),
                        checked_func = function() return fmt() == "icon" end,
                        enabled_func = function() return loc() ~= "none" end,
                        callback     = function()
                            self.settings.status_format = "icon"
                            self:_saveSettings()
                        end,
                    },
                    {
                        text         = _("Text only"),
                        checked_func = function() return fmt() == "text" end,
                        enabled_func = function() return loc() ~= "none" end,
                        callback     = function()
                            self.settings.status_format = "text"
                            self:_saveSettings()
                        end,
                    },
                },
            },
            {
                text           = _("Server settings…"),
                keep_menu_open = true,
                callback       = function(touchmenu_instance)
                    self:_showSettings(touchmenu_instance)
                end,
            },
        },
    }
end

return ClaudeSync
