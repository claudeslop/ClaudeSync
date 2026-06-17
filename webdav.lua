local WebDavApi = require("apps/cloudstorage/webdavapi")
local logger    = require("logger")

local WebDAV = {}
WebDAV.__index = WebDAV

function WebDAV:new(address, username, password)
    return setmetatable({
        address  = address:gsub("/$", ""),
        username = username,
        password = password,
        _ensured = {},
    }, self)
end

-- Walk path components and MKCOL each one.
-- 201 = created, 405 = already exists — both are success.
-- Results cached so repeated calls within one sync session are free.
function WebDAV:ensureDir(remote_path)
    local current = ""
    for part in remote_path:gmatch("[^/]+") do
        current = current == "" and part or (current .. "/" .. part)
        if not self._ensured[current] then
            local url  = WebDavApi:getJoinedPath(self.address, current)
            local code = WebDavApi:createFolder(url, self.username, self.password)
            if code ~= 201 and code ~= 405 then
                logger.warn("ClaudeSync: ensureDir failed:", code, url)
                return false
            end
            self._ensured[current] = true
        end
    end
    return true
end

-- Download remote_path to local_path.
-- Returns: ok (bool), code (number), etag (string|nil)
-- WebDavApi:downloadFile uses FILE_BLOCK_TIMEOUT/FILE_TOTAL_TIMEOUT internally.
function WebDAV:download(remote_path, local_path)
    local url = WebDavApi:getJoinedPath(self.address, remote_path)
    local code, etag = WebDavApi:downloadFile(url, self.username, self.password, local_path)
    if code == 200 then
        return true, 200, etag
    end
    os.remove(local_path)
    if code ~= 404 then
        logger.warn("ClaudeSync: download failed:", code, url)
    end
    return false, code or 0, nil
end

-- Upload local_path to remote_path.
-- etag (optional): sends If-Match; server returns 412 if file changed since our download.
-- Returns: ok (bool), code (number)
-- WebDavApi:uploadFile uses FILE_BLOCK_TIMEOUT/FILE_TOTAL_TIMEOUT internally.
function WebDAV:upload(remote_path, local_path, etag)
    local url  = WebDavApi:getJoinedPath(self.address, remote_path)
    local code = WebDavApi:uploadFile(url, self.username, self.password, local_path, etag)
    local ok   = type(code) == "number" and code >= 200 and code < 300
    if not ok then
        logger.warn("ClaudeSync: upload failed:", code, url)
    end
    return ok, code or 0
end

return WebDAV
