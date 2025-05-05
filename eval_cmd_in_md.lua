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
-- @field body string:
-- @field rowstart integer:
Result = {}
function Result:new(block, string)
	newobj = {
		body = string,
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

-- @param block Block
-- @return output string
M._evaluate_block = function(block)
	local stdout = ""
	local stderr = ""
	local cmd = "bash -c '" .. block.body .. "'"

	local id = vim.fn.jobstart(cmd, {
		on_stdout = function(_, data)
			if data and #data > 1 then
				stdout = stdout .. table.concat(data, "\n")
			end
		end,
		on_stderr = function(_, data)
			if data and #data > 1 then
				stderr = stderr .. table.concat(data, "\n")
			end
		end,
		stdout_buffered = true,
		stderr_buffered = true,
	})
	_ = vim.fn.jobwait({ id })
	if stdout then
		return stdout
	elseif stderr then
		return stderr
	else
		assert(false, "should be unreachable, cmd=" .. table.concat(block.body, "\n"))
	end
end

-- @param content string
-- @return lines string[]
M._split = function(content)
	local lines = {}
	for s in content:gmatch("[^\r\n]+") do
		table.insert(lines, s)
	end
	return lines
end

-- @param result Result
-- @return lines string[]
M._write = function(result)
	local response = "```output\n" .. result.body .. "```\n"
	local lines = M._split(response)
	for idx, line in ipairs(lines) do
		idx = idx - 1
		vim.api.nvim_buf_set_lines(0, result.rowstart + idx, result.rowstart + idx, false, { line })
	end
end

M.run = function(opts)
	local bufnr = opts.bufnr or 0
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
	local blocks = M._parse(lines)

	local block = M._select_block(blocks)
	if block and block.body ~= nil and #block.body > 0 then
		local res = Result:new(block, M._evaluate_block(block))
		M._write(res)
	end
end

-- M.run({ bufnr = 4 })

return M
