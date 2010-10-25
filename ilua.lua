--
-- ilua.lua
--
-- A more friendly Lua interactive prompt
-- doesn't need '='
-- will print out tables recursively
--
-- Steve Donovan, 2007
-- Chris Hixon, 2010
--

-- create another environment, _E, to help prevent coding mistakes
local g = _G
local _E = {}
g.setmetatable(_E, {
    __index = g,
    __newindex = function(t,k,v)
        return g.error("Attempt to assign to global variable '"..k.."'", 2)
    end
})
g.setfenv(1, _E)

-- imported global functions
local format = g.string.format
local sub = g.string.sub
local rep = g.string.rep
local match = g.string.match
local find = g.string.find
local sort = g.table.sort
local append = g.table.insert
local concat = g.table.concat
local write = g.io.write
local read = g.io.read
local flush = g.io.flush
local floor = g.math.floor
local print = g.print
local loadstring = g.loadstring
local type = g.type
local select = g.select
local setfenv = g.setfenv
local tostring = g.tostring
local getmetatable = g.getmetatable
local setmetatable = g.setmetatable
local pairs = g.pairs
local ipairs = g.ipairs
local rawset = g.rawset
local rawget = g.rawget
local require = g.require
local error = g.error
local dofile = g.dofile
local pcall = g.pcall

-- imported global vars
local debug = g.debug
local string = g.string
local os = g.os
local io = g.io
local arg = g.arg
local _VERSION = g._VERSION

-- local vars
local readline, saveline
local identifier = "^[_%a][_%w]*$"

--
-- local functions 
--

-- returns an array that is a slice of an array ary,
-- beginning at index b, ending at index e, with stride of s.
-- b, e, and s are optional and default to:
-- b = begging of array, e = end of array, s = 1
-- can also be used for reverse, like slice(a, #a, 1, -1)
local function slice(ary, b, e, s)
    local n, b, e, s = {}, b or 1, e or #ary, s or 1
    for i = b, e, s do
        n[#n + 1] = ary[i]
    end
    return n
end

-- trim whitespace from both ends of a string
local function trim(str)
    return str:gsub("^%s*(.-)%s*$", "%1")
end

-- function varsub(str, repl)
-- replaces variables in strings like "%20s{foo} %s{bar}" using the table repl
-- to look up replacements. use string:format patterns followed by {variable}
-- and pass the variables in a table like { foo="FOO", bar="BAR" }
-- variable names need to match Lua identifiers ([_%a][_%w]-)
-- missing variables or errors in formatting will result in empty strings
-- being inserted for the corresponding placeholder pattern
local function varsub(str, repl)
    return str:gsub("(%%.-){([_%a][_%w]-)}", function(f,k)
        local r, ok = repl[k]
        ok, r = pcall(format, f, r)
        return ok and r or ""
    end)
end

-- encodes a string as you would write it in code,
-- escaping control and other special characters
local function escape_string(str)
    local es_repl = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
        ["\\"] = "\\\\", ['"'] = '\\"' }
    str = str:gsub('(["\r\n\t\\])', es_repl)
    str = str:gsub("(%c)", function(c)
        return format("\\%d", c:byte())
    end) 
    return format('"%s"', str)
end

--
-- Pretty print / format class
--

local Pretty = {}

Pretty.defaults = {
    items = 100,                  -- max number of items to list in one table
    depth = 7,                    -- max recursion depth when printing tables 
    len = 80,                     -- max line length hint
    delim1 = ", ",                -- item delimiter (single line / compact)
    delim2 = ", ",                -- item delimiter (multiline)
    indent1 = "    ",             -- string repeated each indent level
    indent2 = "    ",             -- string used to indent final level
    indent3 = "    ",             -- string used to indent final level continuation
    empty = "{ }",                -- string used for empty table 
    bl = "{ ",                    -- table braces, single line mode 
    br = " }",
    bl_m = "{\n",                 -- table braces, multiline mode, substitution available:
    br_m = "\n%s{i}}",            -- %s{i}, %s{i1}, %s{i2}, %s{i3} are calulated indents 
    eol = "\n",                   -- end of line (multiline)
    sp = " ",                     -- used other places where spacing might be desired but optional 
    eq = " = ",                   -- table equals string value (printed as key..eq..value)
    key = false,                  -- format of key in field (set to pattern to enable)
    value = false,                -- format of value in field (set to pattern to enable)
    field = "%s",                 -- format of field (which is either "k=v" or "v", with delimiter)
    tstr = true,                  -- use to tostring(table) if table has meta __tostring
    table_info = false,           -- show the table info (usually a hex address)
    function_info = false,        -- show the function info (similar to table_info)
    metatables = false,           -- show metatables when printing tables
    multiline = true,             -- set to false to disable multiline output
    compact = true,               -- will compact leaf tables in multiline mode
}

Pretty.__call = function(self, ...)
    self:print(...)
end

function Pretty:new(params)
    local obj = {}
    params = params or {}
    setmetatable(obj, self)
    self.__index = self
    obj:init(params)
    return obj
end

function Pretty:init(params)
    for k, v in pairs(self.defaults) do
        self[k] = v
    end
    for k, v in pairs(params) do
        self[k] = v
    end
    self.print_handlers = self.print_handlers or {} 
    self:reset_seen()
end


function Pretty:reset_seen()
    self.seen = {}
    setmetatable(self.seen, { __do_not_enter = "<< ! >>" })
end

function Pretty:table2str(tbl, path, depth, multiline)
    -- don't print tables we've seen before
    for p, t in pairs(self.seen) do
        if tbl == t then
            local tinfo = self.table_info and tostring(tbl) or p
            return format("<< %s >>", tinfo)
        end
    end
    -- max_depth
    self.seen[path] = tbl
    if depth >= self.depth then
        return ">>>"
    end
    return self:table_children2str(tbl, path, depth, multiline)
end

-- this sort function compares table keys to allow a sort by key 
-- the order is: numeric keys, string keys, other keys(converted to string) 
function Pretty.key_cmp(a, b)
    local at = type(a)
    local bt = type(b)
    if at == "number" then
        if bt == "number" then
            return a < b
        else
            return true
        end
    elseif at == "string" then
        if bt == "string" then
            return a < b
        elseif bt == "number" then
            return false
        else
            return true
        end
    else
        if bt == "string" or bt == "number" then
            return false
        else
            return tostring(a) < tostring(b)
        end
    end
end

-- returns an iterator to sort by table keys using func
-- as the comparison func. defaults to Pretty.key_cmp
function Pretty.pairs_by_keys(tbl, func)
    func = func or Pretty.key_cmp
    local a = {}
    for n in pairs(tbl) do a[#a + 1] = n end
    sort(a, func)
    local i = 0
    return function ()  -- iterator function
        i = i + 1
        return a[i], tbl[a[i]]
    end
end

function Pretty:table_children2str(tbl, path, depth, multiline)
    local ind1, ind2, ind3  = "", "", ""
    local delim1, delim2 = self.delim1, self.delim2
    local sp, eol, eq = self.sp, self.eol, self.eq
    local bl, br = self.bl, self.br
    local bl_m, br_m = self.bl_m, self.br_m
    local tinfo = self.table_info and tostring(tbl)..sp or ""
    local key_fmt, val_fmt, field = self.key, self.val, self.field
    local compactable, cnt, c = 0, 0, {}
    -- multiline setup
    if multiline then
        ind1 = self.indent1:rep(depth)
        ind2 = ind1 .. self.indent2
        ind3 = ind1 .. self.indent3
        local irepl = { i=ind1, i1=ind1, i2=ind2, i3=ind3 }
        bl_m, br_m = varsub(bl_m, irepl), varsub(br_m, irepl)
    end
    -- metatable
    if self.metatables then
        local mt = getmetatable(tbl)
        if mt then
            append(c, "<metatable>".. self.eq .. self:val2str(mt,
                path .. (path == "" and "" or ".") .. "<metatable>", depth + 1, multiline))
        end
    end

    -- process child nodes, sorted
    local last = nil
    for k, v in Pretty.pairs_by_keys(tbl, self.sort_function) do
        -- item limit
        if self.items and cnt >= self.items then
            append(c, "...")
            compactable = compactable + 1
            break
        end            
        -- determine how to display the key. array part of table will show no keys
        local print_index = true
        local print_brackets = true
        if type(k) == "number" then
            if (last and k > 1 and k == last + 1) or (not last and k == 1) then
                print_index = false
                last = k
            else
                last = false
            end
        else
            last = nil
        end
        local key = tostring(k) 
        if type(k) == "string" then
            if k:match(identifier) then
                print_brackets = false
            else
                key = escape_string(key) 
            end
        end
        if print_brackets then
            key = '[' .. key .. ']'
        end
        -- format val
        local val = self:val2str(v,
            path .. (path == "" and "" or ".") .. key, depth + 1, multiline)
        if not val:match("[\r\n]") then
            compactable = compactable + 1
        end
        if val_fmt then
            val = val_fmt:format(val)
        end
        -- put the pieces together
        local out = ""
        if key_fmt then
            key = key_fmt:format(key)
        end
        if print_index then
            out = key .. eq .. val
        else
            out = val
        end
        append(c, out)
        cnt = cnt + 1
    end

    -- compact
    if multiline and self.compact and #c > 0 and compactable == #c then
        local lines = {}
        local line = "" 
        for i, v in ipairs(c) do
            local f = field:format(v .. (i == cnt and "" or delim1))
            if line == "" then
                line = ind2 .. f
            elseif #line + #f <= self.len then
                line = line .. f 
            else
                append(lines, line)
                line = ind3 .. f
            end
        end
        append(lines, line)
        return tinfo .. bl_m .. concat(lines, eol) .. br_m
    elseif #c == 0 then -- empty
        return tinfo .. self.empty
    elseif multiline then -- multiline
        local c2 = {}
        for i, v in ipairs(c) do
            append(c2, ind2 .. field:format(v .. (i == cnt and "" or delim2)))
        end
        return tinfo .. bl_m .. concat(c2, eol) .. br_m
    else -- single line
        local c2 = {}
        for i, v in ipairs(c) do
            append(c2, field:format(v .. (i == cnt and "" or delim1)))
        end
        return tinfo .. bl .. concat(c2) .. br
    end
end

function Pretty:val2str(val, path, depth, multiline)
    local tp = type(val)
    if self.print_handlers[tp] then
        local s = self.print_handlers[tp](val)
        return s or '?'
    end
    if tp == 'function' then
        return self.function_info and tostring(val) or "function"
    elseif tp == 'table' then
        local mt = getmetatable(val)
        if mt and mt.__do_not_enter then
            return mt.__do_not_enter
        elseif self.tstr and mt and mt.__tostring then
            return tostring(val)
        else
            return self:table2str(val, path, depth, multiline)
        end
    elseif tp == 'string' then
        return escape_string(val)
    elseif tp == 'number' then
        -- we try only to apply floating-point precision for numbers deemed to be floating-point,
        -- unless the 3rd arg to precision() is true.
        if self.num_prec and (self.num_all or floor(val) ~= val) then
            return self.num_prec:format(val)
        else
            return tostring(val)
        end
    else
        return tostring(val)
    end
end

function Pretty:format(...)
    local out, v = "", nil
    -- first try single line output
    self:reset_seen()
    for i = 1, select("#", ...) do
        v = select(i, ...)
        out = format("%s%s ", out, self:val2str(v, "", 0, false))
    end
    -- if it is too long, use multiline mode, if enabled
    if self.multiline and #out > self.len then
        out = ""
        self:reset_seen()
        for i = 1, select("#", ...) do
            v = select(i, ...)
            out = format("%s%s\n", out, self:val2str(v, "", 0, true))
        end
    end
    self:reset_seen()
    return trim(out)
end

function Pretty:print(...)
    local output = self:format(...)
    if self.output_handler then
        self.output_handler(output)
    else
        if output and output ~= "" then
            print(output)
        end
    end
end

--
-- Ilua class
--

local Ilua = {}

-- defaults
Ilua.defaults = {
    -- evaluation related
    prompt = '>> ',         -- normal prompt
    prompt2 = '.. ',        -- prompt during multiple line input
    strict = true,          -- set to true to turn undeclared variable checks
    chunkname = "stdin",    -- name of the evaluated chunk when compiled
    result_var = "_",       -- the variable name that stores the last results
    verbose = false,        -- currently unused

    -- internal, for reference only
    savef = nil,
    line_handler_fn = nil,
    global_handler_fn = nil,
    num_prec = nil,
    num_all = nil,
}

-- things to expose to the enviroment
Ilua.expose = {
    ["Ilua"] = true, ["ilua"] = true, ["Pretty"] = true,
    ["p"] = true, ["ls"] = true, ["dir"] = true,
    ["slice"] = true
}

function Ilua:new(params)
    local obj = {}
    params = params or {}
    setmetatable(obj, self)
    self.__index = self
    obj:init(params)
    return obj
end

function Ilua:init(params)
    for k, v in pairs(self.defaults) do
        self[k] = v
    end
    for k, v in pairs(params) do
        self[k] = v
    end
    local oh = function(str)
        if str and str ~= "" then self:output(str) end
    end
    self.p = Pretty:new { output_handler = oh }
    self.ls = Pretty:new { compact=true, depth=1, output_handler = oh }
    self.dir = Pretty:new { compact=false, depth=1, key="%-20s",
        function_info=true, table_info=true, output_handler = oh }
    -- setup environment
    self.env = setmetatable({}, { __index = g })
    -- init collections
    self.collisions = {}
    self.lib = {}
    self.declared = {}
    -- finish setup
    self:setup_strict()
    -- expose some things to the environment 
    local expose = self.expose 
    self.env.Ilua = expose["Ilua"] and Ilua or nil
    self.env.ilua = expose["ilua"] and self or nil
    self.env.Pretty = expose["Pretty"] and Pretty or nil
    self.env.p = expose["p"] and self.p or nil
    self.env.ls = expose["ls"] and self.ls or nil
    self.env.dir = expose["dir"] and self.dir or nil
    self.env.slice = expose["slice"] and slice or nil
end

-- injects some shortcut variables and functions
function Ilua:helpers()
    local e = self.env
    -- object aliases
    for k, v in pairs { i = self, I = Ilua, P = Pretty, env = e, e = e } do
        e[k] = v
    end
    -- methods turned into functions
    for i, k in ipairs { 'vars', 'v' } do
        e[k] = function(...) return (self[k])(self, ...) end
    end
end
    
function Ilua:output(str)
    if self.savef then
        self.savef:write(str, "\n")
    end
    print(str)
end

function Ilua:precision(len,prec,all)
    if not len then self.num_prec = nil
    else
        self.num_prec = '%'..len..'.'..prec..'f'
    end
    self.num_all = all
end	

function Ilua:line_handler(handler)
    self.line_handler_fn = handler
end

function Ilua:global_handler(handler)
    self.global_handler_fn = handler
end

function Ilua:print_variables()
    for name,v in pairs(self.declared) do
        print(name,type(self.env[name]))
    end
end

Ilua.v = Ilua.print_variables
Ilua.vars = Ilua.print_variables

function Ilua:get_input()
    local lines, i, input, chunk, err = {}, 1
    while true do
        input = readline((i == 1) and self.prompt or self.prompt2)
        if not input then return end
        lines[i] = input
        input = concat(lines, "\n")
        chunk, err = loadstring(format("return(%s)", input), self.chunkname)
        if chunk then return input end
        chunk, err = loadstring(input, self.chunkname)
        if chunk or not err:match("'<eof>'$") then
            return input
        end
        lines[1] = input
        i = 2
    end
end

function Ilua:wrap(...)
    self.p(...)
    self.env[self.result_var] = select(1, ...)
end

function Ilua:eval_lua(line)
    if self.savef then
        self.savef:write(self.prompt, line, '\n')
    end
    -- is the line handler interested?
    if self.line_handler_fn then
        line = self.line_handler_fn(line)
        -- returning nil here means that the handler doesn't want
        -- Lua to see the string
        if not line then return end
    end
    -- is it an expression?
    local chunk, err = loadstring(format("ilua:wrap(%s)", line), self.chunkname)
    if err then -- otherwise, a statement?
        chunk, err = loadstring(format("ilua:wrap((function() %s end)())", line), self.chunkname)
    end
    if err then
        self:output(err)
        return
    end
    -- compiled ok, evaluate the chunk
    setfenv(chunk, self.env)
    local ok, res = pcall(chunk)
    if not ok then
        self:output(res)
    end
end

-- require a lib and inject it into ilua namespace
function Ilua:import(lib, dont_complain)
    local tbl = g.require(lib)
    if type(tbl) ~= 'table' then
        tbl = g[lib]
    end
    self:inject(tbl, dont_complain, lib)
end

-- inject @tbl into the ilua namespace
function Ilua:inject(tbl, dont_complain, lib)
    lib = lib or '<unknown>'
    if type(tbl) == 'table' then
        for k,v in pairs(tbl) do
            local val = rawget(self.env, k)
            -- NB to keep track of collisions!
            if val and k ~= '_M' and k ~= '_NAME' and
                    k ~= '_PACKAGE' and k ~= '_VERSION' then
                self.collisions[k] = {lib, self.lib[k]}
            end
            self.env[k] = v
            self.lib[k] = lib
        end
    end
    if not dont_complain then
        for name, coll in pairs(self.collisions) do
            local lib, oldlib = coll[1], coll[2]
            write('warning: ',lib,'.',name,' overwrites ')
            if oldlib then
                write(oldlib,'.',name,'\n')
            else
                write('global ',name,'\n')
            end
        end
    end
end

--
-- checks uses of undeclared global variables (if strict is on)
-- All global variables must be 'declared' through a regular assignment
-- (even assigning nil will do) in a main chunk before being used
-- anywhere.
function Ilua:setup_strict()
    local mt = getmetatable(self.env)
    if mt == nil then
        mt = {}
        setmetatable(self.env, mt)
    end

    local function what ()
        local d = debug.getinfo(3, "S")
        return d and d.what or "C"
    end

    mt.__newindex = function (t, n, v)
        self.declared[n] = true
        rawset(t, n, v)
    end

    mt.__index = function (t, n)
        if not n then return end
        if not self.declared[n] and what() ~= "C" then
            local lookup = self.global_handler_fn and self.global_handler_fn(n)
            if lookup then return lookup end
            lookup = g[n]
            if lookup then return lookup end
            if self.strict then
                error("variable '"..tostring(n).."' is not declared", 2)
            end
            return nil
        end
        return rawget(t, n)
    end
end

function Ilua:run()
    while true do    
        local input = self:get_input()
        if not input or trim(input) == 'quit' then break end
        self:eval_lua(input)
        saveline(input)
    end

    if self.savef then
        self.savef:close()
    end
end

local function quit(code,msg)
    io.stderr:write(msg,'\n')
    os.exit(code)
end


--- Initial operations which may not succeed!
-- try to bring in any ilua configuration file; don't complain if this is unsuccessful
pcall(function()    
    require 'ilua-defs'
end)

-- Unix readline support, if readline.so is available...
local rl
local err = pcall(function()
    rl = require 'readline'  
    readline = rl.readline
    saveline = rl.add_history
end)
if not rl then
    readline = function(prompt)
        write(prompt)
        return read()
    end
    saveline = function(s) end
end

local ilua = Ilua:new()

-- process command-line parameters
if arg then
    local i = 1

    local function parm_value(opt,parm,def)
        local val = parm:sub(3)
        if #val == 0 then
            i = i + 1
            if i > #arg then 
                if not def then
                    quit(-1,"expecting parameter for option '-"..opt.."'")
                else
                    return def
                end
            end
            val = arg[i]
        end
        return val
    end

    while i <= #arg do
        local v = arg[i]
        local opt = v:sub(1,1)
        if opt == '-' then
            opt = v:sub(2,2)			
            if opt == 'h' then
                quit(0,"ilua (-l lib) (-L lib) (lua files)")            
            elseif opt == 'H' then
                ilua:helpers()
            elseif opt == 'l' then
                require (parm_value(opt,v))
            elseif opt == 'L' then
                local lib = parm_value(opt,v)
                local tbl = require (lib)
                -- we cannot always trust require to return the table!
                if type(tbl) ~= 'table' then
                    tbl = g[lib]
                end
                ilua:inject(tbl,true,lib)
            elseif opt == 't' or opt == 'T' then
                if opt == 'T' then
                    ilua.file = 'ilua_'..os.date ('%y_%m_%d_%H_%M')..'.log'
                else
                    ilua.file = parm_value(opt,v,"ilua.log")
                end
                print('saving transcript "'..ilua.file..'"')
                ilua.savef = io.open(ilua.file,'w')
                ilua.savef:write('! ilua ',concat(arg,' '),'\n')
            elseif opt == 's' then
                ilua.strict = false
            elseif opt == 'v' then
                ilua.verbose = true
            end
        else -- a plain file to be executed immediately
            dofile(v)
        end
        i = i + 1
    end
end

ilua:output('ILUA: ' .. _VERSION)
if jit and jit.version then
    ilua:output(jit.version .. (jit.arch and " ("..jit.arch..")" or ""))
end

-- any inject complaints?
ilua:inject()

ilua:run()
