--- Provides wrappers around perf to generate our stack trace format.
-- The functions in this module generate stack traces in the format:
-- local traces = {
--     "event 1" = {
--        {
--            count = 42,
--            frames = {
--                 "symbol1 /home/user/Project/src_1.cpp:57",
--                 "symbol2 /home/user/Project/src_2.cpp:32",
--                 "symbol1 /home/user/Project/src_1.cpp:42"
--            }
--        },
--        {
--            count = 99,
--            frames = {
--                 "symbol3 /home/user/Project/src_1.cpp:20",
--                 "0x1231232",
--                 "__foo_bar",
--                 "symbol4 /home/user/Project/src_3.cpp:50"
--            }
--        },
--        -- more traces...
--     },
--
--     "event 2" = {
--         -- ...
--     },
--
--     -- more events...
-- }
-- See :help perfanno-extensions

local M = {}

--- Execute cmd and return the stdout result.
-- @param cmd Command to execute.
-- @param silent Prevent stderr output if true.
-- @return Pair of exit code and stdout as a list of lines
local function get_command_output(cmd)
    local co = coroutine.running()
    local exit_code, stdout

    vim.fn.jobstart(cmd, {
        stdout_buffered = true,
        on_stdout = function(_, data)
            stdout = data
        end,
        on_exit = function(_, code)
            exit_code = code
            coroutine.resume(co)
        end
    })

    coroutine.yield()
    return exit_code, stdout
end

--- Obtains simple flat profile from perf (no callgraph).
-- @param perf_data Location of "perf.data" file.
-- @return Stack traces.
function M.perf_flat(perf_data)
    local esc = vim.fn.fnameescape(perf_data)
    -- TODO: could this break if the user has a perf config?
    -- TODO: what versions of perf does this work for?
    local cmd = "perf report -g none -F sample,srcline,symbol --stdio --full-source-path -i " .. esc
    local exit_code, lines = get_command_output(cmd)

    if exit_code ~= 0 then
        vim.notify("Perf returned non-zero exit code (" .. tostring(exit_code)
            .. ") for command: " .. cmd)
        return {}
    end

    local result = {}
    local current_event

    for _, line in ipairs(lines) do
        local num, event = line:match("# Samples: (%d+%u?)%s+of event '(.*)'")

        if num and event then
            result[event] = {}
            current_event = event
        else
            local count, file, sep, linenr, symbol =
            line:match("^%s*(%d+)%s+(.-)([+:])(%d+)%s+%[%.%]%s*(.*)")
            local success = count and file and sep and linenr and symbol

            if success and tonumber(count) > 0 then
                local trace

                if vim.startswith(file, "/") then
                    trace = {symbol = symbol, file = file, linenr = tonumber(linenr)}
                else
                    trace = {symbol = file .. sep .. linenr}
                end

                table.insert(result[current_event], {count = tonumber(count), frames = {trace}})
            end
        end
    end

    return result
end

--- Obtains actual stack traces from perf via the folded output mode.
-- @param perf_data Location of "perf.data" file.
-- @return Stack traces.
function M.perf_callgraph(perf_data)
    local esc = vim.fn.fnameescape(perf_data)
    -- TODO: could this break if the user has a perf config?
    -- TODO: what versions of perf does this work for?
    local cmd = "perf report -g folded,0,caller,srcline,branch,count"
                .. " --no-children --full-source-path --stdio -i " .. esc
    local exit_code, lines = get_command_output(cmd)

    if exit_code ~= 0 then
        vim.notify("Perf returned non-zero exit code (" .. tostring(exit_code)
            .. ") for command: " .. cmd)
        return {}
    end

    local result = {}
    local current_event

    for _, line in ipairs(lines) do
        local num, event = line:match("# Samples: (%d+[KMB]?)%s+of event '(.*)'")

        if num and event then
            result[event] = {}
            current_event = event
        else
            local count, traceline = line:match("^(%d+) (.*)$")

            if count and traceline and tonumber(count) > 0 then
                local tracedata = {count = tonumber(count), frames = {}}

                for func in traceline:gmatch("[^;]+") do
                    local symbol, file, linenr = func:match("^(.-)%s*(/.*):(%d+)")

                    if file and linenr then
                        if symbol == "" then
                            symbol = nil
                        end

                        local frame = {symbol = symbol, file = file, linenr = tonumber(linenr)}
                        table.insert(tracedata.frames, frame)
                    else  -- address, symbol, etc. (no debug info)
                        table.insert(tracedata.frames, {symbol = func})
                    end
                end

                table.insert(result[current_event], tracedata)
            end
        end
    end

    return result
end

return M
