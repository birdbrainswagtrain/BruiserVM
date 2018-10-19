local image = file.Read("glua86/fbird.img")

print("=============================>")

local mem_size = 0x100000
local mem_raw = {}
for i=0,mem_size/4 do
    mem_raw[i] = 0
end

local mem8 = setmetatable({},{
    __index=function(t,i)
        return bit.band(0xFF,bit.rshift(mem_raw[bit.rshift(i,2)],bit.band(i,3)*8))
    end,
    __newindex=function(t,i,v)
        local mask = bit.bnot(bit.lshift(0xFF,bit.band(i,3)*8))
        mem_raw[bit.rshift(i,2)] = 
            bit.band(mem_raw[bit.rshift(i,2)],mask) +
            bit.lshift(bit.band(0xFF,v),bit.band(i,3)*8)
    end
})

local mem16 = setmetatable({},{
    __index=function(t,i)
        return mem8[i]+mem8[i+1]*256
    end
})

local function sign8(x)
    if x>127 then return x-256 end
    return x
end

local function sign16(x)
    if x>32767 then return x-65536 end
    return x
end

for i=1,#image do
    local byte = string.byte(image,i)
    mem8[0x7c00+i-1] = byte
end

--[[for i=0x7c00/4,0x7c20/4 do
    print(string.format("%x %x %x",mem_raw[i],mem8[i*4],mem8[i*4+1]))
end]]

local cpu = {
    mem8 = mem8,
    mem16 = mem16,
    f_dir = 1,
    get_flags = nil,
    set_flags = nil,
    r8 = nil,
    r16 = nil,
    seg = nil
}

local function get_seg(i)
    local seg_lut = {
        [0]="cpu.seg_e",
        [1]="cpu.code",
        [2]="stack",
        [3]="data",
        [4]="cpu.seg_f",
        [5]="cpu.seg_g"
    }
    return seg_lut[i]
end

local function modrm(pc,reg_type,width)
    local x = mem8[pc]
    local mod = bit.rshift(x, 6)
    local reg = bit.band(7,bit.rshift(x, 3))
    local rm = bit.band(7,x)

    local reg_result
    
    if reg_type then
        if reg_type=="seg" then
            reg_result = get_seg(reg)..".offset"
        else
            reg_result = reg_type.."["..reg.."]"
        end
    else
        reg_result=reg
    end

    if mod==0 and rm==6 then
        return reg_result,"data"..width.."["..mem16[pc+1].."]",3
    elseif mod==3 then
        return reg_result, "r"..width.."["..rm.."]",1
    else
        local offset=0
        local len=1
        if mod==1 then
            offset = sign8(mem8[pc+1])
            len=2
        elseif mod==2 then
            offset = sign16(mem16[pc+1])
            len=3
        end

        if offset ~= 0 then
            offset="+"..offset
        else
            offset=""
        end

        local rm_result = "-------------------------->bad"..rm

        if rm==0 then
            rm_result = "data"..width.."[r16[3]+r16[6]"..offset.."]"
        elseif rm==5 then
            rm_result = "data"..width.."[r16[7]"..offset.."]"
        end

        return reg_result,rm_result,len
    end
end

local function push_reg_16(pc)
    return {
        code="r16[4]=r16[4]-2 ; stack16[r16[4]] = r16["..bit.band(7,mem8[pc]).."]",
        len=1
    }
end

local function pop_reg_16(pc)
    return {
        code="r16["..bit.band(7,mem8[pc]).."] = stack16[r16[4]] ; r16[4]=r16[4]+2",
        len=1
    }
end

local function mov_reg_8(pc)
    return {
        code="r8["..bit.band(7,mem8[pc]).."]="..mem8[pc+1],
        len=2
    }
end

local function mov_reg_16(pc)
    return {
        code="r16["..bit.band(7,mem8[pc]).."]="..mem16[pc+1],
        len=3
    }
end

local function xchg_reg_16(pc)
    local other_reg = "r16["..bit.band(7,mem8[pc]).."]"
    return {
        code="do local tmp=r16[0] ; r16[0]="..other_reg.." ; "..other_reg.."=tmp end",
        len=1
    }
end

local op_handlers = {
    [0x02]=function(pc)
        local reg,rm,len = modrm(pc+1,"r8",8)
        return {
            code=reg.."=status("..reg.."+"..rm..",8)",
            len=1+len
        }
    end,
    [0x09]=function(pc)
        local reg,rm,len = modrm(pc+1,"r16",16)
        return {
            code=rm.."=status(bit.bor("..reg..","..rm.."),16)",
            len=1+len
        }
    end,
    [0x0C]=function(pc)
        local val = mem8[pc+1]
        return {
            code="r8[0]=status(bit.bor(r8[0],"..val.."),8)",
            len=2
        }
    end,
    [0x24]=function(pc)
        local val = mem8[pc+1]
        return {
            code="r8[0]=status(bit.band(r8[0],"..val.."),8)",
            len=2
        }
    end,

    [0x31]=function(pc)
        local reg,rm,len = modrm(pc+1,"r16",16)
        return {
            code=reg.."=status(bit.bxor("..reg..","..rm.."),16)",
            len=1+len
        }
    end,
    [0x3C]=function(pc)
        return {
            code="status(r8[0]- "..sign8(mem8[pc+1])..",8)",
            len=2
        }
    end,

    [0x50]=push_reg_16,
    [0x51]=push_reg_16,
    [0x52]=push_reg_16,
    [0x53]=push_reg_16,
    [0x54]=push_reg_16,
    [0x55]=push_reg_16,
    [0x56]=push_reg_16,
    [0x57]=push_reg_16,

    [0x58]=pop_reg_16,
    [0x59]=pop_reg_16,
    [0x5A]=pop_reg_16,
    [0x5B]=pop_reg_16,
    [0x5C]=pop_reg_16,
    [0x5D]=pop_reg_16,
    [0x5E]=pop_reg_16,
    [0x5F]=pop_reg_16,

    [0x72]=function(pc)
        return {
            jmp_addr= pc+sign8(mem8[pc+1])+2,
            jmp_cond= "cpu.f_carry",
            len=2
        }
    end,
    [0x74]=function(pc)
        return {
            jmp_addr= pc+sign8(mem8[pc+1])+2,
            jmp_cond= "cpu.f_zero",
            len=2
        }
    end,
    [0x75]=function(pc)
        return {
            jmp_addr= pc+sign8(mem8[pc+1])+2,
            jmp_cond= "not cpu.f_zero",
            len=2
        }
    end,


    [0x80]=function(pc)
        local reg,rm,len = modrm(pc+1,nil,8)

        if reg==0 then
            return {
                code=rm.."=status("..rm.."+"..sign8(mem8[pc+len+1])..",8)",
                len=2+len
            }
        elseif reg==7 then
            return {
                code="status("..rm.."- "..sign8(mem8[pc+len+1])..",8)",
                len=2+len
            }
        else
            error("80:"..reg)
        end
    end,
    [0x81]=function(pc)
        local reg,rm,len = modrm(pc+1,nil,16)

        if reg==0 then
            return {
                code=rm.."=status("..rm.."+"..sign16(mem16[pc+len+1])..",16)",
                len=3+len
            }
        elseif reg==5 then
            return {
                code=rm.."=status("..rm.."- "..sign16(mem16[pc+len+1])..",16)",
                len=3+len
            }
        elseif reg==7 then
            return {
                code="status("..rm.."- "..sign16(mem16[pc+len+1])..",16)",
                len=3+len
            }
        else
            error("81:"..reg)
        end
    end,
    [0x83]=function(pc)
        local reg,rm,len = modrm(pc+1,nil,16)

        if reg==0 then
            return {
                code=rm.."=status("..rm.."+"..sign8(mem8[pc+len+1])..",16)",
                len=2+len
            }
        elseif reg==5 then
            return {
                code=rm.."=status("..rm.."- "..sign8(mem8[pc+len+1])..",16)",
                len=2+len
            }
        elseif reg==7 then
            return {
                code="status("..rm.."- "..sign8(mem8[pc+len+1])..",16)",
                len=2+len
            }
        else
            error("83:"..reg)
        end
    end,

    [0x88]=function(pc)
        local reg,rm,len = modrm(pc+1,"r8",8)
        return {
            code=rm.."="..reg,
            len=1+len
        }
    end,
    [0x8A]=function(pc)
        local reg,rm,len = modrm(pc+1,"r8",8)
        return {
            code=reg.."="..rm,
            len=1+len
        }
    end,
    [0x8E]=function(pc)
        local reg,rm,len = modrm(pc+1,"seg",16)
        return {
            code=reg.."="..rm.."*16",
            len=1+len
        }
    end,

    [0x90]=xchg_reg_16,
    [0x91]=xchg_reg_16,
    [0x92]=xchg_reg_16,
    [0x93]=xchg_reg_16,
    [0x94]=xchg_reg_16,
    [0x95]=xchg_reg_16,
    [0x96]=xchg_reg_16,
    [0x97]=xchg_reg_16,

    [0x9C]=function(pc)
        return {
            code="r16[4]=r16[4]-2 ; stack16[r16[4]] = cpu.get_flags()",
            len=1
        }
    end,
    
    [0x9D]=function(pc)
        return {
            code="cpu.set_flags(stack16[r16[4]]) ; r16[4]=r16[4]+2",
            len=1
        }
    end,

    [0xA0]=function(pc)
        local addr = mem16[pc+1]
        return {
            code="r8[0]=data8["..addr.."]",
            len=3
        }
    end,
    [0xA1]=function(pc)
        local addr = mem16[pc+1]
        return {
            code="r16[0]=data16["..addr.."]",
            len=3
        }
    end,
    [0xA2]=function(pc)
        local addr = mem16[pc+1]
        return {
            code="data8["..addr.."]=r8[0]",
            len=3
        }
    end,
    [0xA3]=function(pc)
        local addr = mem16[pc+1]
        return {
            code="data16["..addr.."]=r16[0]",
            len=3
        }
    end,

    -- stos
    [0xAA]=function(pc)
        return {
            code="cpu.seg_e[r16[7]]=r16[0] ; r16[7]=r16[7]+cpu.f_dir",
            len=1
        }
    end,
    [0xAB]=function(pc)
        return {
            code="cpu.seg_e[r16[7]]=r16[0] ; r16[7]=r16[7]+2*cpu.f_dir",
            len=1
        }
    end,

    [0xB0]=mov_reg_8,
    [0xB1]=mov_reg_8,
    [0xB2]=mov_reg_8,
    [0xB3]=mov_reg_8,
    [0xB4]=mov_reg_8,
    [0xB5]=mov_reg_8,
    [0xB6]=mov_reg_8,
    [0xB7]=mov_reg_8,

    [0xB8]=mov_reg_16,
    [0xB9]=mov_reg_16,
    [0xBA]=mov_reg_16,
    [0xBB]=mov_reg_16,
    [0xBC]=mov_reg_16,
    [0xBD]=mov_reg_16,
    [0xBE]=mov_reg_16,
    [0xBF]=mov_reg_16,

    [0xC6]=function(pc)
        local reg,rm,len = modrm(pc+1,nil,8)
        if reg ~= 0 then error("bad 0xC6") end
        return {
            code=rm.."="..mem8[pc+len+1],
            len=2+len
        }
    end,
    [0xC7]=function(pc)
        local reg,rm,len = modrm(pc+1,nil,16)
        if reg ~= 0 then error("bad 0xC7") end
        return {
            code=rm.."="..mem16[pc+len+1],
            len=3+len
        }
    end,

    [0xCD]=function(pc)
        return {
            code="int("..mem8[pc+1]..")",
            len=2
        }
    end,

    [0xD0]=function(pc)
        local reg,rm,len = modrm(pc+1,nil,8)
        if reg==5 then
            return {
                code=rm.."=status(bit.rshift("..rm..",1),8)",
                len=2
            }
        else
            return {
                code="--?"..reg.." -- "..rm
            }
        end
    end,

    [0xE2]=function(pc)
        -- loop (brother)
        return {
            code="r16[1]=r16[1]-1",
            jmp_addr= pc+sign8(mem8[pc+1])+2,
            jmp_cond= "r16[1]~=0",
            len=2
        }
    end,
    [0xE4]=function(pc)
        return {
            code="r8[0]=cpu.input("..mem8[pc+1]..")",
            len=2
        }
    end,
    [0xE6]=function(pc)
        return {
            code="cpu.output("..mem8[pc+1]..",r8[0])",
            len=2
        }
    end,
    [0xE8]=function(pc)
        return {
            code="call("..string.format("0x%x",pc+mem16[pc+1])..")",
            len=3
        }
    end,
    [0xE9]=function(pc)
        return {
            jmp_addr= pc+sign16(mem16[pc+1])+3,
            len=0
        }
    end,

    [0xEB]=function(pc)
        return {
            jmp_addr= pc+sign8(mem8[pc+1])+2,
            len=0
        }
    end,

    [0xF6]=function(pc)
        local reg,rm,len = modrm(pc+1,nil,8)

        if reg==4 then
            return {
                code="r16[0]=r8[0]*"..rm.." ; cpu.f_carry = bit.band(0xFF00,r16[0])~=0 ; cpu.f_overflow = cpu.f_carry",
                len=1+len
            }
        else
            error("F6:"..reg)
        end
    end,
    [0xF7]=function(pc)
        local reg,rm,len = modrm(pc+1,nil,16)

        if reg==6 then
            -- divide, TODO errors
            return {
                code="do local tmp1=r16[0]+r16[2]*256 ; local tmp2="..rm.." ; r16[0]=math.floor(tmp1/tmp2) ; r16[2]=tmp1%tmp2 end",
                len=1+len
            }
        else
            error("F7:"..reg)
        end
    end,


    [0xFC]=function(pc)
        return {
            code="cpu.f_dir=1",
            len=1
        }
    end,
    [0xFD]=function(pc)
        return {
            code="cpu.f_dir=-1",
            len=1
        }
    end,

    [0xFF]=function(pc)
        local reg,rm,len = modrm(pc+1,nil,16)

        if reg==0 then
            return {
                code="do local tmp = cpu.f_carry ; "..rm.."=status("..rm.."+1,16) ; cpu.f_carry = tmp end",
                len=1+len
            }
        else
            error("FF:"..reg)
        end

    end
}

local instructions = {}
local func_entry=0x7C00
local pc=func_entry
local error_msgs = {}

local jmp_addrs = {}

::compile_chunk::
while true do
    local op = mem8[pc]

    local handler = op_handlers[op]

    if handler then
        local instr = handler(pc)
        instructions[pc] = instr
        if instr.jmp_addr then
            jmp_addrs[instr.jmp_addr]=true
        end
        if instr.len==0 then
            break
        end
        if instr.len==nil then
            table.insert(error_msgs,string.format("%x: no len %x",pc,op))
            break
        end
        pc=pc+instr.len
    else
        table.insert(error_msgs,string.format("%x: unknown opcode %x",pc,op))
        break
    end
end

local jmp_addr = next(jmp_addrs)
while jmp_addr ~= nil do
    jmp_addrs[jmp_addr]=nil
    
    if instructions[jmp_addr] == nil then
        pc = jmp_addr
        goto compile_chunk
    end

    jmp_addr = next(jmp_addrs)
end

local min_addr = math.huge
local max_addr = 0

for addr,_ in pairs(instructions) do
    min_addr=math.min(addr,min_addr)
    max_addr=math.max(addr,max_addr)
end

local next_addr=min_addr
for addr=min_addr,max_addr do
    local instr = instructions[addr]
    if instr then
        if next_addr~=addr then
            print("-----------------------------------------------------------")
        end

        local str = instr.code or ""
        if instr.jmp_addr then
            str=str.." -- goto "..string.format("%x",instr.jmp_addr)
            if instr.jmp_cond then
                str=str.." if "..instr.jmp_cond
            end
        end

        next_addr=addr+instr.len

        print(string.format("%x",addr),str)
    end
end


print("\nERRORS:")
PrintTable(error_msgs)

-- create blocks
local function make_block()
    return {xrefs={},loops=0,min_loop_target=math.huge}
end

local blocks = {[func_entry]=make_block()}
blocks[func_entry].entry = true
for addr,instr in pairs(instructions) do
    if instr.jmp_addr and not blocks[instr.jmp_addr] then
        blocks[instr.jmp_addr]= make_block()
    end
end

-- fill blocks with instrucitons
for addr,block in pairs(blocks) do
    repeat
        if blocks[addr] and blocks[addr]~=block then
            -- entry point shouldn't get linked to anything
            block.next_addr=addr
            break
        end
        local instr = instructions[addr]
        if instr == nil then break end
        table.insert(block,instr)
        addr = addr+instr.len
    until instr.len==0
end

-- build sorted addr list
local block_addrs = {}
for addr,block in pairs(blocks) do
    table.insert(block_addrs,addr)
end
table.sort(block_addrs)
while block_addrs[1]<func_entry do
    local addr = table.remove(block_addrs, 1)
    table.insert(block_addrs, addr)
    error("REORDER BLOCK,ENTRY JUMP SHOULD BE HANDED ALREADY")
end

-- build linkage
local last_addr
for i,addr in pairs(block_addrs) do
    local block = blocks[addr]
    if last_addr then
        blocks[last_addr].next = addr
        blocks[addr].prev = last_addr
    end
    last_addr = addr
end

-- patch up any adjacent blocks that were separated
for addr,block in pairs(blocks) do
    if block.next_addr and block.next_addr ~= block.next then
        error("BLOCK JUMP FIXUP")
        table.insert(block,{jmp_addr=block.next_addr,len=0})
    end
end

-- find xrefs
local current_id = 0
local block_addr = func_entry
while block_addr ~= nil do
    local block = blocks[block_addr]
    block.base_id = current_id+1
    
    for i=1,#block do
        local instr = block[i]
        instr.id = current_id+i
        if instr.jmp_addr then
            blocks[instr.jmp_addr].xrefs[instr.id]=true
        end
    end
    
    current_id=current_id+#block
    block_addr=block.next
end

local function check_can_loop(source_block,source_id,target_id)
    local block=source_block

    print("POTENTIAL LOOP:",source_id,target_id)
    while true do
        for xref,_ in pairs(block.xrefs) do
            if xref>source_id or xref<target_id then
                print("BAD",xref)
                return false
            end
        end
        if block.min_loop_target and block.min_loop_target<target_id then
            print("BAD (COLLISION)") -- TODO I HAVE NO IDEA IF THIS ACTUALLY WORKS
            return false
        end
        if target_id==block.base_id then break end
        block=blocks[block.prev]
    end
    block.loops=block.loops+1
    source_block.min_loop_target = math.min(target_id,block.min_loop_target)

    print("GOOD")
    return true
end

-- build loops - finally
local block_addr = func_entry
while block_addr ~= nil do
    local block = blocks[block_addr]

    for i=1,#block do
        local instr = block[i]
        if instr.jmp_addr then
            local target_id = blocks[instr.jmp_addr].base_id

            if instr.id >= target_id and check_can_loop(block,instr.id,target_id) then
                instr.loop=true
            else
                blocks[instr.jmp_addr].needs_label=true
            end
        end
    end

    block_addr=block.next
end

print("\nBLOCKS:")
PrintTable(blocks)

-- codegen
local code_lines={
    "return function(cpu)",
        "local call=cpu.call",
        "local int=cpu.int",
        "local status=cpu.status",
        "local r8=cpu.r8",
        "local r16=cpu.r16",
        "local data8=cpu.data8",
        "local data16=cpu.data16",
        "local stack8=cpu.stack8",
        "local stack16=cpu.stack16",
        "--todo cache all locals from cpu"
}

local block_addr = func_entry
while block_addr ~= nil do
    local block = blocks[block_addr]

    if block.needs_label then
        table.insert(code_lines,string.format("::L%x::",block_addr))
    end

    print(block.loops)
    for i=1,block.loops do
        table.insert(code_lines,"repeat")
    end

    for i=1,#block do
        local instr = block[i]
        if instr.code then
            table.insert(code_lines,instr.code)
        end
        if instr.loop then
            if instr.jmp_cond then
                table.insert(code_lines,"until not "..instr.jmp_cond)
            else
                table.insert(code_lines,"until false")
            end
        elseif instr.jmp_addr then
            if instr.jmp_cond then
                table.insert(code_lines,string.format("if %s then goto L%x end",instr.jmp_cond,instr.jmp_addr))
            else
                table.insert(code_lines,string.format("goto L%x",instr.jmp_addr))
            end
        end
    end

    block_addr=block.next
end

table.insert(code_lines,"end")

local code_str = table.concat(code_lines,"\n")

print(code_str)
file.Write("glua86/code.txt", code_str)

local code_f = CompileString(code_str, "glua86")()