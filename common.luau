-- command-recall: shared model for both halves of the plugin.
--
-- The store is a two-level table: store[program][context .. "\1" .. token] =
-- { n = uses, f = failing uses, t = last used (wall seconds) }.
-- That is all the memory the feature needs: everything the shell reads is
-- derived from it, so a restart only replays `state.json`.

local common = {}

-- Half-life of the recency weight, in days. A token used once a day for a week
-- still outranks one last used a month ago.
common.RECENCY_DAYS = 14

-- How deep into a command line the context reaches, and how many rows one
-- program may publish to the shell.
common.CONTEXT_DEPTH = 2
common.MAX_ROWS_PER_PROGRAM = 200
common.MAX_PROGRAMS = 400

-- Words that run another program: the program is the next word.
common.WRAPPERS = {
	sudo = true,
	env = true,
	time = true,
	nice = true,
	nohup = true,
	command = true,
	exec = true,
	caffeinate = true,
	doas = true,
}

-- Separators that end one command and start the next.
local SPLITS = { ["|"] = true, [";"] = true, ["\n"] = true }
local PAIRS = { ["&&"] = true, ["||"] = true }

-- Shell syntax that ends up at the start of a line in a history file (a loop or
-- an `if' typed over several lines): not a program, so nothing to learn from it.
-- Bracketed keys because most of these are reserved words in Luau.
common.KEYWORDS = {
	["if"] = true,
	["then"] = true,
	["else"] = true,
	["elif"] = true,
	["fi"] = true,
	["for"] = true,
	["while"] = true,
	["until"] = true,
	["do"] = true,
	["done"] = true,
	["case"] = true,
	["esac"] = true,
	["function"] = true,
	["return"] = true,
	["local"] = true,
	["typeset"] = true,
	["declare"] = true,
	["shift"] = true,
	["break"] = true,
	["continue"] = true,
}

-- Split a command line into the commands it runs, ignoring anything inside
-- quotes or a `$( )` substitution.
function common.segments(line)
	local out = {}
	local buf = ""
	local quote = nil
	local i = 1
	local sub = string.sub
	while i <= #line do
		local c = sub(line, i, i)
		local next2 = sub(line, i, i + 1)
		if quote then
			buf ..= c
			if c == quote then
				quote = nil
			end
		elseif c == "'" or c == '"' or c == "`" then
			quote = c
			buf ..= c
		elseif c == "$" and next2 == "$(" then
			-- Copy the substitution whole; it is data, not a new command.
			local depth = 0
			while i <= #line do
				local d = sub(line, i, i)
				if d == "(" then
					depth += 1
				elseif d == ")" then
					depth -= 1
					if depth == 0 then
						buf ..= sub(line, i, i)
						i += 1
						break
					end
				end
				buf ..= d
				i += 1
			end
			continue
		elseif PAIRS[next2] then
			table.insert(out, buf)
			buf = ""
			i += 2
			continue
		elseif SPLITS[c] then
			table.insert(out, buf)
			buf = ""
		else
			buf ..= c
		end
		i += 1
	end
	table.insert(out, buf)
	return out
end

-- Whitespace tokens of one segment, keeping quoted words together.
function common.tokenize(seg)
	local out = {}
	local buf = ""
	local quote = nil
	local has = false
	for i = 1, #seg do
		local c = string.sub(seg, i, i)
		if quote then
			if c == quote then
				quote = nil
			else
				buf ..= c
			end
		elseif c == "'" or c == '"' or c == "`" then
			quote = c
			has = true
		elseif c == " " or c == "\t" then
			if buf ~= "" then
				table.insert(out, buf)
				buf = ""
			end
		else
			buf ..= c
		end
	end
	if buf ~= "" then
		table.insert(out, buf)
	end
	return out
end

-- Where the program sits in a token list: after wrappers and `VAR=value`.
function common.program_index(tokens)
	local i = 1
	while i <= #tokens do
		local t = tokens[i]
		if common.WRAPPERS[t] or string.match(t, "^%a[%w_]*=") then
			i += 1
		else
			return i
		end
	end
	return nil
end

-- The program a token list runs, after wrappers and `VAR=value` prefixes.
function common.program(tokens)
	local at = common.program_index(tokens)
	-- `/usr/bin/git` and `git` are the same program.
	return at and (string.gsub(tokens[at], "^.*/", "")) or nil
end

-- Is a token worth remembering? Options and subcommands yes; paths, globs,
-- expansions and anything the user typed as data, no.
function common.interesting(tok)
	-- Long flags are normal: `--dangerously-skip-permissions' is 29 characters,
	-- so the cap only keeps a pasted blob from becoming a row. `:` and `@` are
	-- allowed because scripts and filters are named that way (`test:web`,
	-- `@isee/shared` is a path and still rejected by the `/` below).
	if #tok == 0 or #tok > 64 then
		return false
	end
	if string.find(tok, "[/%%*$~'\"`()<>|&;{}%[%!#=\\\\]") then
		return false
	end
	if string.sub(tok, 1, 1) == "-" then
		return true
	end
	return string.match(tok, "^[%w%+_,%.%-:@]+$") ~= nil
end

-- What one finished command teaches: a list of { program, context, token }.
function common.lessons(line)
	local out = {}
	for _, seg in common.segments(line) do
		local tokens = common.tokenize(seg)
		local at = common.program_index(tokens)
		local prog = at and string.gsub(tokens[at], "^.*/", "") or nil
		-- `if', `for', `done' at the start of a history line is syntax, not a
		-- program: nothing a completion could ever offer.
		if prog and not common.KEYWORDS[prog] then
			local context = {}
			local after_flag = false
			for i = at + 1, #tokens do
				local tok = tokens[i]
				local learnable = common.interesting(tok)
				-- A word right after an option is that option's value, not a
				-- subcommand: `agy --model claude-opus' must not teach
				-- `claude-opus' to the empty context, or `agy <Tab>' would offer
				-- it as if it were a subcommand.
				local is_value = after_flag and #context == 0
				if learnable and not is_value then
					table.insert(out, {
						program = prog,
						context = table.concat(context, " "),
						token = tok,
					})
				end
				-- Only the subcommand path builds context: flags and data don't.
				if
					learnable
					and not is_value
					and string.sub(tok, 1, 1) ~= "-"
					and #context < common.CONTEXT_DEPTH
				then
					table.insert(context, tok)
				end
				after_flag = learnable and string.sub(tok, 1, 1) == "-"
			end
		end
	end
	return out
end

-- A program name the store may hold: a plain word, no path, no traversal. The
-- host publishes one file per program, so this also keeps a token from turning
-- into a path outside the learned directory.
function common.is_name(program)
	if #program == 0 or #program > 40 then
		return false
	end
	if string.find(program, "..", 1, true) then
		return false
	end
	return string.match(program, "^[%w%._%+-]+$") ~= nil
end

local function entry(store, program, context, token)
	local byProgram = store[program]
	if not byProgram then
		byProgram = {}
		store[program] = byProgram
	end
	local key = context .. "\1" .. token
	local e = byProgram[key]
	if not e then
		e = { n = 0, f = 0, t = 0, context = context, token = token }
		byProgram[key] = e
	end
	return e
end

-- Fold one finished command into the store. `status` is the reward: a failing
-- run is remembered as a minus, so a broken option sinks without being deleted.
-- `penalty_only` adds just that minus, for a command already counted when it
-- started (`command_started`).
function common.learn(store, line, status, now, penalty_only)
	local changed = false
	for _, l in common.lessons(line) do
		if common.is_name(l.program) then
			local e = entry(store, l.program, l.context, l.token)
			if penalty_only then
				if status ~= 0 then
					e.f += 1
					changed = true
				end
			else
				e.n += 1
				if status ~= 0 then
					e.f += 1
				end
				e.t = now
				changed = true
			end
		end
	end
	return changed
end

-- Ranking: sqrt-damped frequency (iTerm2) over a recency half-life (atuin),
-- times a failure penalty (mcfly's exit-status feature).
function common.score(e, now)
	local days = math.max(0, (now - e.t) / 86400)
	local recency = 1 / (1 + days / common.RECENCY_DAYS)
	local success = 1 - 0.6 * (e.f / math.max(1, e.n))
	return math.sqrt(e.n) * recency * success
end

local function sortedEntries(list, now)
	local out = {}
	for _, e in list do
		table.insert(out, e)
	end
	table.sort(out, function(a, b)
		local sa, sb = common.score(a, now), common.score(b, now)
		if sa == sb then
			return a.token < b.token
		end
		return sa > sb
	end)
	return out
end

-- Drop the weakest entries so the store stays inside the shell's reading budget.
-- Returns the programs it dropped entirely: their `learned/<program>' files must
-- go too, or the shell keeps offering a memory that no longer exists.
function common.prune(store, now)
	local programs = {}
	for program, byKey in store do
		table.insert(programs, { program = program, list = byKey, best = 0 })
	end
	table.sort(programs, function(a, b)
		for _, e in a.list do
			local s = common.score(e, now)
			if s > a.best then
				a.best = s
			end
		end
		for _, e in b.list do
			local s = common.score(e, now)
			if s > b.best then
				b.best = s
			end
		end
		return a.best > b.best
	end)
	local dropped = {}
	for i = common.MAX_PROGRAMS + 1, #programs do
		dropped[programs[i].program] = true
		store[programs[i].program] = nil
	end
	for _, p in programs do
		local keep = sortedEntries(p.list, now)
		for i = common.MAX_ROWS_PER_PROGRAM + 1, #keep do
			p.list[keep[i].context .. "\1" .. keep[i].token] = nil
		end
	end
	return dropped
end

-- The shell-facing rows: `token \t uses \t fails \t age_days \t score \t context`,
-- best first. The context goes last on purpose: the first argument position has
-- no context, and `read' with a tab IFS drops a leading empty field, so an empty
-- column may only ever sit at the end of the line. The zsh side filters on the
-- context and lets zsh filter on the word being completed; this is a plain dump
-- of the ranking.
function common.renderProgram(program, byKey, now)
	local text = ""
	for _, e in sortedEntries(byKey, now) do
		local days = math.max(0, (now - e.t) / 86400)
		text ..= string.format(
			"%s\t%d\t%d\t%.1f\t%.4f\t%s\n",
			e.token,
			e.n,
			e.f,
			days,
			common.score(e, now),
			e.context
		)
	end
	return text
end

function common.render(store, now)
	local out = {}
	for program, byKey in store do
		out[program] = common.renderProgram(program, byKey, now)
	end
	return out
end

-- Plain tables both ways, for `state.json`.
function common.encode(store)
	local out = {}
	for program, byKey in store do
		local rows = {}
		for _, e in byKey do
			table.insert(rows, { c = e.context, t = e.token, n = e.n, f = e.f, u = e.t })
		end
		out[program] = rows
	end
	return out
end

function common.decode(rows)
	local store = {}
	for program, list in rows do
		local byKey = {}
		for _, r in list do
			byKey[r.c .. "\1" .. r.t] = { n = r.n, f = r.f, t = r.u, context = r.c, token = r.t }
		end
		store[program] = byKey
	end
	return store
end

function common.counts(store)
	local programs, tokens, uses = 0, 0, 0
	for _, byKey in store do
		programs += 1
		for _, e in byKey do
			tokens += 1
			uses += e.n
		end
	end
	return { programs = programs, tokens = tokens, uses = uses }
end

return common
