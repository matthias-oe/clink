--
-- Copyright (c) 2012 Martin Ridgers
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
--

--------------------------------------------------------------------------------
clink.arg = {}

--------------------------------------------------------------------------------
local argument_generators = {}
local node_meta = {}
local node_props = {
    loop        = 0x0001,
    conditional = 0x0002,
}

--------------------------------------------------------------------------------
local traverse
local traverse_loop_shim
local set_prop
local has_prop
local is_node
local create_node
local node_insert
local nodes_from_key_table
local loop_point

--------------------------------------------------------------------------------
function node_meta.__concat(lhs, rhs)
    if not is_node(rhs) then
        error("Right-handside must be clink.arg.node()", 2)
    end

    if is_node(lhs) then
        error("Left-handside must not be a clink.arg.node()", 2)
    end

    if type(lhs) == "table" then
        local outer = create_node()
        nodes_from_key_table(outer, lhs, rhs)
        return outer
    end

    -- Already got a key?
    if rawget(rhs,  "_key") ~= nil then
        local node = create_node()
        node_insert(node, rhs)
        rhs = node
    end

    rawset(rhs, "_key", lhs)
    return rhs
end

--------------------------------------------------------------------------------
function is_node(n)
    return type(n) == "table" and getmetatable(n) == node_meta
end

--------------------------------------------------------------------------------
function set_prop(node, name)
    local bit = node_props[name]
    if bit == nil then
        return
    end

    if not has_prop(node, name) then
        local p = rawget(node, "_props")
        if p == nil then
            p = 0
        end

        p = p + bit
        rawset(node, "_props", p)
    end
end

--------------------------------------------------------------------------------
function has_prop(node, name)
    local bit = node_props[name]
    if bit ~= nil then
        local p = rawget(node, "_props")
        if p ~= nil then
            if (p % (bit * 2)) >= bit then
                return true
            end
        end
    end

    return false
end

--------------------------------------------------------------------------------
function nodes_from_key_table(out, keys, value)
    for _, i in ipairs(keys) do
        if is_node(i) then
            error("Left-handside must not be a clink.arg.node()", 2)
        end

        if type(i) == "table" then
            nodes_from_key_table(out, i, value)
        else
            local inner = create_node()
            rawset(inner, "_key", i)
            node_insert(inner, value)
            table.insert(out, inner)
        end
    end
end

--------------------------------------------------------------------------------
function create_node()
    local node = {}
    setmetatable(node, node_meta)
    node.loop = function(node)
        set_prop(node, "loop")
        return node
    end
    return node
end

--------------------------------------------------------------------------------
function node_insert(node, i)
    if type(i) == "table" and rawget(i, "_key") == nil then
        for _, j in ipairs(i) do
            if type(j) == "table" then
                node_insert(node, j)
            else
                table.insert(node, j)
            end
        end

        return
    end

    table.insert(node, i)
end

--------------------------------------------------------------------------------
function clink.arg.node(...)
    local node = create_node()

    for _, i in ipairs({...}) do
        node_insert(node, i)
    end

    return node
end

--------------------------------------------------------------------------------
function clink.arg.condition(func, ...)
    if type(func) ~= "function" then
        error("First argument to clink.arg.condition() must be a function", 2)
    end

    local node = create_node()
    set_prop(node, "conditional")
    node._key = func 

    for _, i in ipairs({...}) do
        local n = create_node()
        if not is_node(i) and type(i) == "table" then
            node_insert(n, i)
        else
            table.insert(n, i)
        end
        table.insert(node, n)
    end

    return node
end

--------------------------------------------------------------------------------
function clink.arg.print_tree(tree, s)
    if s == nil then s = "+-" end
    if type(tree) == "table" then
        print(s..tostring(rawget(tree, "_key")))

        local p = rawget(tree, "_props")
        if p ~= nil then
            local t = ""
            for i, j in pairs(node_props) do
                if has_prop(tree, i) then
                    t = t..","..i
                end
            end
            print("| "..s.."props: "..t.." "..p)
        end

        for _, i in ipairs(tree) do
            local t = s
            if type(i) == "table" then
                t = "| "..t
            end

            clink.arg.print_tree(i, t)
        end
    else
        print("| "..s..tostring(tree))
    end
end

--------------------------------------------------------------------------------
function clink.arg.register_tree(cmd, generator)
    if not is_node(generator) or has_prop(generator, "conditional") then
        generator = clink.arg.node(generator)
    end

    cmd = cmd:lower()
    local prev = argument_generators[cmd]
    if prev ~= nil then
        node_insert(prev, generator)
    else
        argument_generators[cmd] = generator
    end
end

--------------------------------------------------------------------------------
function clink.arg.stop()
    return clink.arg.node(true)
end

--------------------------------------------------------------------------------
function clink.arg.file_matches()
    return clink.arg.node(false)
end

--------------------------------------------------------------------------------
local function get_matches(part, value, out, text, first, last)
    local t = type(value)

    if t == "string" then
        if clink.is_match(part, value) then
            table.insert(out, value)
        end
    elseif t == "function" then
        local matches = value(part, text, first, last)
        if matches == nil or type(matches) ~= "table" then
            return false
        end

        for _, i in ipairs(matches) do
            table.insert(out, i)
        end
    elseif t == "number" then
        if clink.is_match(part, tostring(value)) then
            table.insert(out, value)
        end
    elseif t == "boolean" then
        return value
    end
end

--------------------------------------------------------------------------------
function traverse(node, parts, text, first, last)
    local part = parts[parts.n]
    local last_part = (parts.n >= #parts)
    parts.n = parts.n + 1

    if part == nil then
        return false
    end

    local full_match = nil
    local partial_matches = {}

    -- If the traversal has reached a condition node, then call the selector
    -- function and traverse down the path selected.
    if has_prop(node, "conditional") then
        local selector = node._key;
        local index = selector(part)
        index = tonumber(index)
        if index < 1 then index = 1 end
        if index > #node then index = #node end

        parts.n = parts.n - 1
        return traverse_loop_shim(node[index], parts, text, first, last)
    end

    for _, i in ipairs(node) do
        if is_node(i) then
            -- Pass through nodes that have no key or are conditional.
            local key = rawget(i, "_key")
            if not key or has_prop(i, "conditional") then
                parts.n = parts.n - 1
                return traverse_loop_shim(i, parts, text, first, last)
            end

            -- Get matches from the node.
            local matches = {}
            get_matches(part, key, matches, text, first, last)

            for _, j in ipairs(matches) do
                -- If this is deemed to be a full match and there's more of the
                -- tree to traverse into, traverse into it.
                if not last_part and clink.is_match(j, part) then
                    return traverse_loop_shim(i, parts, text, first, last)
                end

                table.insert(partial_matches, j)
            end
        else
            local ret = get_matches(part, i, partial_matches, text, first, last)
            if ret ~= nil then
                return ret
            end
        end
    end

    if last_part then
        for _, i in ipairs(partial_matches) do
            clink.add_match(i)
        end
    end

    return (clink.match_count() > 0)
end

--------------------------------------------------------------------------------
function traverse_loop_shim(node, parts, text, first, last)
    local ret = traverse(node, parts, text, first, last)

    if parts.n <= #parts and not ret then
        if has_prop(node, "loop") then
            ret = traverse_loop_shim(node, parts, text, first, last)
        end
    end

    return ret
end

--------------------------------------------------------------------------------
local function argument_match_generator(text, first, last)
    local leading = rl_line_buffer:sub(1, first - 1):lower()

    -- Extract the command.
    local cmd_l, cmd_r
    if leading:find("^%s*\"") then
        -- Command appears to be surround by quotes.
        cmd_l, cmd_r = leading:find("%b\"\"")
        if cmd_l and cmd_r then
            cmd_l = cmd_l + 1
            cmd_r = cmd_r - 1
        end
    else
        -- No quotes so the first, longest, non-whitespace word is extracted.
        cmd_l, cmd_r = leading:find("[^%s]+")
    end

    if not cmd_l or not cmd_r then
        return false
    end

    local regex = "[\\/:]*([^\\/:.]+)(%.*[%l]*)%s*$"
    local _, _, cmd, ext = leading:sub(cmd_l, cmd_r):lower():find(regex)

    -- Check to make sure the extension extracted is in pathext.
    if ext and ext ~= "" then
        if not clink.get_env("pathext"):lower():match(ext.."[;$]", 1, true) then
            return false
        end
    end
    
    -- Find a registered generator.
    local generator = argument_generators[cmd]
    if generator == nil then
        return false
    end

    -- Split the command line into parts.
    local str = rl_line_buffer:sub(cmd_r + 2, last)
    local parts = {}
    for _, sub_str in ipairs(clink.quote_split(str, "\"")) do
        -- Quoted strings still have their quotes. Look for those type of
        -- strings, strip the quotes and add it completely.
        if sub_str:sub(1, 1) == "\"" then
            local l, r = sub_str:find("\"[^\"]+")
            if l then
                local part = sub_str:sub(l + 1, r)
                table.insert(parts, part)
            end
        else
            -- Extract non-whitespace parts.
            for _, r, part in function () return sub_str:find("^%s*([^%s]+)") end do
                table.insert(parts, part)
                sub_str = sub_str:sub(r + 1)
            end
        end
    end

    -- If 'text' is empty then add it as a part as it would have been skipped
    -- by the split loop above
    if text == "" then
        table.insert(parts, text)
    end

    loop_point = nil
    parts.n = 1
    return traverse_loop_shim(generator, parts, text, first, last)
end

--------------------------------------------------------------------------------
clink.register_match_generator(argument_match_generator, 25)

-- vim: expandtab
