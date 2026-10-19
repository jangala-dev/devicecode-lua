local lfs = require 'lfs'

local M = {}

local function long_bracket_open(line, pos)
	if line:sub(pos, pos) ~= '[' then return nil end

	local cursor = pos + 1
	while line:sub(cursor, cursor) == '=' do cursor = cursor + 1 end
	if line:sub(cursor, cursor) ~= '[' then return nil end

	return line:sub(pos + 1, cursor - 1), cursor + 1
end

local function scan_short_string(line, pos, quote, state)
	local cursor = pos
	while cursor <= #line do
		local ch = line:sub(cursor, cursor)
		if ch == '\\' then
			if cursor == #line then
				state.kind = 'short'
				state.quote = quote
				return #line + 1
			end
			cursor = cursor + 2
		elseif ch == quote then
			state.kind = nil
			state.quote = nil
			return cursor + 1
		else
			cursor = cursor + 1
		end
	end

	return cursor
end

local function scan_line(line, state)
	local cursor = 1
	while cursor <= #line do
		if state.kind == 'long' then
			local close = ']' .. state.equals .. ']'
			local close_at = line:find(close, cursor, true)
			if not close_at then return end

			state.kind = nil
			state.equals = nil
			cursor = close_at + #close
		elseif state.kind == 'short' then
			cursor = scan_short_string(line, cursor, state.quote, state)
		else
			local ch = line:sub(cursor, cursor)
			local next_ch = line:sub(cursor + 1, cursor + 1)
			if ch == '-' and next_ch == '-' then
				local equals, after_open = long_bracket_open(line, cursor + 2)
				if not equals then return end

				state.kind = 'long'
				state.equals = equals
				cursor = after_open
			elseif ch == '[' then
				local equals, after_open = long_bracket_open(line, cursor)
				if equals then
					state.kind = 'long'
					state.equals = equals
					cursor = after_open
				else
					cursor = cursor + 1
				end
			elseif ch == "'" or ch == '"' then
				state.kind = 'short'
				state.quote = ch
				cursor = scan_short_string(line, cursor + 1, ch, state)
			else
				cursor = cursor + 1
			end
		end
	end
end

local function split_lines(content)
	local lines = {}
	local cursor = 1

	while cursor <= #content do
		local newline_at = content:find('\n', cursor, true)
		if newline_at then
			lines[#lines + 1] = {
				text = content:sub(cursor, newline_at - 1),
				eol = '\n',
			}
			cursor = newline_at + 1
		else
			lines[#lines + 1] = {
				text = content:sub(cursor),
				eol = '',
			}
			break
		end
	end

	return lines
end

local function invalid_prefix(line)
	if line:match('^[ \t]*$') then return nil end

	local prefix = line:match('^[ \t]+')
	if not prefix then return nil end
	if prefix:sub(1, 1) == ' ' or prefix:find(' \t', 1, true) then
		return prefix
	end

	return nil
end

local function analyse(content)
	local state = {}
	local rows = split_lines(content)

	for line_number = 1, #rows do
		local row = rows[line_number]
		local protected_at_start = state.kind ~= nil
		if not protected_at_start then
			row.invalid_prefix = invalid_prefix(row.text)
		end
		scan_line(row.text, state)
	end

	return rows
end

function M.check_content(content)
	local violations = {}
	local rows = analyse(content)

	for line_number = 1, #rows do
		if rows[line_number].invalid_prefix then
			violations[#violations + 1] = {
				line = line_number,
				prefix = rows[line_number].invalid_prefix,
			}
		end
	end

	return violations
end

local function read_file(path)
	local file, open_err = io.open(path, 'rb')
	if not file then return nil, open_err end
	local content = file:read('*a')
	file:close()
	return content
end

local function collect_path(path, files)
	local attrs, attr_err = lfs.attributes(path)
	if not attrs then return nil, attr_err end

	if attrs.mode == 'file' then
		if path:match('%.lua$') then files[#files + 1] = path end
		return true
	end
	if attrs.mode ~= 'directory' then return true end

	local entries = {}
	for entry in lfs.dir(path) do
		if entry ~= '.' and entry ~= '..' then entries[#entries + 1] = entry end
	end
	table.sort(entries)

	for i = 1, #entries do
		local ok, walk_err = collect_path(path .. '/' .. entries[i], files)
		if not ok then return nil, walk_err end
	end
	return true
end

function M.collect_files(paths)
	local files = {}
	for i = 1, #paths do
		local ok, collect_err = collect_path(paths[i], files)
		if not ok then return nil, ('%s: %s'):format(paths[i], tostring(collect_err)) end
	end
	table.sort(files)
	return files
end

function M.check_paths(paths, output)
	output = output or io.stdout
	local files, collect_err = M.collect_files(paths)
	if not files then return nil, collect_err end

	local violation_count = 0
	for i = 1, #files do
		local content, read_err = read_file(files[i])
		if not content then return nil, ('%s: %s'):format(files[i], tostring(read_err)) end

		local violations = M.check_content(content)
		for j = 1, #violations do
			violation_count = violation_count + 1
			output:write(('%s:%d: Lua indentation must start with tabs; spaces are allowed only for alignment after tabs\n')
				:format(files[i], violations[j].line))
		end
	end

	return violation_count, #files
end

return M
