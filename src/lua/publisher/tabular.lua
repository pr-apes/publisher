--
--  tabular.lua
--  speedata publisher
--
--  For a list of authors see `git blame'
--  See file COPYING in the root directory for license details.

file_start("tabular.lua")

module(...,package.seeall)

local metapost = require("publisher.metapost")

local dynamic_data = {}

function new( self )
    assert(self)
    local t = {
        rowheights        = {},
        colwidths         = {},
        align             = {},
        valign            = {},
        padding_left_col  = {},
        padding_right_col = {},
        skip              = {},
        backgroundcolumncolors  = {},
        -- The distance between column i and i+1
        column_distances = {},
        -- number of frames the table is split across, initialize to a sane default value
        split = 1,
    }

    setmetatable(t, self)
    self.__index = self
    return t
end

--- The objects in a table cell can be block objects or inline objects.
--- See the list of [html block objects](https://developer.mozilla.org/en-US/docs/Web/HTML/Block-level_elements)
--- for a rule of thumb how objects are arranged in a table cell. I am not sure if we should fully follow
--- the HTML way.
---
--- The inner arrays contain the objects to be stacked from left to right (“inline”)
--- and the outer array is a list of block objects that are to be stacked from top to bottom:
---     { { img      },
---       { par      },
---       { img, img },
---       { table    }  }
---
--- ![Objects in a table](../img/objectsintable.svg)
--- The table is stored in the objects
function attach_objects_row( self, tab, current_row,skiptable )
    -- For each block object (container) there is one row in block
    local td_elementname
    local td_contents
    local current_column = 0
    for _,td in ipairs(tab) do
        current_column = current_column + 1
        td_elementname = publisher.elementname(td)
        td_contents    = publisher.element_contents(td)
        if td_elementname == "Td" then
            local block = {}
            local inline = {}
            local colspan = tonumber(td_contents.colspan) or 1
            local thiscolumn = current_column
            current_column = current_column + colspan - 1
            while skiptable[current_row] and skiptable[current_row][current_column] do
                thiscolumn = thiscolumn + 1
                current_column = current_column + 1
            end
            for i,j in ipairs(td_contents) do
                local eltname     = publisher.elementname(j)
                local eltcontents = publisher.element_contents(j)
                if eltname == "Image" then
                    -- inline
                    inline[#inline + 1] = eltcontents[1]
                elseif eltname == "Barcode" then
                    -- inline
                    inline[#inline + 1] = eltcontents
                elseif eltname == "Overlay" then
                    -- inline
                    inline[#inline + 1] = eltcontents
                elseif eltname == "VSpace" then
                    if #inline > 0 then
                        -- add current inline to the list of blocks
                        block[#block + 1] = inline
                        inline = {}
                    end
                    block[#block + 1] = {eltcontents}
                elseif eltname == "Paragraph" or eltname == "Box" then
                    -- the text format for the whole table
                    local default_textformat_name = self.textformat
                    -- td align=..., tr align=... and columns align=...
                    local alignment = td_contents.align or tab.align or self.align[thiscolumn]
                    if     alignment=="center"  then  default_textformat_name = "__centered"
                    elseif alignment=="left"    then  default_textformat_name = "__leftaligned"
                    elseif alignment=="right"   then  default_textformat_name = "__rightaligned"
                    elseif alignment=="justify" then  default_textformat_name = "__justified"
                    end
                    -- box doesn't have field textformat
                    if type(eltcontents) == "table" then
                        -- if <Paragraph> has its own text format then use this, instead of the td... one above
                        local tfname = ( eltcontents.textformat and eltcontents.textformat.name) or default_textformat_name or "__leftaligned"
                        eltcontents.textformat = publisher.textformats[tfname]
                        eltcontents.rotate = eltcontents.rotate
                    end
                    -- block
                    if #inline > 0 then
                        -- add current inline to the list of blocks
                        block[#block + 1] = inline
                        inline = {}
                    end
                    block[#block + 1] = {eltcontents}
                elseif eltname == "Table" or eltname == "Groupcontents" then
                    -- block
                    if #inline > 0 then
                        -- add current inline to the list of blocks
                        block[#block + 1] = inline
                        inline = {}
                    end
                    block[#block + 1] = eltcontents
                elseif eltname == "Message" then
                    -- ignore
                else
                    warning("Unknown object in table: %s",eltname or "???")
                end
            end
            if #inline > 0 then
                -- add current inline to the list of blocks
                block[#block + 1] = inline
            end
            td_contents.objects = block
            td_contents.objects.rotate = td_contents.rotate
        elseif td_elementname == "Tr" then -- probably from tablefoot/head
            attach_objects_row(self,td_contents,current_row, skiptable)
        elseif td_elementname == "Column" or td_elementname == "Tablerule" or td_elementname == "TableNewPage" then
            -- ignore, they don't have objects
        else
           -- w("unknown element name %s",td_elementname)
        end
    end
end

function attach_objects( self, tab, row )
    row = row or 1
    for _,tr in ipairs(tab) do
        local eltname = publisher.elementname(tr)
        local tr_contents = publisher.element_contents(tr)
        if eltname == "Tr" then
            local skiptable = self.skiptables.body
            attach_objects_row(self, publisher.element_contents(tr), row,skiptable)
            row = row + 1
        elseif eltname == "Tablehead" or eltname == "Tablefoot" then
            local area
            if eltname == "Tablehead" then area = "tablehead" else area = "tablefoot" end
            area = area .. (tr_contents.page or "")
            local skiptable = self.skiptables[area] or {}
            attach_objects_row(self, publisher.element_contents(tr), row,skiptable)
        end
    end
end

--- Width calculation
--- =================

--- First we check for adjacent columns for collapsing border:
--- ![maximum width](../img/bordercollapse.svg)
---
--- The resulting width for each border (left and right) is
---
--- \\(\frac{max(border-left,border-right)}{2}\\)
---
--- even if one
--- side didn't have a border. In that case we need to adjust the border colors. Beware: the result is slightly undefined
--- if both sides have different colors.
-- Calculate the width for each column in the row.
function calculate_columnwidths_for_row(self, tr_contents,current_row,colspans,colmin,colmax,skiptable )
    local current_column = 0
    local max_wd, min_wd -- maximum and minimum width of a table cell (Td)
    -- first we go through all rows/cells and look, how wide the columns
    -- are supposed to be. If there are colspans, they have to be treated specially

    --- We calculate the widths in two passes:
    ---
    ---  1. Calculate the width of each table cell in a row
    ---  1. Calculate the row height
    ---
    --- The minimum width (min\_wd) is calculated as follows. Calculate the length of the longest item in the row:
    ---
    --- ![minimum width](../img/calculate_longtext2.svg)
    ---
    --- The maximum width (max\_wd) is calculated by typesetting the text and taking total size of the hbox into account:
    ---
    --- ![maximum width](../img/calculate_longtext.svg)
    ---
    for _,td in ipairs(tr_contents) do
        local td_contents = publisher.element_contents(td)
        -- all columms (table cells)
        -- fill skip, colspan and colmax-tables for this cell
        current_column = current_column + 1
        min_wd,max_wd = nil,nil
        local colspan = tonumber(td_contents.colspan) or 1

        -- When I am on a skip column (because of a row span), we jump over to the next column
        while skiptable[current_row] and skiptable[current_row][current_column] do current_column = current_column + 1 end

        local td_borderleft  = tex.sp(td_contents["border-left"]  or 0)
        local td_borderright = tex.sp(td_contents["border-right"] or 0)
        local padding_left   = td_contents.padding_left  or self.padding_left_col[current_column]  or self.padding_left
        local padding_right  = td_contents.padding_right or self.padding_right_col[current_column] or self.padding_right
        local cellheight = 0
        for _,blockobject in ipairs(td_contents.objects) do
            for i=1,#blockobject do
                local inlineobject = blockobject[i]
                if type(inlineobject)=="table" and node.is_node(inlineobject.nodelist) then
                    local wd, ht, dp = node.dimensions(inlineobject.nodelist)
                    max_wd = math.max(wd + padding_left  + padding_right + td_borderleft + td_borderright, max_wd or 0)
                    min_wd = paragraph.minimal_width_nodelist(inlineobject.nodelist,inlineobject.textformat)
                    cellheight = cellheight + ht + dp
                elseif type(inlineobject)=="table" then
                    if inlineobject.min_width then
                        local mw = inlineobject:min_width(inlineobject.alignment,{fontfamily = inlineobject.fontfamily or self.fontfamily})
                        min_wd = math.max(mw + padding_left  + padding_right + td_borderleft + td_borderright, min_wd or 0)
                    end
                    if inlineobject.max_width_and_lineheight then
                        local mw,cellheight = inlineobject:max_width_and_lineheight({fontfamily = inlineobject.fontfamily or self.fontfamily})
                        max_wd = math.max(mw + padding_left  + padding_right + td_borderleft + td_borderright, max_wd or 0)
                    end
                elseif node.is_node(inlineobject) and node.has_field(inlineobject,"width") then
                    min_wd = math.max(inlineobject.width + padding_left  + padding_right + td_borderleft + td_borderright, min_wd or 0)
                    max_wd = math.max(inlineobject.width + padding_left  + padding_right + td_borderleft + td_borderright, max_wd or 0)
                    if node.has_field(inlineobject,"height") then
                        cellheight = cellheight + inlineobject.height
                    end
                    if node.has_field(inlineobject,"depth") then
                        cellheight = cellheight + inlineobject.depth
                    end
                end
            end
            if not ( min_wd and max_wd) then
                if node.has_field(inlineobject,"width") then
                    if inlineobject.width then
                        min_wd = inlineobject.width + padding_left  + padding_right + td_borderleft + td_borderright
                        max_wd = inlineobject.width + padding_left  + padding_right + td_borderleft + td_borderright
                    else
                        warning("Could not determine min_wd and max_wd")
                        assert(false)
                    end
                else
                    min_wd = 0
                    max_wd = 0
                end
            end
        end
        -- colspan?
        min_wd = min_wd or 0
        max_wd = max_wd or 0
        local angle_rad = -1 * math.rad(td_contents.rotate or 0)
        max_wd = math.abs(max_wd * math.cos(angle_rad)) + math.abs(cellheight * math.sin(angle_rad))
        if colspan > 1 then
            colspans[#colspans + 1] = { start = current_column, stop = current_column + colspan - 1, max_wd = max_wd, min_wd = min_wd }
            current_column = current_column + colspan - 1
        else
            colmax[current_column] = math.max(colmax[current_column] or 0,max_wd)
            colmin[current_column] = math.max(colmin[current_column] or 0,min_wd)
        end
    end  -- ∀ columns
end

function collect_alignments( self )
    for _,tr in ipairs(self.tab) do
        local tr_contents      = publisher.element_contents(tr)
        local tr_elementname = publisher.elementname(tr)
        if tr_elementname == "Columns" then
            local i = 0
            for _,column in ipairs(tr_contents) do
                if publisher.elementname(column)=="Column" then
                    local column_contents = publisher.element_contents(column)
                    i = i + 1
                    self.align[i]             = column_contents.align
                    self.valign[i]            = column_contents.valign
                    self.padding_left_col[i]  = column_contents.padding_left
                    self.padding_right_col[i] = column_contents.padding_right
                end
            end
        end
    end
end


-- This code is not really correct. See #332 for more information.
-- The column widths should be adjusted as well.
function merge_border_with_nextcell(row,x)
    local thiscell,nextcell,nextcell_borderleft,thiscell_borderright,new_borderwidth
    thiscell = row[x]
    nextcell = row[x+1]

    thiscell_borderright = tex.sp(thiscell["border-right"] or 0)
    nextcell_borderleft  = tex.sp(nextcell["border-left"]  or 0)
    new_borderwidth = math.abs( math.max(thiscell_borderright,nextcell_borderleft) / 2 )

    nextcell["border-left"]  = new_borderwidth
    thiscell["border-right"] = new_borderwidth

    if thiscell_borderright == 0 then
        thiscell["border-right-color"] = nextcell["border-left-color"]
    end
    if nextcell_borderleft == 0 then
        nextcell["border-left-color"] = thiscell["border-right-color"]
    end
end

function merge_border_with_nextrow(tablematrix,row,col,cols)
    local thiscell,nextcell,new_borderwidth
    thiscell = tablematrix[row][col]
    thiscell_borderbottom = tex.sp(thiscell["border-bottom"] or 0)
    if tonumber(thiscell.rowspan) and thiscell.rowspan > 1 then return end
    for i = 1, cols do
        nextcell = tablematrix[row + 1][col + i - 1]
        nextcell_bordertop  = tex.sp(nextcell["border-top"]  or 0)
        new_borderwidth = math.abs( math.max(thiscell_borderbottom,nextcell_bordertop) / 2 )

        nextcell["border-top"]  = new_borderwidth
        if i == 1 then
            thiscell["border-bottom"] = new_borderwidth
        end

        if thiscell_borderbottom == 0 then
            thiscell["border-bottom-color"] = nextcell["border-top-color"]
        end
        if nextcell_bordertop == 0 then
            nextcell["border-top-color"] = thiscell["border-bottom-color"]
        end
    end
end


function adjust_borderwidths_collapse(self,tr_contents,tablearea)
    tablearea = tablearea or "body"
    local firstrow = tr_contents[1]
    local eltname = publisher.elementname(firstrow)
    if eltname == "Tablehead" or eltname == "Tablefoot" then
        if eltname == "Tablehead" then tablearea = "tablehead" else tablearea = "tablefoot" end
        tablearea = tablearea .. (tr_contents[i].page or "")
        adjust_borderwidths_collapse(self,publisher.element_contents(firstrow),tablearea)
        return
    end
    local skiptable = self.skiptables[tablearea]
    -- tablematrix has one cell for each virtual cell. A cell with rowspan=2 has two entries.
    -- The value for the entry is the td_contents of the cell.
    local tablematrix = {}
    local row = 0
    local maxcol = 0
    for i = 1,#tr_contents do
        local eltname = publisher.elementname(tr_contents[i])
        local tr = publisher.element_contents(tr_contents[i])
        if eltname == "Tr" then
            row = row + 1
            tablematrix[row] = tablematrix[row] or {}

            local col = 0
            for j = 1, #tr do
                local td = publisher.element_contents(tr[j])
                col = col + 1
                while skiptable[row] and skiptable[row][col] do
                    col = col + 1
                end
                tablematrix[row][col] = td
                maxcol = math.max(maxcol,j)

                if skiptable[row + 1] and skiptable[row + 1][col] then
                    local r = row + 1
                    while skiptable[r] and skiptable[r][col] do
                        tablematrix[r] = tablematrix[r] or {}
                        tablematrix[r][col] = td
                        r = r + 1
                    end
                end
            end
        end
    end

    for y = 1, #tablematrix do
        local thisrow = tablematrix[y]
        for x = 1,#thisrow - 1 do
            merge_border_with_nextcell(thisrow,x)
        end
    end

    for y = 1, #tablematrix - 1 do
        local thisrow = tablematrix[y]
        local x = 1
        while x <= #thisrow do
            local cs = tablematrix[y][x].colspan or 1
            merge_border_with_nextrow(tablematrix,y,x,cs)
            x = x + cs
        end
    end

end

--- Calculate the widths of the columns for the table.
--- -------------------------------------------------
function calculate_columnwidth( self )
    -- first, adjust widths for border collapse
    if self.bordercollapse then
        adjust_borderwidths_collapse(self,self.tab)
    end


    local colspans = {}
    local minwidths,col_shrink,starcols,colmax,colmin = {},{},{},{},{}
    local hasminwidth = false
    local current_row = 0
    self.tablewidth_target = self.width
    local columnwidths_given = false

    for _,tr in ipairs(self.tab) do
        local tr_contents      = publisher.element_contents(tr)
        local tr_elementname = publisher.elementname(tr)

        --- When the user gives us column widths, we use them for calculation. There are two ways to
        --- determine the column widths: with \\(n\\)* (where \\(n\\) is an integer number) or with absolute
        --- lengths such as `4` (in grid cells) or `2.5cm`. For example:
        ---
        ---     <Columns>
        ---       <Column width="3cm"/>
        ---       <Column width="1*"/>
        ---       <Column width="3*"/>
        ---     </Columns>
        ---
        --- When we typeset a table with a requested with of 11cm, the first column would get 3cm,
        --- the second column 1/4 of the rest (2cm) and the third 3/4 of the rest (6cm).
        --- ![Table calculation](../img/table313.svg)
        if tr_elementname == "Columns" then
            local i = 0
            local count_stars = 0
            local sum_real_widths = 0
            local count_columns = 0
            local starpattern = "([0-9]+)%*"
            for _,column in ipairs(tr_contents) do
                if publisher.elementname(column)=="Column" then
                    local column_contents = publisher.element_contents(column)
                    i = i + 1
                    if column_contents.minwidth then
                        minwidths[i] = column_contents.minwidth
                    end
                    if column_contents.width then
                        -- if I have something written in <column> I don't need
                        -- to calculate column width:
                        if column_contents.width == "max" then
                            col_shrink[i] = 1
                            hasminwidth = true
                        elseif column_contents.width == "min" then
                            col_shrink[i] = 2
                            hasminwidth = true
                        else
                            columnwidths_given = true
                            local width_stars = string.match(column_contents.width,starpattern)
                            if width_stars then
                                starcols[i] = tonumber(width_stars,10)
                                count_stars = count_stars + width_stars
                            else
                                if tonumber(column_contents.width) then
                                    self.colwidths[i] = publisher.current_grid:width_sp(column_contents.width)
                                else
                                    self.colwidths[i] = tex.sp(column_contents.width)
                                end
                                sum_real_widths = sum_real_widths + self.colwidths[i]
                            end
                        end
                    end
                    if column_contents.backgroundcolor then
                        self.backgroundcolumncolors[i] = column_contents.backgroundcolor
                    end
                end
                count_columns = i
            end

            -- if stretch="no", we don't need to stretch/shrink anything
            -- count_stars == 0 if there are only fixed width columns
            -- given in the <Column width="..."/>  setting.
            if self.autostretch ~= "max" and count_stars == 0 then
                self.tablewidth_target = sum_real_widths
            end
            if hasminwidth then
                columnwidths_given = false
                break
            end

            if columnwidths_given and count_stars == 0 then return end

            if count_stars > 0 then
                -- now we know the number of *-columns and the sum of the fix columns, so that
                -- we can distribute the remaining space
                local to_distribute = self.tablewidth_target - sum_real_widths - table.sum(self.column_distances,1,count_columns - 1)
                i = 0
                for _,column in ipairs(tr_contents) do
                    if publisher.elementname(column)=="Column" then
                        local column_contents = publisher.element_contents(column)
                        i = i + 1
                        local width_stars = string.match(column_contents.width,starpattern)
                        if width_stars then
                            self.colwidths[i] = math.round( to_distribute *  width_stars / count_stars ,0)
                        end
                    end
                end
            end -- sum_* > 0
        end
    end

    if columnwidths_given then return end

    --- Phase I
    --- -------
    --- Calculate max\_wd, min\_wd. We do this in a separate function for each row.
    for _,tr in ipairs(self.tab) do
        local tr_contents      = publisher.element_contents(tr)
        local tr_elementname = publisher.elementname(tr)
        if tr_elementname == "Tr" then
            current_row = current_row + 1
            self:calculate_columnwidths_for_row(tr_contents,current_row,colspans,colmin,colmax,self.skiptables.body)
        elseif tr_elementname == "Tablerule" then
            -- ignore
        elseif tr_elementname == "Tablehead" or tr_elementname == "Tablefoot" then
            local area
            if tr_elementname == "Tablehead" then area = "tablehead" else area = "tablefoot" end
            area = area .. (tr_contents.page or "")
            for _,row in ipairs(tr_contents) do
                local row_contents    = publisher.element_contents(row)
                local row_elementname = publisher.elementname(row)
                if row_elementname == "Tr" then
                    current_row = current_row + 1
                    self:calculate_columnwidths_for_row(row_contents,current_row,colspans,colmin,colmax,self.skiptables[area])
                end
            end
        elseif tr_elementname == "Columns" or tr_elementname == "TableNewPage" then
            -- ignore
        else
            warning("Unknown Element: %q",tr_elementname or "?")
        end -- if it's really a row
    end -- ∀ rows / rules

    if hasminwidth then
        local one_star_width = self.tablewidth_target
        local to_distribute = 0
        for i = 1, #colmin do
            if col_shrink[i] then
                local to_shrink
                if col_shrink[i] == 1 then
                    to_shrink = colmax[i]
                    if minwidths[i] and minwidths[i] > colmax[i] then
                        to_shrink = minwidths[i]
                    end
                else
                    to_shrink = colmin[i]
                    if minwidths[i] and minwidths[i] > colmin[i] then
                        to_shrink = minwidths[i]
                    end
                end
                one_star_width = one_star_width - to_shrink
                self.colwidths[i] = to_shrink
            elseif starcols[i] then
                to_distribute = to_distribute + starcols[i]
            else
                one_star_width = one_star_width - self.colwidths[i]
            end
        end
        one_star_width = one_star_width / to_distribute

        for i = 1, #colmin do
            if starcols[i] then
                self.colwidths[i] = one_star_width * starcols[i]
            end
        end
        return
    end

    --- Now we are finished with all cells in all rows. If there are colospans, we might have
    --- to increase some column widths
    ---
    --- Example (fake):
    ---
    ---     <Table width="30">
    ---       <Tr><Td>A</Td><Td>A</Td></Tr>
    ---       <Tr><Td colspan="2">A very very very long text</Td></Tr>
    ---     </Table>
    ---     ----------------------------
    ---     |A           |A            |
    ---     |A very very very long text|
    ---     ----------------------------
    ---
    --- In this case sum(min) is approx. the width of the word "very" and sum(max) is the width of the text.
    --- colmax[i] is the width of "A", colmin[i] also
    ---
    --- Phase II: include colspan
    --- -------------------------
    for i,colspan in pairs(colspans) do
        local sum_min,sum_max = 0,0
        local r -- stretch factor = wd(colspan)/wd(sum_start_end)

        --- First we calculate how wide the columns are that are covered by colspan, but without
        --- colspan itself

        if #colmax < colspan.stop then
            err("Not enough columns found for colspan")
            return -1
        end
        sum_max = table.sum(colmax,colspan.start,colspan.stop)
        sum_min = table.sum(colmin,colspan.start,colspan.stop)

        --- If the colspan requires more room than the rest of the table, we have to increase
        --- the width of all columns in the table accordingly. We stretch the columns by
        --- a factor r. r is calculated by the contents.
        ---
        --- We do that once for the maximum width and once for the minimum width
        local width_of_colsep = table.sum(self.column_distances,colspan.start,colspan.start)

        if colspan.max_wd > sum_max + width_of_colsep then
            r = ( colspan.max_wd - width_of_colsep ) / sum_max
            for j=colspan.start,colspan.stop do
                colmax[j] = colmax[j] * r
            end
        end -- colspan.max_wd > sum_max?

        if colspan.min_wd > sum_min + width_of_colsep then
            r = ( colspan.min_wd - width_of_colsep ) / sum_min
            for j=colspan.start,colspan.stop do
                colmin[j] = colmin[j] * r
            end
        end -- colspan.min_wd > sum_min?
    end -- ∀ colspans

    -- Now colmin and colmax are calculated for all columns. colspans are included.


    --- Phase III: Stretch or shrink table
    --- ----------------------------------

    -- Here comes the main width calculation
    -- FIXME: we should use column_distances[i] instead of self.colsep
    local colsep = (#colmax - 1) * self.colsep
    local tablewidth_is = table.sum(colmax) + colsep

    --- 1. calculate natural (max) width / total width for each column.
    ---
    --- If stretch="no" is set, we can encounter the case that the table is too wide. Then it
    --- must be shrunk.

    -- highly unlikely that the table matches the size exactly
    if tablewidth_is == self.tablewidth_target then
        for i=1,#colmax do
            self.colwidths[i] = colmax[i]
        end
        return
    end

    -- if the table is too wide, we need to shrink some columns
    if tablewidth_is > self.tablewidth_target then
        local col_r = {} -- temporary column width after shrinking
        local shrink_factor = {}
        local sum_shrinkfactor = 0
        local excess = 0
        local r = ( self.tablewidth_target - colsep )  / ( tablewidth_is - colsep)
        for i=1,#colmax do
            -- actually:
            -- r[i] = colmax[i] / tablewidth_is
            -- to get to the row width we need to multiply with tablewidth_target
            col_r[i] = colmax[i] * r

            -- if the calculated width is less than the minimal width, the cell needs to be wider
            -- and the total width must be reduced by the excess.
            if col_r[i] < colmin[i] then
                excess = excess + colmin[i] - col_r[i]
                self.colwidths[i] = colmin[i]
            end
            if col_r[i] > colmin[i] then
                -- this column can be shrunk if necessary. The factor is col_r[i] / colmin[i]
                shrink_factor[i] = col_r[i] / colmin[i]
                sum_shrinkfactor = sum_shrinkfactor + shrink_factor[i]
            end
        end
        -- the excess must be subtracted partly from the columns that are to wide
        for i=1,#colmax do
            if shrink_factor[i] then
                self.colwidths[i] = col_r[i] -  shrink_factor[i] / sum_shrinkfactor * excess
            elseif colmax[i] == 0 then
                self.colwidths[i] = 0
            end
        end
        return
    end

    -- if stretch="no", we don't need to stretch/shrink anything
    if self.autostretch ~= "max" then
        self.tablewidth_target = tablewidth_is
        for i=1,#colmax do
            self.colwidths[i] = colmax[i]
        end

        return
    end


    -- if the table is too narrow, we must make it wider
    if tablewidth_is < self.tablewidth_target then
        -- table must get wider
        local r = ( self.tablewidth_target - colsep ) / ( tablewidth_is - colsep )
        for i=1,#colmax do
            self.colwidths[i] = colmax[i] * r
        end
    end
end

-- Typeset a table cell. Return a vlist, tightly packed (i.e. all vspace are 0).
function pack_cell(self, blockobjects, width, horizontal_alignment)
    local cell
    for _,blockobject in ipairs(blockobjects) do
        local cellrow = nil
        local current_width = 0
        if node.is_node(blockobject) then
            cellrow = node.insert_after(cellrow,node.tail(cellrow),blockobject)
        else
            for i=1,#blockobject do
                local inlineobject = blockobject[i]
                if type(inlineobject) == "table" then
                    if width then
                        local angle_rad = -1 * math.rad(blockobjects.rotate or 0)
                        local sin_angle = math.sin( angle_rad )
                        local format_width = width
                        if sin_angle ~= 0 then
                            -- The width is not 100% accurate yet. Multi-line paragraphs for example
                            -- are not yet taken into account.
                            local mw = inlineobject:max_width_and_lineheight({fontfamily = inlineobject.fontfamily or self.fontfamily})
                            format_width = math.max(format_width, mw * sin_angle )
                        end

                        local v = inlineobject:format(format_width,{textformat = inlineobject.textformat,fontfamily = inlineobject.fontfamily or self.fontfamily })
                        cell = node.insert_after(cell,node.tail(cell),v)
                    else
                        w("no width given in paragraph")
                    end
                elseif node.is_node(inlineobject) then
                    -- an image for example
                    if node.has_field(inlineobject,"width") then
                        -- insert a line break if the row is too wide
                        if current_width + inlineobject.width > width then
                            local tmp
                            if cellrow then
                                if cellrow.next then
                                    tmp = node.hpack(cellrow)
                                else
                                    tmp = cellrow
                                end
                            end
                            cell = node.insert_after(cell,node.tail(cell),tmp)
                            cellrow = inlineobject
                            current_width = inlineobject.width
                        else
                            current_width = current_width + inlineobject.width
                            cellrow = node.insert_after(cellrow,node.tail(cellrow),inlineobject)
                        end
                    else
                        cellrow = node.insert_after(cellrow,node.tail(cellrow),inlineobject)
                    end

                else
                    w("unknown %s",type(inlineobject))
                end
            end
        end

        -- cellrow can be nil if there is a paragraph for example
        if cellrow then
            local tmp
            if cellrow.next then
                tmp = node.hpack(cellrow)
            else
                tmp = cellrow
            end
            cell = node.insert_after(cell,node.tail(cell),tmp)
        end
    end

    -- if there are no objects in a row, we create a dummy object
    -- so the row can be created and vpack does not fall over a nil
    cell = cell or node.new("hlist")
    cell = publisher.rotateTd(cell,blockobjects.rotate or 0,width)

    local n = cell
    while n do
        if n.id == publisher.hlist_node or n.id == publisher.vlist_node then
            local n_prev = n.prev
            local n_next = n.next
            local tmp = n
            n.next = nil
            local glue_left, glue_right

            if horizontal_alignment == "center" or horizontal_alignment == "justify" then
                glue_left = node.copy(publisher.glue_stretch2)
                glue_right = node.copy(publisher.glue_stretch2)
            elseif horizontal_alignment=="left" or horizontal_alignment == nil then
                glue_left = nil
                glue_right = node.copy(publisher.glue_stretch2)
            elseif horizontal_alignment=="right"   then
                glue_left = node.copy(publisher.glue_stretch2)
                glue_right = nil
            end

            if glue_left then
                publisher.setprop(glue_left,"origin","align_left")
                tmp = node.insert_before(tmp,n,glue_left)
            end
            if glue_right then
                publisher.setprop(glue_right,"origin","align_right")
                tmp = node.insert_after(tmp,n,glue_right)
            end
            tmp = node.hpack(tmp,width,"exactly")

            if n_prev then
                n_prev.next = tmp
            end
            if n_next then
                n_next.prev = tmp
            end
            tmp.prev = n_prev
            tmp.next = n_next
            if n == cell then
                cell = tmp
            end
            n = tmp
        end
        n = n.next
    end
    local ret
    ret = node.vpack(cell)
    return ret
end

--- last\_shiftup is for vertical border-collapse.
function calculate_rowheight( self,tr_contents, current_row,last_shiftup,skiptable )
    last_shiftup = last_shiftup or 0
    local rowheight
    local rowspan,colspan
    local wd,parameter
    local rowspans = {}
    local shiftup = 0

    local fam = publisher.fonts.lookup_fontfamily_number_instance[self.fontfamily]
    local min_lineheight = fam.baselineskip

    if tr_contents.minheight then
        local minht
        if tonumber(tr_contents.minheight) then
            minht = publisher.current_grid:height_sp(tr_contents.minheight)
        else
            minht = tex.sp(tr_contents.minheight)
        end
        minht = minht or 0
        rowheight = math.max(minht, min_lineheight)
    else
        rowheight = min_lineheight
    end

    -- its not trivial to find out in which column I am in.
    -- See the example in qa/tables/columnspread. Line three:
    -- The first cell is in column 1, the second cell is in column 4
    local current_column = 0

    for _,td in ipairs(tr_contents) do
        local td_contents = publisher.element_contents(td)
        if td_contents == nil then
            err("No contents in Td")
            return rowheight,rowspans,shiftup
        end
        current_column = current_column + 1

        local td_borderleft   = tex.sp(td_contents["border-left"]   or 0)
        local td_borderright  = tex.sp(td_contents["border-right"]  or 0)
        local td_bordertop    = tex.sp(td_contents["border-top"]    or 0)
        local td_borderbottom = tex.sp(td_contents["border-bottom"] or 0)
        local padding_left   = td_contents.padding_left   or self.padding_left_col[current_column]  or self.padding_left
        local padding_right  = td_contents.padding_right  or self.padding_right_col[current_column] or self.padding_right
        local padding_top    = td_contents.padding_top    or self.padding_top
        local padding_bottom = td_contents.padding_bottom or self.padding_bottom

        rowspan = tonumber(td_contents.rowspan) or 1
        colspan = tonumber(td_contents.colspan) or 1
        wd = 0

        -- There might be a rowspan in the row above, so we need to find the correct
        -- column width

        while skiptable[current_row] and skiptable[current_row][current_column] do
            current_column = current_column + 1
        end
        for s = current_column,current_column + colspan - 1 do
            if self.colwidths[s] == nil then
                err("Something went wrong with the number of columns in the table (calculate_rowheight)")
            else
                wd = wd + self.colwidths[s]
            end
        end
        current_column = current_column + colspan - 1
        -- FIXME: use column_distances[i] instead of self.colsep
        wd = wd + ( colspan - 1 ) * self.colsep

        -- FIXME: take border-left and border-right into account
        --        in the height calculation also border-top and border-bottom
        local alignment = td_contents.align or tr_contents.align or self.align[current_column]
        local cell = self:pack_cell(td_contents.objects,wd - padding_left - padding_right - td_borderleft - td_borderright,alignment)
        td_contents.cell = cell
        local tmp = cell.height + cell.depth
        local _w, _h, _d = node.dimensions(cell)

        tmp = tmp + padding_top + padding_bottom + td_borderbottom + td_bordertop
        if rowspan > 1 then
            rowspans[#rowspans + 1] =  { start = current_row, stop = current_row + rowspan - 1, ht = tmp }
            td_contents.rowspan_internal = rowspans[#rowspans]
        else
            rowheight = math.max(rowheight,tmp)
        end
    end
    tr_contents.shiftup = last_shiftup
    return rowheight,rowspans,shiftup
end


function calculate_rowheights(self)
    -- rowspans is the concatenation of each rowspan for a table row
    local rowspans = {}
    local _rowspans
    local rowheightarea
    local tablearea
    local rowcounter = {}
    local current_row

    local last_shiftup = 0

    for _,tr in ipairs(self.tab) do
        local tr_contents = publisher.element_contents(tr)
        local eltname = publisher.elementname(tr)
        if eltname == "Tablerule" or eltname == "Columns" or eltname == "TableNewPage" then
            -- ignore
        elseif eltname == "Tablehead" then
            tablearea = "tablehead" .. (tr_contents.page or "")
        elseif eltname == "Tablefoot" then
            tablearea = "tablefoot" .. (tr_contents.page or "")
        else
            tablearea = "body"
        end
        if tablearea then
            self.rowheights[tablearea] = self.rowheights[tablearea] or {}
            rowheightarea = self.rowheights[tablearea]
            rowspans[tablearea] = rowspans[tablearea] or {}
            rowcounter[tablearea] = rowcounter[tablearea] or 0
        end

        if eltname == "Tablerule" or eltname == "Columns" or eltname == "TableNewPage" then
            -- ignore
        elseif eltname == "Tablehead" or eltname == "Tablefoot" then
            local last_shiftup = 0
            for _,row in ipairs(tr_contents) do
                local cellcontents  = publisher.element_contents(row)
                local cell_elementname = publisher.elementname(row)
                if cell_elementname == "Tr" then
                    rowcounter[tablearea] = rowcounter[tablearea] + 1
                    current_row = rowcounter[tablearea]
                    rowheight, _rowspans,last_shiftup = self:calculate_rowheight(cellcontents,current_row,last_shiftup,self.skiptables[tablearea])
                    rowheightarea[current_row] = rowheight
                    rowspans[tablearea] = table.__concat(rowspans[tablearea],_rowspans)
                end
            end
        elseif eltname == "Tr" then
            rowcounter[tablearea] = rowcounter[tablearea] + 1
            current_row = rowcounter[tablearea]
            rowheight, _rowspans,last_shiftup = self:calculate_rowheight(tr_contents,current_row,last_shiftup,self.skiptables.body)
            rowheightarea[current_row] = rowheight
            rowspans[tablearea] = table.__concat(rowspans[tablearea],_rowspans)
        else
            warning("Unknown contents in “Table” %s",eltname or "?")
        end -- if it's not a <Tablerule>
    end -- for all rows

    for k,v in pairs(self.rowheights) do
        local thisrowspan = rowspans[k]
        self:adjust_row_heights_for_rowspans(thisrowspan,v)
    end
end

function adjust_row_heights_for_rowspans(self,rowspans,area)
    -- Adjust row heights. We have to do calculations on all row heights, before the rows can get their
    -- final heights
    for i,rowspan in pairs(rowspans) do
        local sum_ht = 0
        for j=rowspan.start,rowspan.stop do
            if not area[j] then
                err("Rowspan exceeds the number of rows in the table")
            else
                sum_ht = sum_ht + area[j]
            end
        end
        sum_ht = sum_ht + self.rowsep * ( rowspan.stop - rowspan.start )
        if rowspan.ht > sum_ht then
            if self.vexcess == "bottom" then
                area[rowspan.stop] = area[rowspan.stop] + rowspan.ht - sum_ht
            else
                local excess_per_row = (rowspan.ht - sum_ht) / (rowspan.stop - rowspan.start + 1)
                for j=rowspan.start,rowspan.stop do
                    area[j] = area[j] + excess_per_row
                end
            end
        end
    end

    -- We have now calculated all row heights. So we can adjust the rowspans now.
    for i,rowspan in pairs(rowspans) do
        rowspan.sum_ht = table.sum(area,rowspan.start, rowspan.stop) + self.rowsep * ( rowspan.stop - rowspan.start )
    end
end

--- ![Table cell](../img/cell.svg)

--- Width calculation is now finished, we can typeset the table
--- Typesetting the table
--- ---------------------
--- First, we create a complete table with all rows. Splitting into pages is done later on
-- Return one row (an hlist)
function typeset_row(self, tr_contents,current_row,skiptable,rowheightarea )
    local current_column
    local current_column_width, ht
    local row = {}
    local rowspan, colspan
    local v,vlist,hlist
    local fill = { width = 0, stretch = 2^16, stretch_order = 3}
    local td_contents
    current_column = 0
    for _,td in ipairs(tr_contents) do
        current_column = current_column + 1

        td_contents = publisher.element_contents(td)
        if td_contents == nil then
            err("td_contents is empty (nil)")
            return publisher.emergency_block()
        end
        rowspan = tonumber(td_contents.rowspan) or 1
        colspan = tonumber(td_contents.colspan) or 1

        -- FIXME: am I sure that I am in the corerct column?  (colspan...)?
        local td_borderleft   = tex.sp(td_contents["border-left"]   or 0)
        local td_borderright  = tex.sp(td_contents["border-right"]  or 0)
        local td_bordertop    = tex.sp(td_contents["border-top"]    or 0)
        local td_borderbottom = tex.sp(td_contents["border-bottom"] or 0)
        local padding_left    = td_contents.padding_left   or self.padding_left_col[current_column]  or self.padding_left
        local padding_right   = td_contents.padding_right  or self.padding_right_col[current_column] or  self.padding_right
        local padding_top     = td_contents.padding_top    or self.padding_top
        local padding_bottom  = td_contents.padding_bottom or self.padding_bottom

        -- when we are on a skip-cell (because of a rowspan), we need to create an empty hbox
        while skiptable[current_row] and skiptable[current_row][current_column] do
            v = publisher.create_empty_hbox_with_width(self.colwidths[current_column])
            v = publisher.add_glue(v,"head",fill) -- otherwise we'd get an underfull box
            row[current_column] = node.vpack(v,rowheightarea[current_row],"exactly")
            current_column = current_column + 1
        end

        current_column_width = 0
        for s = current_column,current_column + colspan - 1 do
            if self.colwidths[s] == nil then
                err("Something went wrong with the number of columns in the table (typeset_row)")
            else
                current_column_width = current_column_width + self.colwidths[s]
            end
        end

        -- FIXME: use column_distances[i] instead of self.colsep
        current_column_width = current_column_width + ( colspan - 1 ) * self.colsep
        current_column = current_column + colspan - 1
        if rowspan > 1 then
            ht = td_contents.rowspan_internal.sum_ht
        else
            ht = rowheightarea[current_row]
        end

        local g = set_glue(nil,{width = padding_top})
        publisher.setprop(g,"origin","align_top")

        local valign = td_contents.valign or tr_contents.valign or self.valign[current_column]
        if valign ~= "top" then
            set_glue_values(g,{stretch = 2^16, stretch_order = 2})
        end

        local cell_start = g
        local current = node.tail(cell_start)

        local cell
        -- td_contents.cell can be nil if we have dynamic table head and foot
        if td_contents.cell then
            cell = td_contents.cell.head
            td_contents.cell.head = nil
            node.free(td_contents.cell)
        else
            local alignment = td_contents.align or tr_contents.align or self.align[current_column]
            cell = self:pack_cell(td_contents.objects,current_column_width - padding_left - padding_right - td_borderleft - td_borderright,alignment)
            cell = cell.head
        end
        -- The cell is a vlist with minimum height. We need to repack the contents of the
        -- cell in order to use the aligns and VSpaces in the table cell

        local tail = node.tail(cell_start)
        tail.next = cell
        cell.prev = tail

        local g = set_glue(nil,{width = padding_bottom})
        publisher.setprop(g,"origin","align_bottom")

        local valign = td_contents.valign or tr_contents.valign or self.valign[current_column]
        if valign ~= "bottom" then
            set_glue_values(g,{stretch = 2^16, stretch_order = 2})
        end

        node.insert_after(cell_start,node.tail(cell_start),g)

        vlist = node.vpack(cell_start,ht - td_bordertop - td_borderbottom,"exactly")
        --- The table cell now looks like this
        ---
        --- ![Table cell vertical](../img/tablecell1.svg)
        ---
        --- Now we need to add the left and the right glue
        g = set_glue(nil,{width = padding_left})

        cell_start = g
        local ht_border = 0
        rowspan = td_contents.rowspan or 1
        for i=1,rowspan do
            ht_border = ht_border + rowheightarea[current_row + i - 1] + self.rowsep
        end
        ht_border = ht_border - td_bordertop - td_borderbottom - self.rowsep

        if td_borderleft ~= 0 then
            local start = publisher.colorbar(td_borderleft,ht_border,0,td_contents["border-left-color"])
            local stop = node.tail(start)
            stop.next = g
            cell_start = start
        end

        current = node.tail(cell_start)
        current.next = vlist
        current = vlist

        g = set_glue(nil,{width = padding_right})

        current.next = g
        current = g
        if td_borderright ~= 0 then
            local rule = publisher.colorbar(td_borderright,ht_border,0,td_contents["border-right-color"])
            g.next = rule
        end

        hlist = node.hpack(cell_start,current_column_width,"exactly")
        --- The cell is now almost complete. We can set the background color and add the top and bottom rule.
        ---
        --- ![Table cell vertical](../img/tablecell2.svg)
        if tr_contents.backgroundcolor or td_contents.backgroundcolor or self.backgroundcolumncolors[current_column] then
            -- prio: Td.backgroundcolor, then Tr.backgroundcolor, then Column.backgroundcolor
            local color = self.backgroundcolumncolors[current_column]
            if tr_contents.backgroundcolor and tr_contents.backgroundcolor ~= "-" then
                color = tr_contents.backgroundcolor
            end
            if tr_contents.backgroundcolor == "-" then
                color = nil
            end
            if td_contents.backgroundcolor and td_contents.backgroundcolor ~= "-" then
                color = td_contents.backgroundcolor
            end
            if td_contents.backgroundcolor == "-" then
                color = nil
            end
            if color and color ~= "-" then
                hlist = publisher.background(hlist,color)
            end
        end

        local bg = td_contents["background-text"]
        if bg then
            local bgcolor  = td_contents["background-textcolor"] or "black"
            local angle    = td_contents["background-angle"]     or 0
            local bgsize   = td_contents["background-size"]      or "contain"
            local fontname = td_contents["background-font-family"]
            local ff = publisher.fonts.lookup_fontfamily_name_number[fontname]
            hlist = publisher.bgtext(hlist,bg,angle,bgcolor, ff or self.fontfamily,bgsize)
        end

        if td_contents.graphic then
            local _, x = metapost.prepareboxgraphic(hlist.width,hlist.height,td_contents.graphic)
            local x = node.hpack(x)
            x.width = 0
            x.height = 0
            hlist = node.insert_before(hlist,hlist,x)
            hlist = node.hpack(hlist)
        end


        local head = hlist
        if td_bordertop > 0 then
            local rule = publisher.colorbar(current_column_width,td_bordertop,0,td_contents["border-top-color"])
            -- rule is: whatsit, rule, whatsit
            node.tail(rule).next = hlist
            head = rule
        end

        if td_borderbottom > 0 then
            local rule = publisher.colorbar(current_column_width,td_borderbottom,0,td_contents["border-bottom-color"])
            hlist.next = rule
        end

        -- What is this for?
        local gl = set_glue(nil,{width = 0, shrink = 2^16, shrink_order = 2})
        node.slide(head).next = gl

        --- This is our table cell now:
        ---
        --- ![Table cell vertical](../img/tablecell3.svg)
        hlist = node.vpack(head,rowheightarea[current_row],"exactly")

        if publisher.options.showobjects then
            publisher.boxit(hlist)
        end

        row[#row + 1] = hlist

    end -- stop td

    if current_column == 0 then
        v = publisher.create_empty_hbox_with_width(self.tablewidth_target)
        v = publisher.add_glue(v,"head",fill) -- otherwise we get an underfull vbox
        row[1] = node.vpack(v,rowheightarea[current_row],"exactly")
    end


    --- We now add colsep and connect the cells so we have a list of vboxes and
    --- pack them in a hbox.
    --- ![a row](../img/tablerow.svg)
    -- FIXME: use column_distances[i] instead of self.colsep
    local cell_start,current
    cell_start = row[1]
    current = cell_start
    if row[1] then
        for z=2,#row do
            _,current = publisher.add_glue(current,"tail",{ width = self.colsep })
            if row[z] then
                current.next = row[z]
                current = row[z]
            end
        end
        row = node.hpack(cell_start)
    else
        err("(Internal error) Table is not complete.")
    end
    node.set_attribute(row,publisher.att_tr_shift_up,tr_contents.shiftup)
    node.set_attribute(row,publisher.att_use_as_head,tr_contents.sethead)
    return row
end

-- Gets called for each <Tablehead> element. second_run is for dynamic table head
local function make_tablehead(self,tr_contents,tablehead_first,tablehead,current_row,second_run)
    local current_tablehead_type
    if tr_contents.page == "first" then
        current_tablehead_type = tablehead_first
        if second_run ~= true then
            self.tablehead_first_contents = {tr_contents,current_row}
        end
    else
        current_tablehead_type = tablehead
        if second_run ~= true then
            self.tablehead_contents = {tr_contents,current_row}
        end
    end

    local tablearea = "tablehead" .. (tr_contents.page or "")

    for _,row in ipairs(tr_contents) do
        row_contents = publisher.element_contents(row)
        row_elementname = publisher.elementname(row)
        if row_elementname == "Tr" then
            current_row = current_row + 1
            current_tablehead_type[#current_tablehead_type + 1] = self:typeset_row(row_contents,current_row,self.skiptables[tablearea] or {},self.rowheights[tablearea])
        elseif row_elementname == "Tablerule" then
            tmp = publisher.colorbar(self.tablewidth_target,tex.sp(row_contents.rulewidth or "0.25pt"),0,row_contents.color,"tablerule")
            current_tablehead_type[#current_tablehead_type + 1] = node.hpack(tmp)
        end
    end
    if #current_tablehead_type == 0 then
        table.insert(current_tablehead_type,node.new("hlist"))
    end
    if self.rowsep ~= 0 then
        publisher.add_glue(current_tablehead_type[#current_tablehead_type], "tail", {width=self.rowsep})
    end

    return current_row
end

-- second run is for dynamic table foot
local function make_tablefoot(self,tr_contents,tablefoot_last,tablefoot,current_row,second_run)
    local current_tablefoot_type
    if tr_contents.page == "last" then
        current_tablefoot_type = tablefoot_last
        if second_run ~= true then
            self.tablefoot_last_contents = {tr_contents,current_row}
        end
    else
        current_tablefoot_type = tablefoot
        if second_run ~= true then
            self.tablefoot_contents = {tr_contents,current_row}
        end
    end
    for _,row in ipairs(tr_contents) do
        row_contents = publisher.element_contents(row)
        row_elementname = publisher.elementname(row)

        local tablearea = "tablefoot" .. (tr_contents.page or "")
        if row_elementname == "Tr" then
            current_row = current_row + 1
            current_tablefoot_type[#current_tablefoot_type + 1] = self:typeset_row(row_contents,current_row,self.skiptables[tablearea] or {},self.rowheights[tablearea])
        elseif row_elementname == "Tablerule" then
            tmp = publisher.colorbar(self.tablewidth_target,tex.sp(row_contents.rulewidth or "0.25pt"),0,row_contents.color,"tablerule")
            current_tablefoot_type[#current_tablefoot_type + 1] = node.hpack(tmp)
        end
    end
    if #current_tablefoot_type == 0 then
        table.insert(current_tablefoot_type,node.new("hlist"))
    end

    return current_row
end
--------------------------------------------------------------------------

-- TODO: rename function: we don't calculate the height here
local function calculate_height_and_connect_tablehead(self,tablehead_first,tablehead)
    -- We connect all but the last row with the next row and remember the height in ht_header
    for z = 1,#tablehead_first - 1 do
        _,tmp = publisher.add_glue(tablehead_first[z],"tail",{ width = self.rowsep })
        tmp.next = tablehead_first[z+1]
        tablehead_first[z+1].prev = tmp
    end

    for z = 1,#tablehead - 1 do
        _,tmp = publisher.add_glue(tablehead[z],"tail",{ width = self.rowsep })
        tmp.next = tablehead[z+1]
        tablehead[z+1].prev = tmp
    end
end

local function calculate_height_and_connect_tablefoot(self,tablefoot,tablefoot_last)
    local ht_footer, ht_footer_last = 0, 0
    for z = 1,#tablefoot - 1 do
        ht_footer = ht_footer + tablefoot[z].height  -- Tr or Tablerule
        -- if we have a rowsep then add glue. Todo: make a if/then/else conditional
        _,tmp = publisher.add_glue(tablefoot[z],"tail",{ width = self.rowsep })
        tmp.next = tablefoot[z+1]
        tablefoot[z+1].prev = tmp
    end

    for z = 1,#tablefoot_last - 1 do
        ht_footer_last = ht_footer_last + tablefoot_last[z].height  -- Tr or Tablerule
        -- if we have a rowsep then add glue. Todo: make a if/then/else conditional
        _,tmp = publisher.add_glue(tablefoot_last[z],"tail",{ width = self.rowsep })
        tmp.next = tablefoot_last[z+1]
        tablefoot_last[z+1].prev = tmp
    end

    if #tablefoot > 0 then
        ht_footer = ht_footer + tablefoot[#tablefoot].height + #tablefoot * self.rowsep
    end

    if #tablefoot_last > 0 then
        ht_footer_last = ht_footer_last + tablefoot_last[#tablefoot_last].height + #tablefoot_last * self.rowsep
    else
        ht_footer_last = ht_footer
    end
    return ht_footer, ht_footer_last
end


-- This is called for Td/sethead=yes for the copies
-- of the first head. It removes the pdf_dest nodes for bookmark destinations.
function remove_bookmark_nodes( nodelist )
    local head = nodelist
    while head do
        if head.id == publisher.hlist_node or head.id == publisher.vlist_node then
            head.list = remove_bookmark_nodes(head.list)
        elseif head.id == publisher.whatsit_node and head.subtype == publisher.pdf_dest_whatsit then
            node.flush_list(head)
            return nil
        end
        head = head.next
    end
    return nodelist
end

function typeset_table(self)
    local current_row
    local tablehead_first = {}
    local tablehead = {}
    local tablefoot_last = {}
    local tablefoot = {}
    -- omit_head_on_pages is for dynamic headers (2)
    local omit_head_on_pages = {}
    local rows = {}
    local break_above = true
    local filter = {}
    local startpage = publisher.current_pagenumber
    local tablepart_absolute = 1

    current_row = 0
    for _,tr in ipairs(self.tab) do
        local tr_contents = publisher.element_contents(tr)
        local eltname   = publisher.elementname(tr)
        local tmp
        -- If this row is allowed to break above
        -- Will be set to false if break_below is "no"

        if eltname == "Columns" then
            -- ignore
        elseif eltname == "Tablerule" then
            local offset = 0
            if tr_contents.start and tr_contents.start ~= 1 then
                local sum = 0
                for i=1,tr_contents.start - 1 do
                    sum = sum + self.colwidths[i]
                end
                offset = sum
            end
            tmp = publisher.colorbar(self.tablewidth_target - offset,tex.sp(tr_contents.rulewidth or "0.25pt"),0,tr_contents.color,"tablerule")
            tmp = publisher.add_glue(tmp,"head",{width = offset})
            tmp = node.hpack(tmp)
            publisher.setprop(tmp,"origin","tablerule")
            rows[#rows + 1] = tmp
            if break_above == false then
                if publisher.options.showobjects then
                    rows[#rows] = publisher.addhrule(rows[#rows])
                end
                node.set_attribute(rows[#rows],publisher.att_break_above,1)
                break_above = true
            end
            if tr_contents.breakbelow == false then
                break_above = false
            end

        elseif eltname == "Tablehead" then
            make_tablehead(self,tr_contents,tablehead_first,tablehead,current_row)
            if tr_contents.page == "first" then
                filter.tablehead_force_first = true
            elseif tr_contents.page == "odd" or tr_contents.page == "even" then
                filter.tablehead = tr_contents.page
            elseif tr_contents.page == "all" then
                filter.tablehead = "none"
            end

        elseif eltname == "Tablefoot" then
            make_tablefoot(self,tr_contents,tablefoot_last,tablefoot,0)
        elseif eltname == "Tr" then
            current_row = current_row + 1
            rows[#rows + 1] = self:typeset_row(tr_contents,current_row,self.skiptables.body,self.rowheights.body)
            -- We allow data to be attached to a table row.
            if tr_contents.data then
                dynamic_data[#dynamic_data + 1] = tr_contents.data
                node.set_attribute(rows[#rows],publisher.att_tr_dynamic_data,#dynamic_data)
            end
            node.set_attribute(rows[#rows],publisher.att_is_table_row,1)

            if break_above == false then
                if publisher.options.showobjects then
                    rows[#rows] = publisher.addhrule(rows[#rows])
                end
                node.set_attribute(rows[#rows],publisher.att_break_above,1)
                break_above = true
            end

            if tr_contents["top-distance"] ~= 0 then
                node.set_attribute(rows[#rows],publisher.att_space_amount,tr_contents["top-distance"])
            end
            if tr_contents["break-below"] == "no" then
                node.set_attribute(rows[#rows],publisher.att_break_below_forbidden,1)
                break_above = false
            end
        elseif eltname == "TableNewPage" then
            if publisher.current_group == nil then
                local tf = node.new("hlist")
                node.set_attribute(tf,publisher.att_tablenewpage, 1)
                rows[#rows + 1] = tf
            else
                warning("TableNewPage does not work in Group")
            end
        else
            warning("Unknown contents in “Table” %s",eltname or "?" )
        end -- if it's a table cell
    end

    if #rows == 0 then
        warning("table without contents")
        return publisher.empty_block()
    end

    -- I used to have a metatable with __index here, but this gives a stack overflow
    -- for large indexes
    local tableheads_extra = {
        largest_index = 0
    }
    local function get_tableheads_extra( idx, maxrow )
        -- maxrow = maxrow or
        idx = idx - 1
        if idx < 1 then return nil end
        local maxidx = tableheads_extra.largest_index
        local id = math.min(idx,maxidx)
        if tableheads_extra[id] ~= nil then
            local subidx = #tableheads_extra[id]
            if maxrow == nil then
                return tableheads_extra[id][subidx].nodelist
            end
            local entry
            while subidx > 0 do
                entry = tableheads_extra[id][subidx]
                if entry.rownumber <= maxrow then
                    return entry.nodelist
                end
                subidx = subidx - 1
            end
            return get_tableheads_extra(id  , maxrow)
        end
        if idx == 1 then return nil end
        return get_tableheads_extra(idx)
    end

    local function set_tableheads_extra( idx, nodelist, rownumber )
        -- nodelist is a copied list, but the pdf_dest whatsits must not
        -- go into the output.
        remove_bookmark_nodes(nodelist)
        tableheads_extra.largest_index = math.max( tableheads_extra.largest_index , idx )
        tableheads_extra[idx] = tableheads_extra[idx] or {}
        tableheads_extra[idx][#tableheads_extra[idx] + 1]  = { nodelist = nodelist, rownumber = rownumber }
    end

    calculate_height_and_connect_tablehead(self,tablehead_first,tablehead)
    local ht_footer,  ht_footer_last = calculate_height_and_connect_tablefoot(self,tablefoot,tablefoot_last)

    if not tablehead[1] then
        tablehead[1] = node.new("hlist") -- empty tablehead
    end
    if not tablehead_first[1] then
        tablehead_first[1] = node.copy_list(tablehead[1])
    end
    if not tablefoot[1] then
        tablefoot[1] = node.new("hlist") -- empty tablefoot
    end
    if not tablefoot_last[1] then
        tablefoot_last[1] = node.copy_list(tablefoot[1])
    end

    local ht_current = self.options.current_height or self.options.ht_max
    local ht_max     = self.options.ht_max
    -- The maximum heights are saved here for each table. Currently all tables must have the same height (see the metatable)
    local pagegoals = {}

    -- Return a boolean if we need to show the static header on this page
    local function showheader_static( tablepart )
        if tablepart_absolute == 1 and filter.tablehead_force_first then return true end
        if filter.tablehead == nil then return false end
        if filter.tablehead == "none" then return true end
        if math.fmod(tablepart_absolute,2) == math.fmod(startpage,2) then
            if filter.tablehead == "odd" then
                return true
            else
                return false
            end
        else
            if filter.tablehead == "odd" then
                return false
            else
                return true
            end
        end
    end

    -- Return a boolean if we need to show the dynamic header on this page
    local function showheader( tablepart, rowmax )
        -- We can skip the dynamic header on pages where the first line is the next dynamic header
        if omit_head_on_pages[tablepart] then return false end

        if get_tableheads_extra(tablepart_absolute,rowmax) ~= nil then return true end
        return false
    end


    --- Table splitting
    --- ===============
    --- Table splitting is done in several steps and we need helper functions to generate the dynamic headers
    --- and to get the height of these headers
    local function get_height_header(i)
        local ht = 0
        if showheader_static(i) then
            if i == 1 then
                local x = node.vpack(tablehead_first[1])
                ht = x.height
            else
                local x = node.vpack(tablehead[1])
                ht = x.height
            end
        end
        if showheader(i) then
            ht = ht + get_tableheads_extra(i).height + self.rowsep
        end
        return ht
    end

    local maxpages = 0

    setmetatable(pagegoals, { __index = function(tbl,idx)
                local footerheight = ht_footer
                if idx == maxpages then
                    footerheight = ht_footer_last
                end
                local ht_head = get_height_header(idx)
                local val
                if idx == 1 then
                    val = ht_current - ht_head - footerheight
                    return val
                elseif idx == -1 then
                    val = ht_current - ht_head - footerheight
                    return val
                else
                    if self.getheight then
                        -- self.getheight is a function which expects a relative
                        -- page number (1 = first page of table, 2 = second page of table...)
                        -- The function might return nil, if it doesn't have enough information
                        -- to obtain the max height
                        local ht = self.getheight(idx)
                        if ht then
                            val = ht - ht_head - footerheight
                            tbl[idx] = val
                            return val
                        end
                    end
                    val = ht_max - ht_head - footerheight
                end
                return val
    end})


    local function get_tablehead( page,maxrow )
        local nl = get_tableheads_extra(page,maxrow)
        if nl then
            return node.copy_list(nl)
        end
        local tmp = node.new("hlist")
        return tmp
    end


    local function get_tablehead_static( page )
        if page == 1 then
            return tablehead_first[1]
        end
        return node.copy_list(tablehead[1])
    end

    -- When we split the current table we return an array:
    local final_split_tables = {}
    local pagegoal = 0

    local ht_row,space_above,too_high
    --- splits is a table which includes the number of the rows each page has in a multi-page table
    ---
    ---     splits = {
    ---       [1] = "0"
    ---       [2] = "26"
    ---       [3] = "44"
    ---     }

    local splits

    local function calculate_splits()
        local current_page = 1
        local last_possible_split_is_after_line = 0
        local accumulated_height = 0
        local extra_height = 0

        splits = {0}
        for i=1,#rows do
            -- We can mark a row as "use_as_head" to turn the row into a dynamic head
            local use_as_head = node.has_attribute(rows[i],publisher.att_use_as_head)
            if use_as_head == 1 then
                set_tableheads_extra(#splits,node.copy(rows[i]),i)
            elseif use_as_head == 2 then
                set_tableheads_extra(#splits,publisher.create_empty_hbox_with_width(1),i)
            end
            local shiftup = node.has_attribute(rows[i],publisher.att_tr_shift_up) or 0
            if shiftup > 0 then
                rows[i].height = rows[i].height - shiftup
            end
            pagegoal = pagegoals[current_page]
            ht_row = rows[i].height + rows[i].depth
            break_above = node.has_attribute(rows[i],publisher.att_break_above) or -1
            space_above = node.has_attribute(rows[i],publisher.att_space_amount) or 0

            local break_above_allowed = break_above ~= 1

            if break_above_allowed then
                last_possible_split_is_after_line = i - 1
                accumulated_height = accumulated_height + extra_height
                extra_height = 0
            end
            extra_height = extra_height + ht_row

            -- This should be turned on with a separate switch in trace
            -- if publisher.options.showobjects then
            --     local ht = tostring(sp_to_pt(ht_row)) .. "|" .. tostring(sp_to_pt(accumulated_height)) .. "|" .. tostring(sp_to_pt(extra_height))
            --     rows[i] = publisher.showtextatright(rows[i],ht)
            -- end
            local tablenewpage = node.has_attribute(rows[i],publisher.att_tablenewpage)

            local fits_in_table = accumulated_height + extra_height + space_above <= pagegoal
            if tablenewpage or not fits_in_table then
                if node.has_attribute(rows[i],publisher.att_use_as_head) == 1 then
                    -- the next line would be used as a header, so let's skip the
                    -- header on this page
                    omit_head_on_pages[#splits + 1] = true
                end

                if shiftup > 0 then
                    rows[i].height = rows[i].height + shiftup
                end
                -- ==0 can happen when there's not enough room for table head + first line
                if last_possible_split_is_after_line ~= 0 then
                    if node.has_attribute(rows[last_possible_split_is_after_line + 1],publisher.att_use_as_head) == 1 then
                        omit_head_on_pages[#splits + 1] = true
                    end
                    splits[#splits + 1] = last_possible_split_is_after_line
                    tablepart_absolute = tablepart_absolute + 1
                else
                    startpage = startpage + 1
                end
                accumulated_height = ht_row
                extra_height = self.rowsep + extra_height - ht_row
                current_page = current_page + 1
            else
                -- if it is not the first row in a table,
                -- add space_above
                if i ~= splits[#splits] + 1 then
                    extra_height = extra_height + space_above
                end
            end
            extra_height = extra_height + self.rowsep
        end
    end

    calculate_splits()
    -- If there is a longer last footer than the other footers, we need to re-calculate
    -- the splitting. The last table foot can be too high. See #268.
    if ht_footer_last > 0 and ht_footer_last > ht_footer then
        maxpages = #splits
        tablepart_absolute = 1
        startpage = publisher.current_pagenumber
        calculate_splits()
    end

    -- This is the last split
    splits[#splits + 1] = #rows

    --- Table balancing
    --- ===============
    --- When the user has requested table balancing, we need to find out how many frames
    --- the table spans. If there is only one frame, no balancing has to be done.
    --- If there are more frames, we need to find out the “empty” frames.

    -- tosplit is the total number of frames on the last page (used or unused)
    local tosplit = self.split

    -- tosplit > 1 ==> needs balancing (otherwise only one frame or no splitting)
    if tosplit > 1 then
        -- used_frames is the number of frames used by the table w/o split.
        local used_frames = ( #splits - 1 ) % tosplit
        -- This can be 0 (all columns used).
        -- So the number is set to the amount of tosplit in order to balance all columns.
        if used_frames == 0 then used_frames = tosplit end

        -- Now that we know the #frames to be split, we can count the lines.
        -- Remember: the split table looks like this:
        --     splits = {
        --       [1] = "0"
        --       [2] = "26"
        --       [3] = "44"
        --     }
        -- Where 44 is the total number of rows. This has to be the last entry in the splits table.
        -- Each entry means that there is a split after that line. So in the example above,
        -- line 26 is in the first frame, 27 to 44 in the last frame.
        local last_possible_split_is_after_line_t = {}
        -- first, we remove the split marks for the used frames.
        -- (If we omitted the rest of the balance routine, the resulting table would be empty for that page.)
        for i=1,used_frames  do
            -- the entry in omit_head_on_pages for this split is not valid anymore
            omit_head_on_pages[#splits] = nil
            table.remove(splits)
        end

        -- first row is needed for height calculation
        local first_row_in_new_table = splits[#splits] + 1

        -- Now this is the total height of the remaining rows.
        -- We need to take the dynamic headers into account (TODO).
        local sum_ht = 0
        for i = first_row_in_new_table, #rows  do
            sum_ht = sum_ht + rows[i].height + rows[i].depth
        end

        -- percolumn_goal is the optimum height for each column
        local percolumn_goal = math.ceil( sum_ht / tosplit )
        local sum_frame = 0
        local break_below_allowed
        local maxht = ht_current
        for i = first_row_in_new_table, #rows do
            break_below_allowed = ( node.has_attribute(rows[i],publisher.att_break_below_forbidden) ~= 1)
            if break_below_allowed then
                last_possible_split_is_after_line_t[#last_possible_split_is_after_line_t + 1] = i
            end
            sum_frame = sum_frame + rows[i].height + rows[i].depth

            if #splits > tosplit then
                -- ht_current must be replaced with ht_max on following pages
                maxht = ht_max
            end
            if sum_frame > maxht then
                splits[#splits + 1] = last_possible_split_is_after_line_t[#last_possible_split_is_after_line_t - 1]
                tosplit = tosplit - 1

                -- When there is more than one column left, we should adjust the percolumn_goal. (should we?)
                if tosplit > 0 then
                    percolumn_goal = percolumn_goal - math.ceil( (sum_frame - percolumn_goal )  / tosplit )
                end
                sum_frame = 0
            -- When stepped over the goal, move this line to the next frame.
            -- See #232 for a situation where the second test is necessary.
            elseif sum_frame >= percolumn_goal and last_possible_split_is_after_line_t[#last_possible_split_is_after_line_t] ~= splits[#splits] then
                splits[#splits + 1] = last_possible_split_is_after_line_t[#last_possible_split_is_after_line_t]
                tosplit = tosplit - 1

                -- When there is more than one column left, we should adjust the percolumn_goal. (should we?)
                if tosplit > 0 then
                    percolumn_goal = percolumn_goal - math.ceil( (sum_frame - percolumn_goal )  / tosplit )
                end
                sum_frame = 0
            end
        end

        -- Add the last row to the splits table, unless by coincidence the
        -- split has already done that.
        if splits[#splits] ~= #rows then
            splits[#splits + 1] = #rows
        end

        -- When the last column has exacly one table rule, this rule
        -- gets moved to the previous column
        if #splits > 1 and splits[#splits] - splits[#splits - 1] == 1 then
            local istablerule = publisher.getprop(rows[#rows],"origin") == "tablerule"
            if istablerule then
                splits[#splits - 1] = splits[#splits]
                table.remove(splits)
            end
        end
    end

    --- Table cleanup. This is for dynamic headers which get repeated on the top of
    --- each split. We omit the repetition, if the top entry in a frame is already
    --- a dynamic head.
    for i=2,#splits - 1 do
        r = splits[i]
        if rows[r+1] then
            if node.has_attribute(rows[r + 1],publisher.att_use_as_head) == 1 then
                omit_head_on_pages[i] = true
            end
        else
            -- no head in last column
            omit_head_on_pages[i] = true
        end
    end

    local first_row_in_new_table
    local last_tr_data
    tablepart_absolute = 0
    for s=2,#splits do
        tablepart_absolute = tablepart_absolute + 1
        publisher.xpath.set_variable("_last_tr_data",nil)
        first_row_in_new_table = splits[s-1] + 1

        thissplittable = {}
        final_split_tables[#final_split_tables + 1] = thissplittable

        -- only reformat head when we have a head
        if last_tr_data and self.tablehead_contents then
            -- we have some data attached to table rows, so we re-format the header
            local val = dynamic_data[last_tr_data]
            publisher.xpath.set_variable("_last_tr_data",val)
            local tmp1,tmp2 = reformat_head(self,s - 1)
            if s == 2 then
                -- first page
                thissplittable[#thissplittable + 1] = node.copy_list(tmp1)
            else
                -- page > 1
                thissplittable[#thissplittable + 1] = node.copy_list(tmp2)
            end
        else
            if showheader_static(s-1) then
                thissplittable[#thissplittable + 1] = get_tablehead_static(s-1)
            end
            if showheader(s-1, splits[s]) then
                thissplittable[#thissplittable + 1] = get_tablehead(s-1, splits[s - 1])
            end
        end

        for i = first_row_in_new_table,splits[s]  do
            if i > first_row_in_new_table then
                space_above = node.has_attribute(rows[i],publisher.att_space_amount) or 0
            else
                space_above = 0
            end
            thissplittable[#thissplittable + 1] = publisher.make_glue({ width = space_above})
            thissplittable[#thissplittable + 1] = rows[i]
            -- the last rowsep at the end of a split should be omitted.
            if ( i < #rows and i < splits[s] ) or self.tablefoot_contents then
                thissplittable[#thissplittable + 1] = publisher.make_glue({width = self.rowsep})
            end
        end

        last_tr_data = thissplittable[#thissplittable - 1] and node.has_attribute(thissplittable[#thissplittable - 1],publisher.att_tr_dynamic_data)

        -- only reformat the foot when we have dynamic data _and_ have a foot to reformat.
        if last_tr_data and self.tablefoot_contents then
            -- we have some data attached to table rows, so we re-format the footer
            local val = dynamic_data[last_tr_data]
            publisher.xpath.set_variable("_last_tr_data",val)
            local tmp_tablefoot_last,tmp_tablefoot_all = reformat_foot(self,s - 1,#splits - 1)
            if s < #splits then
                thissplittable[#thissplittable + 1] = node.copy_list(tmp_tablefoot_all)
            else
                thissplittable[#thissplittable + 1] = node.copy_list(tmp_tablefoot_last or tmp_tablefoot_all)
            end
        else
            -- no dynamic data, no re-formatting
            if s < #splits then
                thissplittable[#thissplittable + 1] = node.copy_list(tablefoot[1])
            else
                thissplittable[#thissplittable + 1] = node.copy_list(tablefoot_last[1])
            end
        end
    end

    -- now connect the entries in the split_tables
    local tail
    for i=1,#final_split_tables do
        for j=1,#final_split_tables[i] - 1 do
            tail = node.tail(final_split_tables[i][j])
            tail.next = final_split_tables[i][j+1]
            final_split_tables[i][j+1].prev = tail
        end
        final_split_tables[i] = node.vpack(final_split_tables[i][1])
    end
    return final_split_tables
end -- typeset table

function reformat_foot( self,pagenumber,max_splits)
    local rownumber,y
    if pagenumber == max_splits and self.tablefoot_last_contents then
        y         = self.tablefoot_last_contents[1]
        rownumber = self.tablefoot_last_contents[2]
    else
        y         = self.tablefoot_contents[1]
        rownumber = self.tablefoot_contents[2]
    end
    local x = publisher.dispatch(y._layoutxml,y._dataxml)
    local page = publisher.read_attribute(y._layoutxml,y._dataxml,"page","string","all")
    x.page = page
    attach_objects(self, x)
    local tmp_tablefoot_last,tmp_tablefoot_all = {},{}
    make_tablefoot(self,x,tmp_tablefoot_last,tmp_tablefoot_all,rownumber,true)
    calculate_height_and_connect_tablefoot(self,tmp_tablefoot_last,tmp_tablefoot_all)
    return tmp_tablefoot_last[1],tmp_tablefoot_all[1]
end

function reformat_head( self,pagenumber)
    local y = self.tablehead_contents[1]
    local rownumber = self.tablehead_contents[2]
    local x = publisher.dispatch(y._layoutxml,y._dataxml)
    attach_objects( self, x)
    local tmp1,tmp2 = {}, {}
    local page = publisher.read_attribute(y._layoutxml,y._dataxml,"page","string","all")
    x.page = page
    make_tablehead(self,x,tmp1,tmp2,rownumber,true)
    calculate_height_and_connect_tablehead(self,tmp1,tmp2)
    return tmp1[1],tmp2[1]
end

function set_skip_table_elt(tr_contents,curskiptable,current_row)
    local rowspan
    local colspan
    local current_column

    current_column = 0
    for _,td in ipairs(tr_contents) do
        current_column = current_column + 1

        -- There might be a rowspan from the row above, so we need to find the correct column
        while curskiptable[current_row] and curskiptable[current_row][current_column] do
            current_column = current_column + 1
        end

        local td_contents = publisher.element_contents(td)
        rowspan = tonumber(td_contents.rowspan) or 1
        colspan = tonumber(td_contents.colspan) or 1

        for z = current_row + 1, current_row + rowspan - 1 do
            for y = current_column, current_column + colspan - 1 do
                curskiptable[z] = curskiptable[z] or {}
                curskiptable[z][y] = true
            end
        end
        while curskiptable[current_row] and curskiptable[current_row][current_column] do
            current_column = current_column + 1
        end
        current_column = current_column + colspan - 1
    end
end


function set_skip_table( self )
    self.skiptables={ body = { name = "body"}, tablehead = { name = "tablehead"}, tablefoot = { name = "tablefoot"}}
    local curskiptable
    local rowcounter = {}
    local current_row_body = 0
    local current_row_head = 0
    for _,tr in ipairs(self.tab) do
        local tr_contents = publisher.element_contents(tr)
        local eltname = publisher.elementname(tr)
        local page = tr_contents.page or ""
        if eltname == "Tr" then
            current_row_body = current_row_body + 1
            set_skip_table_elt(tr_contents,self.skiptables.body,current_row_body)
        elseif eltname == "Tablehead" or eltname == "Tablefoot" then
            local tablearea
            if eltname == "Tablehead" then tablearea = "tablehead" else tablearea = "tablefoot" end
            tablearea = tablearea .. (tr_contents.page or "")
            rowcounter[tablearea] = 0
            self.skiptables[tablearea] = self.skiptables[tablearea] or { name = self.skiptables[tablearea]}
            for _,tr_inner in ipairs(tr_contents) do
                local inner_eltname = publisher.elementname(tr_inner)
                local inner_contents = publisher.element_contents(tr_inner)
                if inner_eltname == "Tr" then
                    rowcounter[tablearea] = rowcounter[tablearea] + 1
                    set_skip_table_elt(inner_contents,self.skiptables[tablearea],rowcounter[tablearea])
                end
            end
        end
    end
    -- body
end

function make_table( self )
    setmetatable(self.column_distances,{ __index = function() return self.colsep or 0 end })
    set_skip_table(self)
    collect_alignments(self)
    attach_objects(self, self.tab)
    if calculate_columnwidth(self) ~= nil then
        err("Cannot print table")
        local x = node.new("vlist")
        return x
    end

    calculate_rowheights(self)
    publisher.xpath.set_variable("_last_tr_data","")
    return typeset_table(self)
end

file_end("tabular.lua")

