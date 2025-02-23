local record M
    record FeatureInfo
        enabled: boolean
        transitive: boolean
    end
end

local FeatureInfo = M.FeatureInfo
local semver = require("crates.semver")
local state = require("crates.state")
local toml = require("crates.toml")
local types = require("crates.types")
local Diagnostic = types.Diagnostic
local CrateInfo = types.CrateInfo
local Feature = types.Feature
local Features = types.Features
local Range = types.Range
local Requirement = types.Requirement
local SemVer = types.SemVer
local Version = types.Version

local IS_WIN = vim.api.nvim_call_function("has", { "win32" }) == 1

function M.current_buf(): integer
    return vim.api.nvim_get_current_buf() as integer
end

function M.cursor_pos(): integer, integer
    local cursor = vim.api.nvim_win_get_cursor(0)
    return cursor[1] - 1, cursor[2]
end

function M.get_buf_crates(buf: integer): {string:toml.Crate}
    local cache = state.buf_cache[buf]
    return cache and cache.crates
end

function M.get_buf_info(buf: integer): {string:CrateInfo}
    local cache = state.buf_cache[buf]
    return cache and cache.info
end

function M.get_buf_diagnostics(buf: integer): {Diagnostic}
    local cache = state.buf_cache[buf]
    return cache and cache.diagnostics
end

function M.get_crate_info(buf: integer, key: string): CrateInfo
    local info = M.get_buf_info(buf)
    return info[key]
end

function M.get_line_crates(buf: integer, lines: Range): {string:toml.Crate}
    local cache = state.buf_cache[buf]
    local crates = cache and cache.crates
    if not crates then
        return {}
    end

    local line_crates = {}
    for k,c in pairs(crates) do
        if lines:contains(c.lines.s) or c.lines:contains(lines.s) then
            line_crates[k] = c
        end
    end

    return line_crates
end

function M.get_newest(versions: {Version}, avoid_pre: boolean, reqs: {Requirement}|nil): Version, Version, Version
    if not versions then
        return nil
    end

    local newest_yanked: Version = nil
    local newest_pre: Version = nil
    local newest: Version = nil

    for _,v in ipairs(versions) do
        if not reqs or semver.matches_requirements(v.parsed, reqs) then
            if not v.yanked then
                if not avoid_pre or avoid_pre and not v.parsed.pre then
                    newest = v
                    break
                else
                    newest_pre = newest_pre or v
                end
            else
                newest_yanked = newest_yanked or v
            end
        end
    end

    return newest, newest_pre, newest_yanked
end

function M.is_feat_enabled(crate: toml.Crate, feature: Feature): boolean
    local enabled = crate:get_feat(feature.name) ~= nil
    if feature.name == "default" then
        return enabled or crate:is_def_enabled()
    else
        return enabled
    end
end

function M.features_info(crate: toml.Crate, features: Features): {string:FeatureInfo}
    local info: {string:FeatureInfo} = {}

    local function update_transitive(f: Feature)
        for _,m in ipairs(f.members) do
            local tf = features:get_feat(m)
            if tf then
                local i = info[m]
                if i then
                    if not i.transitive then
                        i.transitive = true
                    end
                else
                    info[m] = {
                        enabled = false,
                        transitive = true,
                    }
                    update_transitive(tf)
                end
            end
        end
    end

    for _,f in ipairs(features) do
        local enabled = M.is_feat_enabled(crate, f)
        local i = info[f.name]
        if i then
            i.enabled = enabled
        else
            info[f.name] = {
                enabled = enabled,
                transitive = false,
            }
        end

        if enabled then
            update_transitive(f)
        end
    end

    return info
end

local function insert_version(buf: integer, crate: toml.Crate, text: string): Range
    if not crate.vers then
        if crate.syntax == "table" then
            local line = crate.lines.s + 1
            vim.api.nvim_buf_set_lines(
                buf, line, line, false,
                { 'version = "' .. text .. '"' }
            )
            return crate.lines:moved(0, 1)
        elseif crate.syntax == "inline_table" then
            local line = crate.lines.s
            local def_col_start = 0
            if crate.def then
                def_col_start = crate.def.decl_col.s
            end
            local feat_col_start = 0
            if crate.feat then
                feat_col_start = crate.feat.decl_col.s
            end
            local col = math.max(def_col_start, feat_col_start)
            vim.api.nvim_buf_set_text(
                buf, line, col, line, col,
                { ' version = "' .. text .. '",' }
            )
            return Range.pos(line)
        elseif crate.syntax == "plain" then
            return Range.empty() -- unreachable
        end
    else
        local t = text
        if state.cfg.insert_closing_quote and not crate.vers.quote.e then
            t = text .. crate.vers.quote.s
        end
        local line = crate.vers.line

        if t ~= crate.vers.text then
            vim.api.nvim_buf_set_text(
                buf,
                line,
                crate.vers.col.s,
                line,
                crate.vers.col.e,
                { t }
            )
        end
        return Range.pos(line)
    end
end

local function replace_existing(r: Requirement, version: SemVer): SemVer
    if version.pre then
        return version
    else
        return SemVer.new {
            major = version.major,
            minor = r.vers.minor and version.minor or nil,
            patch = r.vers.patch and version.patch or nil,
        }
    end
end

function M.smart_version_text(crate: toml.Crate, version: SemVer): string
    if #crate:vers_reqs() == 0 then
        return version:display()
    end

    local pos = 1
    local text = ""
    for _,r in ipairs(crate:vers_reqs()) do
        if r.cond == "eq" then
            local v = replace_existing(r, version)
            text = text .. string.sub(crate.vers.text, pos, r.vers_col.s) .. v:display()
        elseif r.cond == "wl" then
            if version.pre then
                text = text .. string.sub(crate.vers.text, pos, r.vers_col.s) .. version:display()
            else
                local v = SemVer.new {
                    major = r.vers.major and version.major or nil,
                    minor = r.vers.minor and version.minor or nil,
                }
                local before = string.sub(crate.vers.text, pos, r.vers_col.s)
                local after = string.sub(crate.vers.text, r.vers_col.e + 1, r.cond_col.e)
                text = text .. before .. v:display() .. after
            end
        elseif r.cond == "tl" then
            local v = replace_existing(r, version)
            text = text .. string.sub(crate.vers.text, pos, r.vers_col.s) .. v:display()
        elseif r.cond == "cr" then
            local v = replace_existing(r, version)
            text = text .. string.sub(crate.vers.text, pos, r.vers_col.s) .. v:display()
        elseif r.cond == "bl" then
            local v = replace_existing(r, version)
            text = text .. string.sub(crate.vers.text, pos, r.vers_col.s) .. v:display()
        elseif r.cond == "lt" and not semver.matches_requirement(version, r) then
            local v = SemVer.new {
                major = version.major,
                minor = r.vers.minor and version.minor or nil,
                patch = r.vers.patch and version.patch or nil,
            }

            if v.patch then
                v.patch = v.patch + 1
            elseif v.minor then
                v.minor = v.minor + 1
            elseif v.major then
                v.major = v.major + 1
            end

            text = text .. string.sub(crate.vers.text, pos, r.vers_col.s) .. v:display()
        elseif r.cond == "le" and not semver.matches_requirement(version, r) then
            local v: SemVer

            if version.pre then
                v = version
            else
                v =  SemVer.new { major = version.major }
                if r.vers.minor or version.minor and version.minor > 0 then
                    v.minor = version.minor
                end
                if r.vers.patch or version.patch and version.patch > 0 then
                    v.minor = version.minor
                    v.patch = version.patch
                end
            end

            text = text .. string.sub(crate.vers.text, pos, r.vers_col.s) .. v:display()
        elseif r.cond == "gt" and not semver.matches_requirement(version, r) then
            local v = SemVer.new {
                major = r.vers.major and version.major or nil,
                minor = r.vers.minor and version.minor or nil,
                patch = r.vers.patch and version.patch or nil,
            }

            if v.patch then
                v.patch = v.patch - 1
                if v.patch < 0 then
                    v.patch = 0
                    v.minor = v.minor - 1
                end
            elseif v.minor then
                v.minor = v.minor - 1
                if v.minor < 0 then
                    v.minor = 0
                    v.major = v.major - 1
                end
            elseif v.major then
                v.major = v.major - 1
                if v.major < 0 then
                    v.major = 0
                end
            end

            text = text .. string.sub(crate.vers.text, pos, r.vers_col.s) .. v:display()
        elseif r.cond == "ge" then
            local v = replace_existing(r, version)
            text = text .. string.sub(crate.vers.text, pos, r.vers_col.s) .. v:display()
        else
            text = text .. string.sub(crate.vers.text, pos, r.vers_col.e)
        end

        pos = math.max(r.cond_col.e + 1, r.vers_col.e + 1)
    end
    text = text .. string.sub(crate.vers.text, pos)

    return text
end

function M.version_text(crate: toml.Crate, version: SemVer, alt: boolean|nil): string
    local smart: boolean
    if alt then
        smart = not state.cfg.smart_insert
    else
        smart = state.cfg.smart_insert
    end
    if smart then
        return M.smart_version_text(crate, version)
    else
        return version:display()
    end
end

function M.set_version(buf: integer, crate: toml.Crate, version: SemVer, alt: boolean|nil): Range
    local text = M.version_text(crate, version, alt)
    return insert_version(buf, crate, text)
end

function M.upgrade_crates(buf: integer, crates: {string:toml.Crate}, info: {string:CrateInfo}, alt: boolean|nil)
    for k,c in pairs(crates) do
        local i = info[k]

        if i then
            local version = i.vers_upgrade or i.vers_update
            if version then
                M.set_version(buf, c, version.parsed, alt)
            end
        end
    end
end

function M.update_crates(buf: integer, crates: {string:toml.Crate}, info: {string:CrateInfo}, alt: boolean|nil)
    for k,c in pairs(crates) do
        local i = info[k]

        if i then
            local version = i.vers_update
            if version then
                M.set_version(buf, c, version.parsed, alt)
            end
        end
    end
end

function M.enable_feature(buf: integer, crate: toml.Crate, feature: Feature): Range
    local t = '"' .. feature.name .. '"'
    if not crate.feat then
        if crate.syntax == "table" then
            local line = math.max(
                crate.vers and crate.vers.line or 0,
                crate.def and crate.def.line or 0
            ) + 1
            vim.api.nvim_buf_set_lines(
                buf, line, line, false,
                { "features = [" .. t .."]" }
            )
            return Range.pos(line)
        elseif crate.syntax == "plain" then
            t = ", features = [" .. t .. "] }"
            local line = crate.vers.line
            local col = crate.vers.col.e
            if crate.vers.quote.e then
                col = col + 1
            else
                t = crate.vers.quote.s .. t
            end
            vim.api.nvim_buf_set_text(buf, line, col, line, col, { t })

            vim.api.nvim_buf_set_text(
                buf,
                line,
                crate.vers.col.s - 1,
                line,
                crate.vers.col.s - 1,
                { "{ version = " }
            )
            return Range.pos(line)
        elseif crate.syntax == "inline_table" then
            local line = crate.lines.s
            local vers_col_end = 0
            if crate.vers then
                vers_col_end = crate.vers.col.e
                if crate.vers.quote.e then
                    vers_col_end = vers_col_end + 1
                end
            end
            local def_col_end = 0
            if crate.def then
                def_col_end = crate.def.col.e
            end
            local col = math.max(vers_col_end, def_col_end)
            vim.api.nvim_buf_set_text(
                buf, line, col, line, col,
                { ", features = [" .. t .. "]" }
            )
            return Range.pos(line)
        end
    else
        local last_feat = crate.feat.items[#crate.feat.items]
        if last_feat then
            if not last_feat.comma then
                t = ", " .. t
            end
            if not last_feat.quote.e then
                t = last_feat.quote.s .. t
            end
        end

        vim.api.nvim_buf_set_text(
            buf,
            crate.feat.line,
            crate.feat.col.e,
            crate.feat.line,
            crate.feat.col.e,
            { t }
        )
        return Range.pos(crate.feat.line)
    end
end

function M.disable_feature(buf: integer, crate: toml.Crate, feature: toml.Feature): Range
    -- check reference in case of duplicates
    local index: integer
    for i,f in ipairs(crate.feat.items) do
        if f == feature then
            index = i
            break
        end
    end
    if not index then return end

    local col_start = feature.decl_col.s
    local col_end = feature.decl_col.e
    if index == 1 then
        if #crate.feat.items > 1 then
            col_end = crate.feat.items[2].col.s - 1
        elseif feature.comma then
            col_end = col_end + 1
        end
    else
        local prev_feature = crate.feat.items[index - 1]
        col_start = prev_feature.col.e + 1
    end

    vim.api.nvim_buf_set_text(
        buf,
        crate.feat.line,
        crate.feat.col.s + col_start,
        crate.feat.line,
        crate.feat.col.s + col_end,
        { "" }
    )
    return Range.pos(crate.feat.line)
end

function M.enable_def_features(buf: integer, crate: toml.Crate): Range
    vim.api.nvim_buf_set_text(
        buf,
        crate.def.line,
        crate.def.col.s,
        crate.def.line,
        crate.def.col.e,
        { "true" }
    )
    return Range.pos(crate.def.line)
end

local function disable_def_features(buf: integer, crate: toml.Crate): Range
    if crate.def then
        local line = crate.def.line
        vim.api.nvim_buf_set_text(
            buf,
            line,
            crate.def.col.s,
            line,
            crate.def.col.e,
            { "false" }
        )
            return crate.lines
    else
        if crate.syntax == "table" then
            local line = math.max((crate.vers.line or 0) + 1, crate.feat.line or 0)
            vim.api.nvim_buf_set_lines(
                buf,
                line,
                line,
                false,
                { "default_features = false" }
            )
            return crate.lines:moved(0, 1)
        elseif crate.syntax == "plain" then
            local t = ", default_features = false }"
            local col = crate.vers.col.e
            if crate.vers.quote.e then
                col = col + 1
            else
                t = crate.vers.quote.s .. t
            end
            local line = crate.vers.line
            vim.api.nvim_buf_set_text(
                buf,
                line,
                col,
                line,
                col,
                { t }
            )

            vim.api.nvim_buf_set_text(
                buf,
                line,
                crate.vers.col.s - 1,
                line,
                crate.vers.col.s - 1,
                { "{ version = " }
            )
            return crate.lines
        elseif crate.syntax == "inline_table" then
            local line = crate.lines.s
            if crate.vers then
                local col = crate.vers.col.e
                if crate.vers.quote.e then
                    col = col + 1
                end
                vim.api.nvim_buf_set_text(
                    buf, line, col, line, col,
                    { ", default_features = false" }
                )
            elseif crate.feat then
                local col = crate.feat.decl_col.s
                vim.api.nvim_buf_set_text(
                    buf, line, col, line, col,
                    { " default_features = false," }
                )
            end
            return crate.lines
        end
    end
end

function M.disable_def_features(buf: integer, crate: toml.Crate, feature: toml.Feature|nil): Range
    if feature then
        if crate.def and crate.def.col.s < crate.feat.col.s then
            M.disable_feature(buf, crate, feature)
            return disable_def_features(buf, crate)
        else
            local lines = disable_def_features(buf, crate)
            M.disable_feature(buf, crate, feature)
            return lines
        end
    else
        return disable_def_features(buf, crate)
    end
end

function M.lualib_installed(name: string): boolean
    local ok, _ = pcall(require as function(string): (any), name)
    return ok
end

function M.binary_installed(name: string): boolean
    if IS_WIN then
        name = name .. ".exe"
    end

    return vim.fn.executable(name) == 1
end

function M.notify(severity: integer, s: string, ...:any)
    vim.notify(s:format(...), severity, { title = state.cfg.notification_title })
end

function M.docs_rs_url(name: string): string
    return "https://docs.rs/"..name
end

function M.crates_io_url(name: string): string
    return "https://crates.io/crates/"..name
end

function M.open_url(url: string)
    if M.binary_installed("xdg-open") then
        vim.cmd("silent !xdg-open " .. url)
    elseif M.binary_installed("open") then
        vim.cmd("silent !open " .. url)
    else
        M.notify(vim.log.levels.WARN, "Couldn't open url")
    end
end

return M
