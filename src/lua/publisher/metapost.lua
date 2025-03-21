--
--  metapost.lua
--  speedata publisher
--
--  For a list of authors see `git blame'
--  See file COPYING in the root directory for license info.


module(...,package.seeall)


-- helper

function extra_page_parameter(current_page)
    return {
        ["page.margin.top"]    = sp_to_bp(current_page.grid.margin_top),
        ["page.margin.left"]   = sp_to_bp(current_page.grid.margin_left),
        ["page.margin.right"]  = sp_to_bp(current_page.grid.margin_right),
        ["page.margin.bottom"] = sp_to_bp(current_page.grid.margin_bottom),
        ["page.width"]         = sp_to_bp(current_page.width),
        ["page.height"]        = sp_to_bp(current_page.height),
        ["page.trim"]          = sp_to_bp(current_page.grid.trim),
    }
end


-- PostScript operators and their pdf equivalent and #arguments. These are just the simple cases.
local pdfoperators = {
    closepath = {"h",0},
    curveto = {"c",6},
    clip = {"W n",0},
    fill = {"f",0},
    gsave = {"q",0},
    grestore = {"Q",0},
    lineto = {"l",2},
    moveto = {"m",2},
    setlinejoin = {"j",1},
    setlinecap = {"J",1},
    setlinewidth = {"w",1},
    stroke = {"S",0},
    setmiterlimit = {"M",1},
}

local ignored_pdfoperators = {
    showpage = true,
    newpath = true,
}

local function getboundingbox(pdfimage,txt)
    local a,b,c,d = string.match(txt,"^%%%%HiResBoundingBox: (%S+) (%S+) (%S+) (%S+)")
    pdfimage.highresbb = { tonumber(a), tonumber(b), tonumber(c), tonumber(d)}
end

-- PostScript is a stack based, full featured programming langauge whereas pdf is just a simple
-- text format. Therefore an interpretation of the input would be necessary, but I try
-- with a simple analysis for now.
local function getpostscript(stack,pdfimage,txt)
    local push = function(elt)
        -- w("PUSH %s",tostring(elt))
        table.insert(stack,elt)
    end

    local pop = function()
        local elt = table.remove(stack)
        -- w("POP %s",tostring(elt))
        return elt
    end

    local tbl = string.explode(txt)
    for i = 1, #tbl do
        local thistoken = tbl[i]
        if tonumber(thistoken) then
            push(tonumber(thistoken))
        elseif thistoken == "[]" then
            push({})
        elseif string.match(thistoken,"^%[") then
            push("[")
            push(string.sub(thistoken,2))
        elseif string.match(thistoken,"%]$") then
            push(string.sub(thistoken,1,-2))
            local arystart = #stack
            for s = #stack,1,-1 do
                if stack[s] == "[" then
                    arystart = s
                end
            end
            local ary = {}
            table.remove(stack,arystart)
            for s = arystart,#stack do
                table.insert(ary,stack[s])
            end
            for s = #stack,arystart,-1 do
                pop()
            end
            push(ary)
        elseif thistoken == "concat" then
            local ary = pop()
            for s = 1,#ary do
                table.insert(pdfimage,ary[s])
            end
            table.insert(pdfimage,"cm")
        elseif thistoken == "dtransform" then
            -- get two, push two
        elseif thistoken == "truncate" then
            -- truncate prev token
        elseif thistoken == "idtransform" then
            -- get two, push two
        elseif thistoken == "setdash" then
            -- TODO: correct
            local a = pop()
            local b = pop()
            table.insert(pdfimage, "[" .. table.concat(b," ") .. "]")
            table.insert(pdfimage,a)
            table.insert(pdfimage,"d")
        elseif thistoken == "setrgbcolor" then
            local b, g, r = pop(),pop(),pop()
            table.insert(pdfimage, r)
            table.insert(pdfimage, g)
            table.insert(pdfimage, b)
            table.insert(pdfimage, "rg")
            table.insert(pdfimage, r)
            table.insert(pdfimage, g)
            table.insert(pdfimage, b)
            table.insert(pdfimage, "RG")
        elseif thistoken == "setcmykcolor" then
            local k, y, m, c = pop(),pop(),pop(),pop()
            table.insert(pdfimage, c)
            table.insert(pdfimage, m)
            table.insert(pdfimage, y)
            table.insert(pdfimage, k)
            table.insert(pdfimage, "K")
            table.insert(pdfimage, c)
            table.insert(pdfimage, m)
            table.insert(pdfimage, y)
            table.insert(pdfimage, k)
            table.insert(pdfimage, "k")
        elseif thistoken == "exch" then
            local a,b = pop(), pop()
            table.insert(pdfimage, a)
            table.insert(pdfimage, b)
        elseif thistoken == "pop" then
            table.remove(stack)
        elseif thistoken == "rlineto" then
            local dy,dx = pop(),pop()
            pdfimage.curx = pdfimage.curx + dx
            pdfimage.cury = pdfimage.cury + dy
            table.insert(pdfimage,pdfimage.curx)
            table.insert(pdfimage,pdfimage.cury)
            table.insert(pdfimage,"l")
        elseif pdfoperators[thistoken] then
            local tab = pdfoperators[thistoken]
            for s = tab[2],1,-1 do
                table.insert(pdfimage,stack[#stack + 1 - s])
            end
            for s = 1,tab[2] do
                table.remove(stack)
            end
            if thistoken == "moveto" or thistoken == "lineto" or thistoken == "curveto" then
                pdfimage.curx = pdfimage[#pdfimage - 1]
                pdfimage.cury = pdfimage[#pdfimage]
            end
            table.insert(pdfimage,tab[1])
        elseif ignored_pdfoperators[thistoken] then
            -- ignore
        else
            w("metapost.lua: ignore %s ",thistoken)
        end
    end
end

function pstopdf(str)
    -- w("str %s",tostring(str))
    lines = {}
    for s in str:gmatch("[^\r\n]+") do
        table.insert(lines, s)
    end

    local pdfimage = {}
    local stack = {}
    for i =1,#lines do
        local thisline = lines[i]
        if string.match(thisline,"^%%%%HiResBoundingBox:") then
            getboundingbox(pdfimage,thisline)
        elseif string.match(thisline,"^%%") then
            -- ignore
        else
            getpostscript(stack,pdfimage,thisline)
        end
    end

    return table.concat(pdfimage," ")
end


local function finder (name, mode, type)
    local loc = kpse.find_file(name)
    if mode == "r" then return loc  end
    return name
end

function execute(mpobj,str)
    -- w("execute %q",str)
    if not str then
        err("Empty metapost string for execute")
        return false
    end
    local l = mpobj.mp:execute(str)
    if l and l.status > 0 then
        err("Executing %s: %s", str,l.term)
        return false
    end
    mpobj.l = l
    return true
end

function newbox(width_sp, height_sp)
    local mp = mplib.new({mem_name = 'plain', find_file = finder,ini_version=true,math_mode = "double", random_seed = math.random(100) })
    local mpobj = {
        mp = mp,
        width = width_sp,
        height = height_sp,
    }
    for _,v in pairs({"plain","csscolors","metafun"}) do
        if not execute(mpobj,string.format("input %s;",v)) then
            err("Cannot start metapost.")
            return nil
        end
    end
    execute(mpobj,string.format("box.width = %fbp;",width_sp / 65782))
    execute(mpobj,string.format("box.height = %fbp;",height_sp / 65782))
    execute(mpobj,[[path box; box = (0,0) -- (box.width,0) -- (box.width,box.height) -- (0,box.height) -- cycle ;]])


    local declarations = {}
    for name,v in pairs(publisher.metapostcolors) do
        if v.model == "cmyk" then
            local varname = string.gsub(name,"%d","[]")
            local decl = string.format("cmykcolor colors.%s;",varname)
            if not declarations[decl] then
                declarations[decl] = true
                execute(mpobj,decl)
            end
            local mpstatement = string.format("colors.%s := (%g, %g, %g, %g);",name, v.c, v.m, v.y, v.k )

            execute(mpobj,mpstatement)
        elseif v.model == "rgb" then
            execute(mpobj,string.format("rgbcolor colors.%s; colors.%s := (%g, %g, %g);",name, name, v.r, v.g, v.b ))
        end
    end

    for name, v in pairs(publisher.metapostvariables) do
        local expr
        expr = string.format("%s %s ; %s := %s ;", v.typ,name,name,v[1])
        execute(mpobj,expr)
    end
    return mpobj
end

function finish(mpobj)
    local pdfstring
    if mpobj.l and mpobj.l.fig and mpobj.l.fig[1] then
        pdfstring = "q " .. pstopdf(mpobj.l.fig[1]:postscript()) .. " Q"
    end
    mpobj.mp:finish()
    return pdfstring
end

-- Return a pdf_whatsit node
function prepareboxgraphic(width_sp,height_sp,graphicname,extra_parameter)
    if not publisher.metapostgraphics[graphicname] then
        err("MetaPost graphic %s not defined",graphicname)
        return nil
    end
    local mpobj = newbox(width_sp,height_sp)
    execute(mpobj,"beginfig(1);")
    for k,v in pairs(extra_parameter or {}) do
        if k == "colors" and type(v) == "table" then
            for col, val in pairs(v) do
                local fmt = string.format("color %s; %s = %s;",col,col,val)
                execute(mpobj,fmt)
            end
        elseif k == "strings" and type(v) == "table" then
            for col, val in pairs(v) do
                local fmt = string.format("string %s; %s = %q;",col,col,val)
                execute(mpobj,fmt)
            end
        else
            local fmt = string.format("%s = %s ;",k,v)
            execute(mpobj,fmt)
        end
    end
    execute(mpobj,publisher.metapostgraphics[graphicname])
    execute(mpobj,"endfig;")
    local pdfstring = finish(mpobj);
    local a=node.new("whatsit","pdf_literal")
    a.data = pdfstring
    a.mode = 0
    return mpobj,a
end

-- return a vbox with the pdf_whatsit node
function boxgraphic(width_sp,height_sp,graphicname,extra_parameter,parameter)
    local mpobj, a = prepareboxgraphic(width_sp,height_sp,graphicname,extra_parameter)
    a = node.hpack(a,mpobj.width,"exactly")
    a.height = mpobj.height
    if parameter and parameter.shiftdown then
        a.height = a.height + parameter.shiftdown
    end
    a = node.vpack(a)
    return a
end