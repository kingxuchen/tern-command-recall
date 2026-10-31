-- command-recall, Tern window half: optional GUI picker over the shared shell
-- memory (`$TERN_RECALL_DIR/learned/<program>`).
--
-- The zsh plugin (`shell/tern-recall.zsh`) is the sole learner and completer
-- across every terminal (Ghostty, Tern, tty7, Otty, iTerm2). This file only
-- exposes Tern command-palette shortcuts to inspect the shared store or copy
-- the `.zshrc` source line.

local function dataDir()
	local custom = tern.getenv("TERN_RECALL_DIR")
	if custom and custom ~= "" then
		return custom
	end
	local xdg = tern.getenv("XDG_DATA_HOME")
	if xdg and xdg ~= "" then
		return xdg .. "/command-recall"
	end
	local home = tern.getenv("HOME") or ""
	return home .. "/.local/share/command-recall"
end

local DATA = dataDir()
local LEARNED = DATA .. "/learned"
local ZSHRC_MARK = DATA .. "/zshrc-configured"
local SHELL_FILE = tern.plugin.dir .. "/shell/tern-recall.zsh"
local SHELL_LINE = '[ -r "' .. SHELL_FILE .. '" ] && . "' .. SHELL_FILE .. '"'
-- Rows one program shows in the picker.
local PICK_ROWS = 40

local function readRows(program, limit)
	local path = LEARNED .. "/" .. program
	if not tern.fs.exists(path) then
		return {}
	end
	local rows = {}
	local text = tern.fs.read(path, 400000)
	for line in string.gmatch(text, "([^\n]+)") do
		local token, context = string.match(line, "^([^\t]*)\t[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t(.*)$")
		if token and token ~= "" then
			table.insert(rows, {
				token = token,
				context = context or "",
				line = program .. (context ~= "" and (" " .. context) or "") .. " " .. token,
			})
			if limit and #rows >= limit then
				break
			end
		end
	end
	return rows
end

-- Programs the store has learned, with their three best rows as a preview.
local function programs()
	if not tern.fs.exists(LEARNED) then
		return {}
	end
	local items = {}
	for _, name in tern.fs.list(LEARNED) do
		local rows = readRows(name, 3)
		if #rows > 0 then
			local top = {}
			for _, row in rows do
				table.insert(top, row.token)
			end
			table.insert(items, { label = name, detail = table.concat(top, "  ") })
		end
	end
	table.sort(items, function(a, b)
		return a.label < b.label
	end)
	return items
end

tern.command({
	id = "show",
	title = "Command Recall: 查看已学命令",
	icon = "sparkle",
	group = "Command Recall",
	run = function(cx)
		local items = programs()
		if #items == 0 then
			cx:toast("info", "还没有学到命令", "在终端里敲几条命令，再按 Tab 看看")
			return
		end
		cx:pick({ items = items, placeholder = "选一个命令" }):next(function(chosen)
			if not chosen then
				return
			end
			local picks = {}
			for _, row in readRows(chosen.label, PICK_ROWS) do
				table.insert(picks, { label = row.line, insert = row.line })
			end
			if #picks == 0 then
				return
			end
			cx:pick({ items = picks, placeholder = "插入这条命令（不回车）", action = "insert" }):next(
				function(pick)
					local pane = cx.session:focused()
					if pick and pane then
						cx:run(pane, pick.insert)
					end
				end
			)
		end)
	end,
})

local function installZshrc(notifyAlways)
	tern.process.run({ "/bin/zsh", SHELL_FILE, "--install" }, { timeout_ms = 5000 }, function(res, cx)
		if not cx then
			return
		end
		local out = (res and res.stdout or "")
		if string.match(out, "^installed") or string.match(out, "^upgraded") then
			cx:toast(
				"info",
				"已自动写入 ~/.zshrc（已备份 ~/.zshrc.bak）",
				"新开一个 Tab 即可在 Tern、Ghostty、tty7、Otty 等所有终端生效"
			)
		elseif notifyAlways then
			cx:toast("info", "~/.zshrc 中已配置好 Command Recall", "无需重复注入，也已将加载命令复制到剪贴板")
		end
	end)
end

tern.on("window_start", function()
	if not tern.fs.exists(ZSHRC_MARK) then
		installZshrc(false)
	end
end)

tern.command({
	id = "install",
	title = "Command Recall: 写入 ~/.zshrc（全终端生效）",
	icon = "sparkle",
	group = "Command Recall",
	run = function(cx)
		cx:copy(SHELL_LINE)
		installZshrc(true)
	end,
})
