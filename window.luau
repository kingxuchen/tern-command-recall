-- command-recall, window half: what the memory looks like from the outside.
--
-- The learning and the Tab list need nothing here — the daemon does the first
-- and zsh the second. This half only lets you look the memory in the face (a
-- picker over programs, then over the arguments learned for each) and copies the
-- one shell line that turns the feature on.
--
-- No status-line segment on purpose: Tern gives a chrome formatter 4 ms (40 ms
-- before it pauses the hook), and reading the store there is not worth the risk.
-- Everything here runs inside a command hook instead, where the budget is 50 ms
-- and the user asked for it.

local DATA = tern.plugin.data
local LEARNED = DATA .. "/learned"
local SHELL_LINE = '[ -n "$TERN_RECALL_DIR" ] && . "$TERN_RECALL_DIR/tern-recall.zsh"'

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
		local token, uses, _, age, _, context = string.match(
			line,
			"^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$"
		)
		if token and token ~= "" then
			local days = string.match(age, "^(%d+)") or "0"
			table.insert(rows, {
				token = token,
				context = context or "",
				detail = string.format("用了 %s 次 · %s 天前", uses, days),
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
				table.insert(picks, { label = row.line, detail = row.detail, insert = row.line })
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

tern.command({
	id = "install",
	title = "Command Recall: 复制 shell 绑定",
	icon = "sparkle",
	group = "Command Recall",
	run = function(cx)
		cx:copy(SHELL_LINE)
		cx:toast(
			"info",
			"已复制一行 shell 绑定",
			"贴到 ~/.zshrc 末尾（compinit 之后），新开一个 Tab 生效"
		)
	end,
})
