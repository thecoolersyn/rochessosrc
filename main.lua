local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GENV = (typeof(getgenv) == "function") and getgenv() or _G

local LIVE
do
	local ok, v = pcall(function() return STATE end)
	if ok and type(v) == "table" and type(v.alive) == "function" then
		LIVE = v
	end
end

local function harnessAlive()
	if LIVE and type(LIVE.alive) == "function" then
		return LIVE.alive() ~= false
	end
	return true
end

local TEARDOWN = {}

local function OnCleanup(fn)
	table.insert(TEARDOWN, fn)
	return fn
end

local function CleanupAll()
	for i = #TEARDOWN, 1, -1 do
		local fn = TEARDOWN[i]
		TEARDOWN[i] = nil
		pcall(fn)
	end
end

if type(GENV.__ROCHESS_CLEANUP) == "function" then
	pcall(GENV.__ROCHESS_CLEANUP)
end
GENV.__ROCHESS_CLEANUP = CleanupAll
if LIVE and type(LIVE.onCleanup) == "function" then
	LIVE.onCleanup(CleanupAll)
end

local CFG = GENV.__ROCHESS_CFG
if type(CFG) ~= "table" then
	CFG = {}
end
GENV.__ROCHESS_CFG = CFG
-- load persisted online setting from file
if type(readfile) == "function" then
	local ok, val = pcall(readfile, "rochess_online.txt")
	if ok and type(val) == "string" then
		CFG.online = (val:match("^%s*true%s* ) ~= nil)
	end
end

local DEFAULTS = {
	autoplay = false,
	overlay = true,
	label = true,
	eval = true,
	minDelay = 400,
	maxDelay = 900,
	randomize = true,
	online = false,
	think = 1.5,
	maxDepth = 16,
	accent = "Cyan",
	autoMatch = false,
	autoRematch = false,
}
for k, v in pairs(DEFAULTS) do
	if CFG[k] == nil then
		CFG[k] = v
	end
end

local ACCENTS = {
	Cyan = Color3.fromRGB(90, 225, 255),
	Green = Color3.fromRGB(130, 240, 140),
	Gold = Color3.fromRGB(255, 205, 95),
	Pink = Color3.fromRGB(255, 125, 200),
	White = Color3.fromRGB(255, 255, 255),
}

local function accentColor()
	return ACCENTS[CFG.accent] or ACCENTS.Cyan
end

local LOG = "[RoChess] starting"

local App, Bot, Engine

local function resolveModules()
	if type(App) == "table" then
		return App
	end
	local chess = ReplicatedStorage:FindFirstChild("Chess")
	local client = ReplicatedStorage:FindFirstChild("ChessClient")
	if not chess or not client then
		LOG = "this game does not contain Chess/ChessClient"
		return nil
	end
	local okA, a = pcall(function() return require(client.App) end)
	if not okA or type(a) ~= "table" then
		LOG = "ChessClient.App failed to require"
		return nil
	end
	local okE, e = pcall(function() return require(chess.Engine) end)
	if not okE or type(e) ~= "table" then
		LOG = "Chess.Engine failed to require"
		return nil
	end
	local okB, b = pcall(function() return require(chess.Bot) end)
	App = a
	Engine = e
	Bot = (okB and type(b) == "table") and b or nil
	return App
end

local function guardSearchHook()
	if type(Bot) ~= "table" then
		return
	end
	if Bot.onSearch ~= nil then
		if GENV.__ROCHESS_ONSEARCH == nil then
			GENV.__ROCHESS_ONSEARCH = Bot.onSearch
		end
		Bot.onSearch = nil
	end
end

OnCleanup(function()
	local old = GENV.__ROCHESS_ONSEARCH
	GENV.__ROCHESS_ONSEARCH = nil
	if type(Bot) ~= "table" then
		return
	end
	if type(old) == "function" then
		Bot.onSearch = old
	else
		Bot.onSearch = nil
	end
end)

local BEST = nil
local SEARCHING = false
local SESSION = nil
local TURN_KEY = nil
local TURN_START = 0
local TURN_DELAY = 0
local MOVE_PLY = nil
local FAIL_KEY = nil
local RUNNING = true
local STATUS = nil

local PROMO = { q = 5, r = 4, b = 3, n = 2 }

local function clampNum(v, lo, hi)
	return math.clamp(tonumber(v) or lo, lo, hi)
end

local function posKey(s)
	if type(s) ~= "table" then
		return nil
	end
	local ply = (type(s.ucis) == "table") and #s.ucis or -1
	local fen = "?"
	if type(s.engine) == "table" and type(s.engine.getFen) == "function" then
		local ok, f = pcall(s.engine.getFen, s.engine)
		if ok and type(f) == "string" then
			fen = f
		end
	end
	return tostring(s.kind or "?") .. "|" .. fen .. "|" .. tostring(ply)
end

local function fmtEval(score, mate)
	local mateN = tonumber(mate)
	if mateN ~= nil and mateN ~= 0 then
		return (mateN > 0 and "#" or "-#") .. tostring(math.abs(mateN))
	end
	local s = tonumber(score)
	if s == nil then
		return "?"
	end
	return string.format("%+.2f", s / 100)
end

local function sanitize()
	local lo = clampNum(CFG.minDelay, 0, 3000)
	local hi = clampNum(CFG.maxDelay, 0, 3000)
	if hi < lo then
		lo, hi = hi, lo
	end
	CFG.minDelay = lo
	CFG.maxDelay = hi
	CFG.think = clampNum(CFG.think, 0.2, 8)
	CFG.maxDepth = clampNum(CFG.maxDepth, 2, 40)
end
sanitize()

local function allowedKind(kind)
	if kind == "bot" then
		return true
	end
	if CFG.online and kind == "online" then
		return true
	end
	return false
end

local function runAnalysis(s)
	if type(Bot) ~= "table" or type(Bot.analyse) ~= "function" then
		LOG = "engine (Chess.Bot) unavailable"
		return nil
	end
	if type(s) ~= "table" or type(s.ucis) ~= "table" then
		return nil
	end

	local startFen = s.startFen
	if type(startFen) ~= "string" or #startFen < 5 then
		startFen = (type(Engine) == "table" and type(Engine.START_FEN) == "string") and Engine.START_FEN or nil
	end
	sanitize()
	local t0 = os.clock()
	local ok, res = pcall(Bot.analyse, startFen, table.clone(s.ucis), CFG.think, CFG.maxDepth)
	local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
	if not ok or type(res) ~= "table" then
		LOG = "analyse failed: " .. tostring(res)
		return nil
	end
	local uci = res.best
	if type(uci) ~= "string" or #uci < 4 then
		LOG = "no move this position: " .. tostring(res.terminal or "search returned nothing")
		return nil
	end

	local myColor = tonumber(s.myColor) or 1
	local score = tonumber(res.score)
	local mate = tonumber(res.mate)
	local from = Engine.algToIndex64(string.sub(uci, 1, 2))
	local to = Engine.algToIndex64(string.sub(uci, 3, 4))
	if type(from) ~= "number" or type(to) ~= "number" then
		LOG = "bad engine move: " .. uci
		return nil
	end
	local promo = 0
	local pc = string.sub(uci, 5)
	if pc ~= "" then
		promo = PROMO[pc] or 0
	end

	local san = uci
	if type(Engine.new) == "function" and type(s.engine) == "table" and type(s.engine.getFen) == "function" then
		local okF, tmp = pcall(Engine.new, s.engine:getFen())
		if okF and type(tmp) == "table" then
			local okM, mv = pcall(function() return tmp:moveFromUci(uci) end)
			if okM and mv then
				local okP, played = pcall(function() return tmp:play(mv) end)
				if okP and type(played) == "string" and #played > 0 then
					san = played
				end
			end
		end
	end

	return {
		key = posKey(s),
		ply = (type(s.ucis) == "table") and #s.ucis or -1,
		uci = uci,
		san = san,
		from = from,
		to = to,
		promo = promo,
		povScore = score and (score * myColor) or nil,
		povMate = mate and (mate * myColor) or nil,
		depth = tonumber(res.depth),
		nodes = tonumber(res.nodes),
		ms = ms,
	}
end

local function playBest(s, key)
	if type(s) ~= "table" or type(App) ~= "table" or type(BEST) ~= "table" then
		return false, "nothing to play"
	end
	if s.over or type(s.isMyTurn) ~= "function" or not s:isMyTurn() then
		return false, "not your turn"
	end
	local ply = (type(s.ucis) == "table") and #s.ucis or -1
	if s.viewPly ~= ply then
		return false, "viewing history"
	end
	local k = key or posKey(s)
	if BEST.key ~= k then
		return false, "stale move"
	end
	local ok, res = pcall(App.onBoardMove, BEST.from, BEST.to, BEST.promo)
	if not ok then
		return false, "onBoardMove errored: " .. tostring(res)
	end
	if res ~= true then
		return false, "move rejected by the game"
	end
	return true, tostring(BEST.san)
end

local OV = nil

local function killInstance(inst)
	if inst then
		pcall(function() inst:Destroy() end)
	end
end

local function destroyOverlay()
	if OV then
		killInstance(OV.root)
		OV = nil
	end
end
OnCleanup(destroyOverlay)

local function overlayPart(parent, name, z, corner, strokeT)
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = accentColor()
	f.BackgroundTransparency = 0
	f.BorderSizePixel = 0
	f.Active = false
	f.Size = UDim2.fromOffset(0, 0)
	f.ZIndex = z
	if corner then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(corner, 0)
		c.Parent = f
	end
	if strokeT then
		local st = Instance.new("UIStroke")
		st.Thickness = strokeT
		st.Parent = f
	end
	f.Parent = parent
	return f
end

local function ensureOverlay()
	local app = App
	if type(app) ~= "table" or type(app.board) ~= "table" then
		return nil
	end
	local b = app.board
	local f = b.frame
	if not f or not f:IsA("GuiObject") then
		return nil
	end
	if OV and OV.root and OV.root.Parent == f then
		return OV
	end
	destroyOverlay()

	local root = Instance.new("Frame")
	root.Name = "RoChessOverlay"
	root.Archivable = false
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Active = false
	root.ClipsDescendants = false
	root.Size = UDim2.fromScale(1, 1)
	root.Position = UDim2.fromScale(0, 0)
	root.ZIndex = 40
	root.Visible = false
	root.Parent = f

	local src = overlayPart(root, "SRC", 41, 0.12, 3)
	src.BackgroundTransparency = 0.55

	local glow = overlayPart(root, "LINE_GLOW", 42, 0.5, nil)
	glow.BackgroundTransparency = 0.75

	local line = overlayPart(root, "LINE", 43, 0.5, nil)

	local dst = overlayPart(root, "DST", 44, 1, nil)
	dst.BackgroundTransparency = 0.85
	local dstStroke = Instance.new("UIStroke")
	dstStroke.Thickness = 4
	dstStroke.Color = accentColor()
	dstStroke.Parent = dst

	local tag = Instance.new("TextLabel")
	tag.Name = "TAG"
	tag.AnchorPoint = Vector2.new(0.5, 1)
	tag.AutomaticSize = Enum.AutomaticSize.X
	tag.BackgroundColor3 = accentColor()
	tag.BackgroundTransparency = 0.15
	tag.BorderSizePixel = 0
	tag.Size = UDim2.fromOffset(0, 30)
	tag.Font = Enum.Font.GothamBold
	tag.TextSize = 20
	tag.TextColor3 = Color3.fromRGB(12, 18, 26)
	tag.TextXAlignment = Enum.TextXAlignment.Center
	tag.Text = ""
	tag.ZIndex = 46
	tag.Active = false
	tag.Visible = false
	local tagCorner = Instance.new("UICorner")
	tagCorner.CornerRadius = UDim.new(0.35, 0)
	tagCorner.Parent = tag
	tag.Parent = root

	OV = {
		root = root,
		src = src,
		glow = glow,
		line = line,
		dst = dst,
		dstStroke = dstStroke,
		tag = tag,
	}
	return OV
end

local function overlaySet(best)
	if not best or not CFG.overlay then
		if OV then
			OV.root.Visible = false
		end
		return
	end
	local ov = ensureOverlay()
	if not ov then
		return
	end
	local b = App.board
	local f = b.frame
	local size = f.AbsoluteSize
	if size.X <= 4 or size.Y <= 4 then
		ov.root.Visible = false
		return
	end
	local sqx = size.X / 8
	local sqy = size.Y / 8

	local function center(idx)
		local col, row = b:colRow(idx)
		return Vector2.new((col + 0.5) * sqx, (row + 0.5) * sqy)
	end

	local a = center(best.from)
	local c = center(best.to)
	local dx = c.X - a.X
	local dy = c.Y - a.Y
	local len = math.sqrt(dx * dx + dy * dy)
	local mid = Vector2.new((a.X + c.X) * 0.5, (a.Y + c.Y) * 0.5)
	local ang = math.deg(math.atan2(dy, dx))
	local col = accentColor()

	ov.src.Position = UDim2.fromOffset(a.X, a.Y)
	ov.src.Size = UDim2.fromOffset(sqx * 0.96, sqy * 0.96)
	ov.src.BackgroundColor3 = col

	ov.glow.Position = UDim2.fromOffset(mid.X, mid.Y)
	ov.glow.Size = UDim2.fromOffset(len, 16)
	ov.glow.Rotation = ang
	ov.glow.BackgroundColor3 = col

	ov.line.Position = UDim2.fromOffset(mid.X, mid.Y)
	ov.line.Size = UDim2.fromOffset(len, 7)
	ov.line.Rotation = ang
	ov.line.BackgroundColor3 = col

	ov.dst.Position = UDim2.fromOffset(c.X, c.Y)
	ov.dst.Size = UDim2.fromOffset(sqx * 0.58, sqy * 0.58)
	ov.dst.BackgroundColor3 = col
	ov.dstStroke.Color = col

	local text = ""
	if CFG.label then
		text = tostring(best.san or best.uci or "?")
	end
	if CFG.eval then
		local ev = fmtEval(best.povScore, best.povMate)
		if ev ~= "?" then
			text = (text ~= "") and (text .. "  " .. ev) or ev
		end
	end
	if text ~= "" then
		ov.tag.Text = text
		ov.tag.BackgroundColor3 = col
		ov.tag.Position = UDim2.fromOffset(c.X, c.Y - sqy * 0.62)
		ov.tag.Visible = true
	else
		ov.tag.Visible = false
	end

	ov.root.Visible = true
end

local function ensureGamelistRow()
	if type(writefile) ~= "function" or type(readfile) ~= "function" then
		return false
	end
	local uid = tonumber(game.GameId) or 0
	if uid == 0 then
		return false
	end
	local CACHE = "Hyperion/game-list-cache.txt"
	local body = ""
	do
		local ok, cur = pcall(readfile, CACHE)
		if ok and type(cur) == "string" then
			body = cur
		end
	end
	if string.find(body, "UniverseId%s*=%s*" .. tostring(uid)) then
		return false
	end
	local rows = {}
	local okF, fn = pcall((loadstring or load), body)
	if okF and fn then
		local ok2, val = pcall(fn)
		if ok2 and type(val) == "table" then
			for _, entry in ipairs(val) do
				if type(entry) == "table" then
					table.insert(rows, entry)
				end
			end
		end
	end
	for _, entry in ipairs(rows) do
		if tonumber(entry.UniverseId) == uid then
			return false
		end
	end
	local name = "Game " .. tostring(uid)
	local creator = "Unknown"
	local creatorId = "0"
	local okP, prod = pcall(function()
		return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
	end)
	if okP and type(prod) == "table" then
		name = tostring(prod.Name or name)
		local c = prod.Creator
		if type(c) == "table" then
			creator = tostring(c.Name or creator)
			creatorId = tostring(tonumber(c.CreatorTargetId) or 0)
		end
	end
	table.insert(rows, {
		GameName = name,
		UniverseId = uid,
		CreatorName = creator,
		CreatorId = creatorId,
	})
	local parts = { "return {" }
	for _, entry in ipairs(rows) do
		table.insert(parts, string.format(
			'  { GameName = %s, UniverseId = %s, CreatorName = %s, CreatorId = %s },',
			string.format("%q", tostring(entry.GameName or "?")),
			tostring(tonumber(entry.UniverseId) or 0),
			string.format("%q", tostring(entry.CreatorName or "Unknown")),
			tostring(tonumber(entry.CreatorId) or 0)
		))
	end
	table.insert(parts, "}")
	return (pcall(writefile, CACHE, table.concat(parts, "\n")))
end

local function loadSyniscool()
	ensureGamelistRow()
	if GENV.HyperionGameListUrl == nil or GENV.HyperionGameListUrl == "" then
		GENV.HyperionGameListUrl = "http://127.0.0.1:1/none"
	end
	local src
	if type(readfile) == "function" then
		local ok, body = pcall(readfile, "syniscool_cached.luau")
		if ok and type(body) == "string" and #body > 1000 then
			src = body
		end
	end
	if not src then
		local okH, body = pcall(function()
			return game:HttpGet("https://raw.githubusercontent.com/thecoolersyn/syniscool/main/src.lua", true)
		end)
		if okH and type(body) == "string" and #body > 1000 then
			src = body
			if type(writefile) == "function" then
				pcall(writefile, "syniscool_cached.luau", src)
			end
		end
	end
	if type(src) ~= "string" then
		LOG = "syniscool source unavailable"
		return nil
	end
	local fn = (loadstring or load)(src)
	if not fn then
		LOG = "syniscool failed to compile"
		return nil
	end
	local ok, lib = pcall(fn)
	if not ok or type(lib) ~= "table" then
		LOG = "syniscool failed to init: " .. tostring(lib)
		return nil
	end
	return lib
end

local CTRL = {}
local WINDOW = nil

local function readCtrlGet(obj)
	if type(obj) == "table" and type(obj.Get) == "function" then
		local ok, v = pcall(obj.Get, obj)
		if ok and v ~= nil then
			return v
		end
	end
	if type(obj) == "table" and type(obj.Obj) == "table" and type(obj.Obj.Get) == "function" then
		local ok, v = pcall(obj.Obj.Get, obj.Obj)
		if ok and v ~= nil then
			return v
		end
	end
	if type(obj) == "table" and obj.Value ~= nil then
		return obj.Value
	end
	return nil
end

local function syncSettings()
	local v
	v = readCtrlGet(CTRL.PRED)
	if v ~= nil then
		CFG.overlay = (v == true)
	end
	v = readCtrlGet(CTRL.LABEL)
	if v ~= nil then
		CFG.label = (v == true)
	end
	v = readCtrlGet(CTRL.EVALTXT)
	if v ~= nil then
		CFG.eval = (v == true)
	end
	v = readCtrlGet(CTRL.RND)
	if v ~= nil then
		CFG.randomize = (v == true)
	end
	v = readCtrlGet(CTRL.ONLINE)
	if v ~= nil then
		CFG.online = (v == true)
	end
	v = tonumber(readCtrlGet(CTRL.MINDELAY))
	if v ~= nil then
		CFG.minDelay = math.floor(v)
	end
	v = tonumber(readCtrlGet(CTRL.MAXDELAY))
	if v ~= nil then
		CFG.maxDelay = math.floor(v)
	end
	v = tonumber(readCtrlGet(CTRL.THINK))
	if v ~= nil then
		CFG.think = v
	end
	v = tonumber(readCtrlGet(CTRL.DEPTH))
	if v ~= nil then
		CFG.maxDepth = math.floor(v)
	end
	v = readCtrlGet(CTRL.ACCENT)
	if v ~= nil then
		CFG.accent = tostring(v)
	end
	sanitize()
end

local function notify(title, text)
	if type(WINDOW) ~= "table" or type(WINDOW.Notify) ~= "function" then
		return
	end
	pcall(WINDOW.Notify, WINDOW, {
		Title = title or "RoChess",
		Text = text or "",
		Duration = 3,
	})
end

local function onAutoplayChanged(on)
	CFG.autoplay = (on == true)
	MOVE_PLY = nil
end

local function onOnlineChanged(on)
	CFG.online = (on == true)
	-- persist to file
	if type(writefile) == "function" then
		pcall(writefile, "rochess_online.txt", CFG.online and "true" or "false")
	end
end

local function onOverlayChanged(on)
	CFG.overlay = (on == true)
	if not CFG.overlay then
		destroyOverlay()
	end
end

local function refreshStatus()
	local s = nil
	if type(App) == "table" then
		s = App.session
	end
	if type(s) ~= "table" then
		return tostring(LOG)
	end
	local ply = (type(s.ucis) == "table") and #s.ucis or -1
	local turn = "opponent"
	if s.over then
		turn = "finished"
	elseif type(s.isMyTurn) == "function" and s:isMyTurn() then
		turn = "you"
	end
	local line1 = string.format("kind=%s  ply=%d  turn=%s", tostring(s.kind), ply, turn)
	local line2 = "autoplay OFF"
	if CFG.autoplay then
		line2 = string.format("autoplay ON   delay %d-%d ms%s", CFG.minDelay, CFG.maxDelay, CFG.randomize and " (random)" or "")
	end
	local line3 = tostring(LOG)
	if type(BEST) == "table" then
		line3 = string.format(
			"best %s (%s)  %s  depth %s  %d ms  %s nodes",
			tostring(BEST.san),
			tostring(BEST.uci),
			fmtEval(BEST.povScore, BEST.povMate),
			tostring(BEST.depth),
			tonumber(BEST.ms) or 0,
			tostring(BEST.nodes)
		)
	end
	return line1 .. "\n" .. line2 .. "\n" .. line3
end

local function onPlayNow()
	syncSettings()
	local app = resolveModules()
	if type(app) ~= "table" then
		notify("RoChess", "game modules missing")
		return
	end
	local s = app.session
	if type(s) ~= "table" or s.over then
		notify("RoChess", "no live game right now")
		return
	end
	if SEARCHING then
		notify("RoChess", "a search is already running")
		return
	end
	local key = posKey(s)
	if type(BEST) ~= "table" or BEST.key ~= key then
		SEARCHING = true
		BEST = runAnalysis(s)
		SEARCHING = false
		FAIL_KEY = nil
	end
	if type(BEST) ~= "table" then
		FAIL_KEY = key
		notify("RoChess", "no best move for this position")
		return
	end
	local okMove, why = playBest(s, key)
	if okMove then
		MOVE_PLY = (type(s.ucis) == "table") and #s.ucis or -1
		LOG = "played " .. tostring(why)
		notify("RoChess", "played " .. tostring(why))
	else
		LOG = "manual play failed: " .. tostring(why)
		notify("RoChess", tostring(why))
	end
end

local function onAnalyzeNow()
	syncSettings()
	local app = resolveModules()
	if type(app) ~= "table" then
		notify("RoChess", "game modules missing")
		return
	end
	local s = app.session
	if type(s) ~= "table" then
		notify("RoChess", "no session")
		return
	end
	if SEARCHING then
		notify("RoChess", "a search is already running")
		return
	end
	SEARCHING = true
	local res = runAnalysis(s)
	SEARCHING = false
	if type(res) == "table" then
		BEST = res
		FAIL_KEY = nil
		overlaySet(BEST)
		notify("RoChess", string.format(
			"%s   %s   depth %s   %d ms",
			tostring(res.san),
			fmtEval(res.povScore, res.povMate),
			tostring(res.depth),
			res.ms or 0
		))
	else
		FAIL_KEY = posKey(s)
		notify("RoChess", "analysis failed, see status")
	end
end

local function onForceResolve()
	App = nil
	Bot = nil
	Engine = nil
	SESSION = nil
	BEST = nil
	destroyOverlay()
	LOG = "modules will be re-resolved on the next tick"
end

local function buildUI(lib)
	local okW, window = pcall(function()
		return lib:CreateWindow({
			Title = "RoChess",
			ToggleKey = "LeftControl",
		})
	end)
	if not okW or type(window) ~= "table" then
		LOG = "CreateWindow failed"
		return false
	end
	WINDOW = window

	local okP, playTab = pcall(function()
		return window:AddTab({ Name = "RoChess", Icon = "sword" })
	end)
	if not okP or type(playTab) ~= "table" then
		LOG = "AddTab failed"
		return false
	end
	local okE, engineTab = pcall(function()
		return window:AddTab({ Name = "Engine", Icon = "sliders" })
	end)
	local okD, dbgTab = pcall(function()
		return window:AddTab({ Name = "Debug", Icon = "terminal" })
	end)

	local autoMod = playTab:AddModule({
		Name = "Autoplay",
		Default = false,
		NotifyOnToggle = true,
		Callback = onAutoplayChanged,
	})
	CTRL.AUTOPLAY = autoMod

	CTRL.MAXDELAY = autoMod:AddSlider({
		Name = "Max delay (ms)",
		Min = 0,
		Max = 3000,
		Default = CFG.maxDelay,
		Decimals = 0,
	})
	CTRL.MINDELAY = autoMod:AddSlider({
		Name = "Min delay (ms)",
		Min = 0,
		Max = 3000,
		Default = CFG.minDelay,
		Decimals = 0,
	})
	CTRL.RND = autoMod:AddToggle({
		Name = "Randomized delay",
		Default = CFG.randomize,
	})
	CTRL.ONLINE = autoMod:AddToggle({
		Name = "Allow online games",
		Default = CFG.online,
		Callback = onOnlineChanged,
	})
	autoMod:AddButton({
		Name = "Play best move now",
		Callback = onPlayNow,
	})

	-- Auto Match -----------------------------------------------------------
	local autoMatchMod = playTab:AddModule({
		Name = "Auto Queue",
		Default = CFG.autoMatch == true,
		NotifyOnToggle = true,
		Callback = function(on)
			GENV.__rochess.autoMatch(on == true)
		end,
	})
	CTRL.AUTOMATCH = autoMatchMod

	-- Auto Rematch --------------------------------------------------------
	local autoRematchMod = playTab:AddModule({
		Name = "Auto Rematch",
		Default = CFG.autoRematch == true,
		NotifyOnToggle = true,
		Callback = function(on)
			GENV.__rochess.autoRematch(on == true)
		end,
	})
	CTRL.AUTOREMATCH = autoRematchMod

	-- Auto Execute ---------------------------------------------------------
	local autoExecMod = playTab:AddModule({
		Name = "Auto Execute",
		Default = false,
	})
	autoExecMod:AddButton({
		Name = "Queue auto-execute",
		Callback = function()
			local ok, msg = GENV.__rochess.queueAutoExecute()
			if ok then
				notify("RoChess", "auto-execute queued")
			else
				notify("RoChess", "queue failed: " .. tostring(msg))
			end
		end,
	})

	local predMod = playTab:AddModule({
		Name = "Predictor",
		Default = true,
	})
	CTRL.PRED = predMod:AddToggle({
		Name = "Show predicted move",
		Default = CFG.overlay,
		Callback = onOverlayChanged,
	})
	CTRL.LABEL = predMod:AddToggle({
		Name = "Show move label",
		Default = CFG.label,
	})
	CTRL.EVALTXT = predMod:AddToggle({
		Name = "Show eval",
		Default = CFG.eval,
	})
	CTRL.ACCENT = predMod:AddDropdown({
		Name = "Accent colour",
		Options = { "Cyan", "Green", "Gold", "Pink", "White" },
		Default = ACCENTS[CFG.accent] and CFG.accent or "Cyan",
	})

	if type(engineTab) == "table" then
		local searchMod = engineTab:AddModule({
			Name = "Search",
			Default = true,
		})
		CTRL.THINK = searchMod:AddSlider({
			Name = "Think time (s)",
			Min = 0.2,
			Max = 8,
			Default = CFG.think,
			Decimals = 1,
		})
		CTRL.DEPTH = searchMod:AddSlider({
			Name = "Max depth",
			Min = 2,
			Max = 40,
			Default = CFG.maxDepth,
			Decimals = 0,
		})
		searchMod:AddButton({
			Name = "Analyze now",
			Callback = onAnalyzeNow,
		})
	end

	if type(dbgTab) == "table" then
		local dbgMod = dbgTab:AddModule({
			Name = "Runtime",
			Default = true,
		})
		STATUS = dbgMod:AddLabel({
			Text = refreshStatus(),
		})
		dbgMod:AddButton({
			Name = "Re-resolve game modules",
			Callback = onForceResolve,
		})
	end

	return true
end

local function hideOverlay()
	if OV then
		OV.root.Visible = false
	end
end

local function tick()
	syncSettings()
	guardSearchHook()
	local app = resolveModules()
	if type(app) ~= "table" then
		hideOverlay()
		return
	end
	local s = app.session
	if s ~= SESSION then
		SESSION = s
		BEST = nil
		TURN_KEY = nil
		TURN_START = 0
		TURN_DELAY = 0
		MOVE_PLY = nil
		FAIL_KEY = nil
	end
	if type(s) ~= "table" or s.over then
		hideOverlay()
		return
	end
	local ply = (type(s.ucis) == "table") and #s.ucis or -1
	if s.viewPly ~= ply then

		hideOverlay()
		return
	end
	if type(s.isMyTurn) ~= "function" or not s:isMyTurn() then
		hideOverlay()
		TURN_KEY = nil
		return
	end

	local key = posKey(s)
	if key ~= TURN_KEY then
		TURN_KEY = key
		TURN_START = os.clock()
		BEST = nil
		FAIL_KEY = nil
		local lo = CFG.minDelay
		local hi = CFG.maxDelay
		if hi < lo then
			hi = lo
		end
		if CFG.randomize and hi > lo then
			TURN_DELAY = (lo + math.random() * (hi - lo)) / 1000
		else
			TURN_DELAY = hi / 1000
		end
	end

	if (type(BEST) ~= "table" or BEST.key ~= key) and key ~= FAIL_KEY and not SEARCHING then
		SEARCHING = true
		local res = runAnalysis(s)
		SEARCHING = false

		if SESSION ~= s or type(App) ~= "table" or App.session ~= s or s.over then
			return
		end
		if type(res) == "table" then
			BEST = res
			FAIL_KEY = nil
			if tonumber(res.povMate) ~= nil and math.abs(res.povMate) > 0 and math.abs(res.povMate) <= 6 then
				LOG = "mate available: " .. tostring(res.san)
				notify("RoChess", "mate in " .. tostring(math.abs(res.povMate)) .. "  " .. tostring(res.san))
			end
		else
			FAIL_KEY = key
		end
	end

	if type(BEST) == "table" and BEST.key == key then
		overlaySet(BEST)
	else
		hideOverlay()
	end

	if CFG.autoplay and allowedKind(s.kind) and type(BEST) == "table" and BEST.key == key and ply ~= MOVE_PLY then
		local waited = os.clock() - TURN_START
		if waited >= TURN_DELAY then
			local okMove, why = playBest(s, key)
			if okMove then
				MOVE_PLY = (type(s.ucis) == "table") and #s.ucis or -1
				hideOverlay()
				LOG = "autoplay played " .. tostring(why)
			elseif why == "viewing history" or why == "not your turn" or why == "stale move" or why == "nothing to play" then

				LOG = "autoplay waiting: " .. tostring(why)
			else

				MOVE_PLY = ply
				LOG = "autoplay stopped: " .. tostring(why)
				notify("RoChess", "autoplay stopped: " .. tostring(why))
				CFG.autoplay = false
				local ctrl = CTRL.AUTOPLAY
				if type(ctrl) == "table" and type(ctrl.Set) == "function" then
					pcall(ctrl.Set, ctrl, false)
				end
			end
		end
	end
end

local API = {}

API.state = function()
	local app = resolveModules()
	local s = nil
	if type(app) == "table" then
		s = app.session
	end
	return {
		alive = RUNNING,
		log = LOG,
		best = BEST,
		cfg = CFG,
		sessionKind = (type(s) == "table") and s.kind or nil,
		ply = (type(s) == "table" and type(s.ucis) == "table") and #s.ucis or nil,
		yourTurn = (type(s) == "table" and type(s.isMyTurn) == "function") and s:isMyTurn() or false,
	}
end

API.analyze = onAnalyzeNow
API.play = onPlayNow
API.set = function(name, value)
	if name == "autoplay" then
		CFG.autoplay = (value == true)
	elseif name == "online" then
		CFG.online = (value == true)
	end
end

API.hide = function()
	hideOverlay()
end

GENV.__rochess = API

local AUTO_MATCH = (CFG.autoMatch == true)
local AUTO_REMATCH = (CFG.autoRematch == true)
local AUTO_MATCH_COOLDOWN = 0
local AUTO_REMATCH_COOLDOWN = 0

local function triggerRematch()
	if not AUTO_MATCH then
		return false, "auto match disabled"
	end
	local now = os.clock()
	if now - AUTO_MATCH_COOLDOWN < 5 then
		return false, "cooldown"
	end
	local app = resolveModules()
	if type(app) ~= "table" then
		return false, "no app"
	end
	-- Find the randomized queue remote dynamically
	local chess = game:GetService("ReplicatedStorage"):FindFirstChild("Chess")
	local queueRemote = nil
	if chess then
		for _, child in ipairs(chess:GetChildren()) do
			if child:IsA("Folder") and #child.Name == 10 then
				for _, r in ipairs(child:GetChildren()) do
					if r:IsA("RemoteEvent") then
						queueRemote = r
						break
					end
				end
				if queueRemote then break end
			end
		end
	end
	if not queueRemote then
		return false, "queue remote not found"
	end
	AUTO_MATCH_COOLDOWN = now
	local ok, err = pcall(function()
		queueRemote:FireServer({type = "queue", tc = "3+2"})
	end)
	if not ok then
		return false, tostring(err)
	end
	return true, "queued online 3+2"
end

local function triggerRematchOffer()
	if not AUTO_REMATCH then
		return false, "auto rematch disabled"
	end
	local now = os.clock()
	if now - AUTO_REMATCH_COOLDOWN < 5 then
		return false, "cooldown"
	end
	local app = resolveModules()
	if type(app) ~= "table" then
		return false, "no app"
	end
	if type(app.rematch) ~= "function" then
		return false, "rematch unavailable"
	end
	AUTO_REMATCH_COOLDOWN = now
	local ok, err = pcall(app.rematch)
	if not ok then
		return false, tostring(err)
	end
	return true, "rematch offered"
end

local function autoRematchTick()
	if not AUTO_REMATCH then
		return
	end
	local app = resolveModules()
	if type(app) ~= "table" then
		return
	end
	local s = app.session
	if type(s) ~= "table" then
		return
	end
	if not s.over then
		return
	end
	triggerRematchOffer()
end

local function autoMatchTick()
	if not AUTO_MATCH then
		return
	end
	local app = resolveModules()
	if type(app) ~= "table" then
		return
	end
	local s = app.session
	if type(s) ~= "table" then
		return
	end
	if not s.over then
		return
	end
	triggerRematch()
end

API.autoMatch = function(enabled)
	AUTO_MATCH = (enabled == true)
	if enabled ~= nil then
		CFG.autoMatch = AUTO_MATCH
	end
end

API.autoRematch = function(enabled)
	AUTO_REMATCH = (enabled == true)
	if enabled ~= nil then
		CFG.autoRematch = AUTO_REMATCH
	end
end

-- ---------------------------------------------------------------------------
-- auto-execute: queue script to run after teleport
-- ---------------------------------------------------------------------------
local function queueAutoExecute()
	local q = queue_on_teleport or queueonteleport
		or (syn and syn.queue_on_teleport)
		or (fluxus and fluxus.queue_on_teleport)
		or (KRNL_LOADED and (function(s) if type(queueonteleport) == "function" then queueonteleport(s) end end))
	if type(q) ~= "function" then
		return false, "queue_on_teleport unavailable"
	end
	local url = "https://raw.githubusercontent.com/thecoolersyn/rochessosrc/main/main.lua"
	local payload = 'loadstring(game:HttpGet("' .. url .. '", true))()'
	local ok, err = pcall(q, payload)
	if not ok then
		return false, tostring(err)
	end
	return true, "queued"
end


API.queueAutoExecute = queueAutoExecute

task.spawn(function()
	while harnessAlive() and RUNNING do
		task.wait(1)
		pcall(autoMatchTick)
	end
end)

task.spawn(function()
	while harnessAlive() and RUNNING do
		task.wait(1)
		pcall(autoRematchTick)
	end
end)

print("[RoChess] auto-execute queued, auto queue " .. (AUTO_MATCH and "ON" or "OFF"))
OnCleanup(function()
	RUNNING = false
end)

local okUI, errUI = pcall(buildUI, loadSyniscool())
if not okUI then
	LOG = "UI failed: " .. tostring(errUI)
	warn("[RoChess] UI: " .. tostring(errUI))
	syncSettings()
end

task.spawn(function()
	while harnessAlive() and RUNNING do
		task.wait(0.6)
		if typeof(STATUS) == "Instance" then
			pcall(function()
				STATUS.Text = refreshStatus()
			end)
		end
	end
end)

task.spawn(function()
	while harnessAlive() and RUNNING do
		local okT, errT = pcall(tick)
		if not okT then
			LOG = "tick error: " .. tostring(errT)
		end
		task.wait(0.1)
	end
end)

print("[RoChess] loaded: overlay on your turn, autoplay in the RoChess tab, LeftControl toggles the window")
return {
	tick = tick,
	state = API.state,
	analyze = API.analyze,
	play = API.play,
	autoMatch = API.autoMatch,
	autoRematch = API.autoRematch,
	queueAutoExecute = API.queueAutoExecute,
}
