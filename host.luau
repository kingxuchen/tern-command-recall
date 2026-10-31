-- command-recall, host half (the session daemon).
--
-- Learns from every command the shells report (`command_finished` carries the
-- line as typed, its exit status and how long it ran), keeps a ranked store,
-- and publishes it as plain text files the shell's completion reads. Nothing
-- here touches the UI: the daemon sees every pane of every window, and stays
-- alive when the last window closes, so this is the only place the memory
-- should live.

local common = require("./common")

local DATA = tern.plugin.data
local LEARNED = DATA .. "/learned"
local STATE = DATA .. "/state.json"
local SUMMARY = DATA .. "/summary.json"
local SHELL_SRC = tern.plugin.dir .. "/shell/tern-recall.zsh"
local SHELL_DST = DATA .. "/tern-recall.zsh"
local SELFTEST = DATA .. "/selftest.json"
local HISTORY_MARK = DATA .. "/history-imported"

-- How long after the last finished command the files are rewritten.
local FLUSH_MS = 1200

-- One-time import of the shell's own history, so day one is not empty. The
-- zsh extended format is `: <start>:<elapsed>;<command>`; a line without a
-- stamp is kept but dated a month back, so real use outranks it at once.
local HISTORY_MAX_BYTES = 8000000
local HISTORY_MAX_COMMANDS = 8000
local HISTORY_UNDATED_AGE = 30 * 86400

local store = {}
local dirtyPrograms = {}
local dirtyState = false
local flushHandle = nil

local function now()
	return os.time()
end

-- ---------------------------------------------------------------- publishing

local function writeShell()
	if not tern.fs.exists(SHELL_SRC) then
		tern.log.warn("command-recall: missing", SHELL_SRC)
		return
	end
	local src = tern.fs.read(SHELL_SRC, 200000)
	local keep = tern.fs.exists(SHELL_DST) and tern.fs.read(SHELL_DST, 200000) or nil
	if keep ~= src then
		tern.fs.write(SHELL_DST, src)
		tern.log.info("command-recall: published", SHELL_DST)
	end
end

local function flush()
	if flushHandle then
		flushHandle:cancel()
		flushHandle = nil
	end
	local at = now()
	for program in common.prune(store, at) do
		dirtyPrograms[program] = true
	end
	if dirtyState then
		tern.fs.write(STATE, tern.json.encode({ saved = at, rows = common.encode(store) }))
		local counts = common.counts(store)
		tern.fs.write(
			SUMMARY,
			tern.json.encode({ saved = at, programs = counts.programs, tokens = counts.tokens, uses = counts.uses })
		)
	end
	-- The directory can be gone since load(): a cleaned cache dir, or a moved data
	-- dir. Writing must not depend on load's mkdir.
	tern.fs.mkdir(LEARNED)
	for program in dirtyPrograms do
		local path = LEARNED .. "/" .. program
		if store[program] and common.is_name(program) then
			tern.fs.write(path, common.renderProgram(program, store[program], at))
		elseif tern.fs.exists(path) then
			tern.fs.remove(path)
		end
	end
	dirtyState = false
	dirtyPrograms = {}
end

local function schedule()
	if flushHandle then
		return
	end
	flushHandle = tern.timer(FLUSH_MS, function()
		flushHandle = nil
		flush()
	end)
end

-- ------------------------------------------------------------------ learning

local function learn(line, status, penalty_only)
	local at = now()
	local changed = false
	for _, lesson in common.lessons(line) do
		if common.is_name(lesson.program) then
			dirtyPrograms[lesson.program] = true
			changed = true
		end
	end
	if changed then
		common.learn(store, line, status, at, penalty_only)
		dirtyState = true
		schedule()
	end
end

local function load()
	tern.fs.mkdir(LEARNED)
	writeShell()
	if tern.fs.exists(STATE) then
		local ok, doc = pcall(tern.json.decode, tern.fs.read(STATE, 4000000))
		if ok and doc and doc.rows then
			store = common.decode(doc.rows)
		else
			tern.log.warn("command-recall: state unreadable, starting fresh")
		end
	end
end

-- ------------------------------------------------------------------ self-test
-- Runs on every load, in the real VM, and records what the model learned from a
-- fixed transcript. A regression shows up as a changed file, not a broken UI.

local TRANSCRIPT = {
	{ "git status --short", 0 },
	{ "git status --short", 0 },
	{ "git status", 0 },
	{ "git commit -m fix", 0 },
	{ "git commit -am fix", 0 },
	{ "git push origin HEAD", 0 },
	{ "git push --force-with-lease", 2 },
	{ "sudo git push origin main", 0 },
	{ "pnpm test:web --reporter dot", 0 },
	{ "pnpm vitest run src/foo.test.ts", 0 },
	{ "pnpm install --frozen-lockfile", 0 },
	{ 'echo "hello | world" && ls -la /tmp', 0 },
	{ "docker compose -f docker/dev.yml up -d", 0 },
	{ "ls -la $HOME/Library", 0 },
	{ "cat ./README.md", 0 },
	-- The option that made this plugin's length cap 64 instead of 24.
	{ "agy --dangerously-skip-permissions", 0 },
	{ "agy --dangerously-skip-permissions", 0 },
	{ "agy --model claude-opus", 0 },
}

local function selftest()
	-- A store of its own: the transcript must never reach the user's memory.
	local learned = {}
	local seen = {}
	local listed = {}
	for _, step in TRANSCRIPT do
		local line, status = step[1], step[2]
		for _, lesson in common.lessons(line) do
			local key = lesson.program .. "\1" .. lesson.context .. "\1" .. lesson.token
			if not seen[key] then
				seen[key] = true
				table.insert(listed, {
					program = lesson.program,
					context = lesson.context,
					token = lesson.token,
					status = status,
				})
			end
		end
		common.learn(learned, line, status, now())
	end
	local at = now()
	local function scored(program, key)
		local byKey = learned[program]
		local e = byKey and byKey[key]
		if not e then
			return -1
		end
		return common.score(e, at)
	end
	local out = { at = at, lessons = listed, ranking = {}, checks = {} }
	for _, program in { "git", "pnpm", "docker", "ls", "cat", "echo", "sudo", "agy" } do
		local rows = {}
		local byKey = learned[program]
		if byKey then
			for _, e in byKey do
				table.insert(rows, {
					context = e.context,
					token = e.token,
					uses = e.n,
					fails = e.f,
					score = tonumber(string.format("%.4f", common.score(e, at))),
				})
			end
		end
		out.ranking[program] = rows
	end
	out.checks = {
		learned_subcommand = scored("git", "\1status") > 0,
		learned_argument_context = scored("git", "push\1origin") > 0,
		failure_penalised = scored("git", "push\1--force-with-lease") < scored("git", "push\1origin"),
		wrapper_is_not_a_program = learned["sudo"] == nil,
		skips_paths = learned["cat"] == nil,
		skips_quoted_data = learned["echo"] == nil,
		splits_pipeline = scored("ls", "\1-la") > 0,
		context_ignores_data = scored("docker", "compose\1up") > 0,
		keeps_long_flags = scored("agy", "\1--dangerously-skip-permissions") > 0,
		flag_value_is_not_a_subcommand = scored("agy", "\1claude-opus") < 0,
		ranks_by_use = scored("agy", "\1--dangerously-skip-permissions")
			> scored("agy", "\1--model"),
	}
	tern.fs.write(SELFTEST, tern.json.encode(out, true))
end

-- ------------------------------------------------------------- history import
-- Tern only reports commands it sees, so a fresh install would know nothing and
-- `agy <Tab>' would stay empty until the flag is used again. Read the shell's own
-- history once instead, with each command's real timestamp, so recency means
-- something and the ranking still puts what you actually use on top.

local function importHistory()
	if tern.fs.exists(HISTORY_MARK) then
		return 0
	end
	local home = tern.getenv("HOME")
	if not home then
		return 0
	end
	local path = home .. "/.zsh_history"
	if not tern.fs.exists(path) then
		tern.fs.write(HISTORY_MARK, "no .zsh_history")
		return 0
	end
	local text = tern.fs.read(path, HISTORY_MAX_BYTES)
	local at = now()
	local count = 0
	for line in string.gmatch(text, "([^\n]+)") do
		if count >= HISTORY_MAX_COMMANDS then
			break
		end
		local ts, cmd = string.match(line, "^: (%d+):%d+;(.*)$")
		if not ts then
			cmd = line
		end
		-- A command split over lines continues with a backslash; the tail is
		-- uninteresting on its own and would only teach noise. A line with the
		-- 0x83 meta byte is zsh marking an incomplete command on disk, and lines
		-- that mention this plugin's own id are the harness that built it.
		local usable = cmd ~= ""
			and string.sub(cmd, -1) ~= "\\"
			and #cmd <= 2000
			and not string.find(cmd, "\131", 1, true)
			and not string.find(cmd, "tern-recall", 1, true)
			and not string.find(cmd, "recall-probe", 1, true)
		if usable then
			local when = ts and tonumber(ts) or (at - HISTORY_UNDATED_AGE)
			if common.learn(store, cmd, 0, when) then
				count += 1
			end
		end
	end
	for program in store do
		dirtyPrograms[program] = true
	end
	dirtyState = true
	flush()
	tern.fs.write(HISTORY_MARK, string.format("%d commands", count))
	tern.log.info("command-recall: imported", count, "commands from", path)
	return count
end

-- --------------------------------------------------------------------- wiring

tern.on("spawn", function(spec)
	-- The shell side reads $TERN_RECALL_DIR/learned/<program>; pointing it here
	-- means one line in .zshrc works for a linked dev copy too.
	spec.env.TERN_RECALL_DIR = DATA
	return spec
end)

-- A command is remembered when it starts, not when it ends: an interactive one
-- (`cursor-agent --yolo', `opencode', a long `pnpm build') can run for minutes
-- or hours, and a user pressing Tab right after starting it must already see the
-- option. The finish only adds the failure mark.
local started = {}

tern.on("command_started", function(ev)
	if ev.line and ev.line ~= "" then
		started[ev.pane] = ev.line
		learn(ev.line, 0)
	end
end)

tern.on("command_finished", function(ev)
	local line = ev.line
	if not line or line == "" then
		return
	end
	if started[ev.pane] == line then
		started[ev.pane] = nil
		if (ev.status or 0) ~= 0 then
			learn(line, ev.status, true)
		end
	else
		-- A shell that reported only the end, or a finish whose start this VM
		-- never saw: count it now.
		learn(line, ev.status or 0)
	end
end)

load()
importHistory()
selftest()
