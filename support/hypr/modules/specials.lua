----------------------------
---- SPECIAL WORKSPACES ----
----------------------------

-- Scratchpads that slide over whatever workspace you are on and hide again
-- with the same key. Lucid Settings > Workspaces picks the apps each one holds
-- and writes them to ~/.config/hypr/lucid-specials.lua, which is read on every
-- key press, so a change there needs no reload. The keys are in modules/binds.lua

local M = {}

M.data = os.getenv("HOME") .. "/.config/hypr/lucid-specials.lua"

-- the file is data only, so it runs with an empty environment. without it
-- every workspace is on and holds no apps
local function config()
    local chunk = loadfile(M.data, "t", {})
    local ok, cfg = false, nil
    if chunk then ok, cfg = pcall(chunk) end
    if not ok or type(cfg) ~= "table" or type(cfg.workspaces) ~= "table" then
        return { workspaces = {} }
    end
    return cfg
end

local function space(cfg, name)
    local ws = cfg.workspaces[name]
    return type(ws) == "table" and ws or {}
end

local function lower(s)
    return string.lower(tostring(s or ""))
end

-- class compares case-blind, since xwayland and wayland builds of one app
-- disagree (Spotify, spotify); the initial title catches apps with no class
local function owns(app, w)
    local cls = lower(w.class)
    for _, c in ipairs(app.class or {}) do
        if cls ~= "" and cls == lower(c) then return true end
    end
    local title = tostring(w.initial_title or "")
    for _, t in ipairs(app.title or {}) do
        if title ~= "" and title == t then return true end
    end
    return false
end

-- window rules take regex, so names are escaped and matched whole
local function pattern(list)
    local out = {}
    for _, s in ipairs(list) do
        out[#out + 1] = (tostring(s):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?%{%}|\\]", "\\%0"))
    end
    return "(?i)^(" .. table.concat(out, "|") .. ")$"
end

-- discord clients only go to a workspace when its key launched them
local roaming = {
    discord = true, vesktop = true, equibop = true, legcord = true,
    webcord = true, armcord = true, goofcord = true, ["com.discordapp.discord"] = true,
}

local function roams(app)
    for _, c in ipairs(app.class or {}) do
        if roaming[lower(c)] then return true end
    end
    return false
end

-- a key that starts an app marks its workspace, and the window that lands
-- there brings the workspace up with it, instead of leaving it empty
local starts = {}
local launches = {}

hl.on("window.open", function(w)
    if not w then return end
    local now = os.time()
    for name, at in pairs(starts) do
        local target = "special:" .. name
        if now - at > 30 then
            starts[name] = nil
        elseif w.workspace and w.workspace.name == target then
            starts[name] = nil
            hl.dispatch(hl.dsp.focus({ workspace = target }))
            hl.dispatch(hl.dsp.focus({ window = w }))
        end
    end
    for name, l in pairs(launches) do
        local target = "special:" .. name
        if now - l.at > 60 then
            launches[name] = nil
        elseif owns(l.app, w) then
            if not (w.workspace and w.workspace.name == target) then
                hl.dispatch(hl.dsp.window.move({ window = w, workspace = target, follow = false }))
            end
            if starts[name] then
                starts[name] = nil
                hl.dispatch(hl.dsp.focus({ workspace = target }))
                hl.dispatch(hl.dsp.focus({ window = w }))
            end
        end
    end
end)

-- rules cannot be removed, only switched off, so each apply retires the last set
local rules = {}
local ws_rules = {}

function M.apply()
    local cfg = config()
    for _, r in ipairs(rules) do r:set_enabled(false) end
    rules = {}
    for _, r in ipairs(ws_rules) do r:set_enabled(false) end
    ws_rules = {}
    if cfg.keep ~= false then
        for name, ws in pairs(cfg.workspaces) do
            if type(ws) == "table" and ws.enabled ~= false then
                for _, app in ipairs(ws.apps or {}) do
                    for field, list in pairs({ class = app.class, initial_title = app.title }) do
                        if not roams(app) and type(list) == "table" and #list > 0 then
                            rules[#rules + 1] = hl.window_rule({
                                match     = { [field] = pattern(list) },
                                workspace = "special:" .. name,
                            })
                        end
                    end
                end
            end
        end
    end
    -- a wider margin than a normal workspace's, so what is underneath shows
    -- around the windows like a card
    local gaps = math.floor(tonumber(cfg.gaps) or 0)
    if gaps > 0 then
        for name, ws in pairs(cfg.workspaces) do
            if type(ws) == "table" and ws.enabled ~= false then
                ws_rules[#ws_rules + 1] = hl.workspace_rule({
                    workspace = "special:" .. name,
                    gaps_out  = gaps,
                })
            end
        end
    end
    local opts = {}
    if type(cfg.hide_on_switch) == "boolean" then
        opts["binds.hide_special_on_workspace_change"] = cfg.hide_on_switch
    end
    if tonumber(cfg.dim) then
        opts["decoration.dim_special"] = tonumber(cfg.dim)
    end
    if type(cfg.blur) == "boolean" then
        opts["decoration.blur.special"] = cfg.blur
    end
    if next(opts) then hl.config(opts) end
end

-- open a workspace and hide it again if already up. M.toggle also starts the
-- workspace's apps; M.show only pulls in apps already running. one with
-- nothing to show yet waits for its first window instead of coming up empty
local function open(name, launch)
    local target = "special:" .. name
    local cfg = config()
    local ws = space(cfg, name)
    if ws.enabled == false then return end
    local shown = hl.get_active_special_workspace()
    if shown and shown.name == target then
        hl.dispatch(hl.dsp.workspace.toggle_special(name))
        return
    end
    local wins = hl.get_windows() or {}
    local any = false
    local starting = false
    local pulled = nil
    for _, app in ipairs(ws.apps or {}) do
        local running = false
        for _, w in ipairs(wins) do
            if owns(app, w) then
                running = true
                any = true
                if cfg.keep ~= false and not (w.workspace and w.workspace.name == target) then
                    hl.dispatch(hl.dsp.window.move({ window = w, workspace = target, follow = false }))
                    pulled = pulled or w
                end
            end
        end
        if launch and not running and type(app.cmd) == "string" and app.cmd ~= "" then
            starting = true
            if roams(app) then launches[name] = { app = app, at = os.time() } end
            hl.dispatch(hl.dsp.exec_cmd(app.cmd, { workspace = target }))
        end
    end
    if any or not starting then
        hl.dispatch(hl.dsp.focus({ workspace = target }))
        -- a window moved in without follow leaves the keyboard behind the dim
        if pulled then hl.dispatch(hl.dsp.focus({ window = pulled })) end
    else
        starts[name] = os.time()
    end
end

function M.toggle(name)
    return function() open(name, true) end
end

-- show a workspace without starting anything, pulling in only apps already up
function M.show(name)
    return function() open(name, false) end
end

-- start one app in a workspace without toggling away a workspace already up.
-- the browser key uses it to open Zen in the scratchpad, which comes up with
-- the window instead of waiting empty
function M.launch(name, cmd)
    return function()
        starts[name] = os.time()
        hl.dispatch(hl.dsp.exec_cmd(cmd, { workspace = "special:" .. name }))
    end
end

-- the scratchpad key also puts away whichever workspace is up, so one key
-- always gets you back to what you were doing
function M.scratchpad()
    return function()
        if space(config(), "special").enabled == false then return end
        local shown = hl.get_active_special_workspace()
        local name = shown and (shown.name:gsub("^special:", "")) or "special"
        hl.dispatch(hl.dsp.workspace.toggle_special(name))
    end
end

-- stash the focused window in the scratchpad, or send one that is already in a
-- special workspace back to the workspace underneath it
function M.stash()
    return function()
        local w = hl.get_active_window()
        if not w then return end
        if w.workspace and w.workspace.special then
            local under = hl.get_active_workspace()
            if under then
                hl.dispatch(hl.dsp.window.move({ window = w, workspace = under.id, follow = true }))
            end
        elseif space(config(), "special").enabled ~= false then
            hl.dispatch(hl.dsp.window.move({ window = w, workspace = "special:special", follow = false }))
        end
    end
end

-- a workspace deleted in settings hands its windows to the one you are on
function M.release(name)
    local target = "special:" .. name
    local shown = hl.get_active_special_workspace()
    if shown and shown.name == target then
        hl.dispatch(hl.dsp.workspace.toggle_special(name))
    end
    local under = hl.get_active_workspace()
    if not under then return end
    for _, w in ipairs(hl.get_windows() or {}) do
        if w.workspace and w.workspace.name == target then
            hl.dispatch(hl.dsp.window.move({ window = w, workspace = under.id, follow = false }))
        end
    end
end

-- the settings page runs hyprctl eval 'LucidSpecials.apply()' after a change
LucidSpecials = M
pcall(M.apply)

return M
