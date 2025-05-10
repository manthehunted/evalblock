local M = {}

-- @class Block
-- @field body string:
-- @field language string:
-- @field rowstart integer:
-- @field rowend integer:
Block = {}
function Block:new()
	newobj = {
		body = "",
		language = "",
		rowstart = -1,
		rowend = -1,
	}
	self.__index = self
	return setmetatable(newobj, self)
end

-- @class Result
-- @field body string[]:
-- @field rowstart integer:
Result = {}
function Result:new(block, result)
	newobj = {
		result = result,
		rowstart = block.rowend,
	}
	self.__index = self
	return setmetatable(newobj, self)
end

-- @param lines string[]
-- @return blocks Block[]
M._parse = function(lines)
	local is_block = false
	local blocks = {}
	local block = Block:new()

	for row, line in ipairs(lines) do
		if (not is_block) and (vim.startswith(line, "```")) then
			block = Block:new()
			block.language = string.sub(line, 4)
			block.rowstart = row
			is_block = true
		elseif vim.startswith(line, "```") then
			block.rowend = row
			assert((block.rowstart ~= -1) and (block.rowend ~= -1))
			-- TODO: clean up body
			-- drop comment
			-- replace \n with <space>
			-- maybe use string.sub
			table.insert(blocks, block)
			block = Block:new()
			is_block = false
		elseif is_block then
			block.body = block.body .. "\n" .. line
		end
	end
	return blocks
end

-- @param blocks Block[]
-- @return block Block
M._select_block = function(blocks)
	local block = Block:new()
	local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
	for _, block in ipairs(blocks) do
		if (block.rowstart <= row) and (row <= block.rowend) then
			return block
		end
	end
	return block
end

-- @param content string
-- @return lines string[]
M._split = function(content, delimiter)
	local lines = {}
	for s in content:gmatch(delimiter) do
		table.insert(lines, s)
	end
	return lines
end

-- @param result Result
-- @return lines string[]
M._write = function(rowstart, body)
	if body ~= nil then
		local response = "```output\n" .. table.concat(body, "\n") .. "\n```\n"
		local lines = M._split(response, "[^\r\n]+")
		for idx, line in ipairs(lines) do
			idx = idx - 1
			vim.api.nvim_buf_set_lines(0, rowstart + idx, rowstart + idx, false, { line })
		end
	end
end

local loop = vim.loop
local api = vim.api
local results_from_call = {}
local store_results = {}

-- @param err string
-- @param data table
local function read(err, data)
	if err then
		-- TODO handle err
		print("ERROR: ", err)
	end
	if data then
		local vals = vim.split(data, "\n")
		for _, d in pairs(vals) do
			if d == "" then
				goto continue
			end
			table.insert(results_from_call, d)
			::continue::
		end
	end
end

-- @param block string
-- @return (cmd, env) (table, table)
function M._split_cmd(cmd_string)
	local lines = string.gmatch(cmd_string, "[\"']?%S+[\"']?")
	local env = {}
	local cmd = {}
	-- FIXME: environment variable
	for v in lines do
		if string.find(v, "=") then
			local e = M._split(v, "[a-zA-Z1-9_]+")
			env[e[1]] = e[2]
		elseif v:sub(1, 1) == "$" then
			v = string.sub(v, 2)
			table.insert(cmd, vim.fn.getenv(v))
			-- print("after: " .. vim.fn.getenv("AWS_PROFILE"))
			-- print("after: " .. uv.os_getenv("AWS_PROFILE"))
		else
			table.insert(cmd, v)
		end
	end
	return cmd, env
end

-- @param block Block
-- @return nil
--     sideeffect on store_results
function M._evaluate_block(block)
	local body = block.body
	local original = {}

	local uv = vim.uv
	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)
	local function show()
		local count = #store_results
		for i = 0, count do
			store_results[i] = nil
		end -- clear the table for the next search

		count = #results_from_call
		if count > 0 then
			for _, v in pairs(results_from_call) do
				table.insert(store_results, v)
			end

			for i = 0, count do
				results_from_call[i] = nil
			end -- clear the table for the next search
		end
	end

	cmd, env = M._split_cmd(body)
	for k, v in pairs(env) do
		original[k] = vim.fn.getenv(k)
		uv.os_setenv(k, v)
	end
	-- print(cmd[1])
	-- print(unpack(cmd, 2))

	handle = uv.spawn(
		cmd[1],
		{
			args = { unpack(cmd, 2) },
			stdio = { nil, stdout, stderr },
		},
		vim.schedule_wrap(function()
			stdout:read_stop()
			stderr:read_stop()
			stdout:close()
			stderr:close()
			handle:close()
			show()
		end)
	)
	uv.read_start(stdout, read)
	uv.read_start(stderr, read)
	for k, v in pairs(original) do
		uv.os_setenv(k, tostring(v))
	end
end

M.run = function(opts)
	local bufnr = opts.bufnr or 0
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
	local blocks = M._parse(lines)

	local block = M._select_block(blocks)
	if block and block.body ~= nil and #block.body > 0 then
		M._evaluate_block(block)
		M._write(block.rowend, store_results)
	end
end

-- M.run({ bufnr = 4 })

return M
