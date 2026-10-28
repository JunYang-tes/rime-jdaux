-- JD 辅码候选筛选滤镜（句中任意位置辅助码）。
--
-- 用法：
--   在方案的 filters 中加入本滤镜，建议放在主要候选已经生成之后、
--   simplifier / uniquifier 之前：
--
--     - lua_filter@*jdaux_filter
--
--   可选配置：
--
--     jdaux:
--       trigger_key: "`"
--
-- 大致流程：
--   1. 普通输入没有辅助码约束时，直接原样透传候选。
--   2. jdaux_processor 在音节边界捕获 `` ` `` 后的辅码并固化为约束
--      （pos = 第几个汉字），本滤镜读取约束列表，用
--      `lua/jdaux/jd_aux_code.txt` 中的辅助码筛选现有候选。
--   3. 单字查字主要由 `table_translator@jdaux_char` 处理；本滤镜主要负责
--      词组和整句候选筛选。
--   4. 空格/数字上屏前，processor 已把 `` `xx `` 后缀从输入中剥离，
--      不会残留，也不需要按两次空格。
--
-- 基础例子（自然码双拼 + JD 辅码）：
--   shi`o     -> 是 / 时 / 实 ...   因为 是=oivi、时=oivi、实=ooo（首码 o）
--   shi`oo    -> 实 / 恃 ...        因为 实=ooo、恃=oov（前两码 oo）
--   ni`iu     -> 你 / 拟 ...        因为 你=iuai（首两码 iu）
--
-- 整句筛选：
--   当同长度候选只在少数位置不同，本滤镜会优先只检查这些“差异位置”的辅码，
--   而不是匹配整句里任意一个无关的字。这样可以处理整句候选的局部纠错。
--
--   例子 1：
--
--     我非常嫉妒
--     我非常极度
--
--   按 `au 可以把“我非常嫉妒”作为首选，因为 嫉=auo、妒=au。
--
--   例子 2：
--
--     像个傻子使得
--     像个傻子似的
--     像个傻子时的
--
--   按 `i 可以让“像个傻子似的”作为首选，因为 似=i。
--   按 `oi 可以让“像个傻子时的”作为首选，因为 时=oivi。
--
--   例子 3：
--
--     忍不住地流行
--     忍不住的流行
--     忍不住的流星
--
--   按 `oi 可以让“忍不住的流星”到最前，因为 星=oi。
--
--   另一个例子：
--
--     极度你的爱气势如虹
--     嫉妒你的爱气势如虹
--     季度你的爱气势如虹
--
--   输入 `...`au 会优先选择“嫉妒...”开头的候选，因为 嫉=auo / 妒=au，
--   而 极=vu、季=uva 不匹配 `au`。

local state = require("jdaux_state")

local M = {}

local function pass_through(input)
    for cand in input:iter() do
        yield(cand)
    end
end

-- 延迟加载 JD 辅助码表。
--
-- 文件格式：
--   字=aux
-- 示例：
--   你=iuai
--   嫉=auo
--
-- 读取结果会缓存在模块表上；普通输入没有触发键时不会加载码表。
local function load_aux_table()
    if M.aux_table then
        return M.aux_table
    end

    local aux_table = {}
    local file = io.open(rime_api.get_user_data_dir() .. "/lua/jdaux/jd_aux_code.txt", "r")
    if not file and rime_api.get_shared_data_dir then
        file = io.open(rime_api.get_shared_data_dir() .. "/lua/jdaux/jd_aux_code.txt", "r")
    end
    if not file then
        M.aux_table = aux_table
        return aux_table
    end

    for line in file:lines() do
        local ch, code = line:match("^([^=]+)=(.+)$")
        if ch and code and code ~= "" then
            local codes = aux_table[ch]
            if not codes then
                codes = {}
                aux_table[ch] = codes
            end
            codes[#codes + 1] = code
        end
    end
    file:close()

    M.aux_table = aux_table
    return aux_table
end

-- 将 UTF-8 字符串拆成单字数组。
-- Rime 候选文本是 UTF-8，不能直接用字节下标当作汉字位置。
local function split_chars(text)
    local chars = {}
    for _, codepoint in utf8.codes(text) do
        chars[#chars + 1] = utf8.char(codepoint)
    end
    return chars
end

-- 判断某个字是否有以 aux 开头的辅助码。
-- 既支持一码筛选（如 `n`），也支持完整两码筛选（如 `nu`）。
local function char_matches_prefix(aux_table, ch, aux)
    local codes = aux_table[ch]
    if not codes then
        return false
    end
    for _, code in ipairs(codes) do
        if code:sub(1, #aux) == aux then
            return true
        end
    end
    return false
end

-- 按顺序在候选中匹配一串辅助码。
-- 示例：
--   aux = "bd"
--   candidate = "事实"
--   实=bd 会被 `char_matches_prefix` 直接命中；此函数主要用于拆开匹配，
--   例如先匹配 `b`，再在后面的字里匹配 `d`。
local function match_subsequence(aux_table, chars, aux)
    local pos = 1
    for i = 1, #chars do
        local code = aux:sub(pos, pos)
        if code == "" then
            return true
        end
        if char_matches_prefix(aux_table, chars[i], code) then
            pos = pos + 1
        end
    end
    return pos > #aux
end

-- 兜底匹配：当没有更精确的“差异位置”匹配时使用。
-- 它会扫描候选里的所有字：
--   - 一码辅码：命中任意一个辅助码以该键开头的字；
--   - 两码辅码：可以命中某个字的完整辅码，也可以跨字按顺序匹配。
local function candidate_matches(aux_table, text, aux)
    if text == "" or aux == "" then
        return false
    end

    local chars = split_chars(text)
    for i = 1, #chars do
        if char_matches_prefix(aux_table, chars[i], aux) then
            return true
        end
    end

    if #aux > 1 then
        return match_subsequence(aux_table, chars, aux)
    end
    return false
end

-- 一次性消费候选流，并同时保存每个候选拆好的字数组。
-- Rime filter 的输入流不能倒回，所以后续多轮匹配都基于这个列表进行。
local function collect_candidates(input)
    local candidates = {}
    for cand in input:iter() do
        candidates[#candidates + 1] = {
            cand = cand,
            chars = split_chars(cand.text),
        }
    end
    return candidates
end

-- 找出一组候选中发生差异的位置。
-- 对整句候选来说，这能让筛选聚焦在真正需要消歧的字上，
-- 避免被后面无关的字误命中。
local function find_variant_positions(candidates)
    local positions = {}
    local max_len = 0
    for i = 1, #candidates do
        if #candidates[i].chars > max_len then
            max_len = #candidates[i].chars
        end
    end

    for pos = 1, max_len do
        local first = nil
        local differs = false
        for i = 1, #candidates do
            local ch = candidates[i].chars[pos]
            if ch then
                if first == nil then
                    first = ch
                elseif ch ~= first then
                    differs = true
                    break
                end
            end
        end
        if differs then
            positions[#positions + 1] = pos
        end
    end
    return positions
end

-- 选择第一组“同长度且存在差异”的候选。
-- Rime 通常会把可比较的整句候选放在一起，因此这里优先做整句级消歧，
-- 找不到合适分组时再回退到任意字匹配。
local function find_variant_group(candidates)
    local groups = {}
    local order = {}
    for i = 1, #candidates do
        local len = #candidates[i].chars
        if len > 0 then
            local group = groups[len]
            if not group then
                group = {}
                groups[len] = group
                order[#order + 1] = len
            end
            group[#group + 1] = candidates[i]
        end
    end

    for i = 1, #order do
        local group = groups[order[i]]
        if #group >= 2 then
            local positions = find_variant_positions(group)
            if #positions > 0 then
                return group, positions
            end
        end
    end
    return nil, nil
end

-- 只匹配候选中的指定位置，通常是同长度词组/整句候选里的差异位置。
local function candidate_matches_positions(aux_table, chars, aux, positions)
    for i = 1, #positions do
        local ch = chars[positions[i]]
        if ch and char_matches_prefix(aux_table, ch, aux) then
            return true
        end
    end
    if #aux > 1 then
        local selected = {}
        for i = 1, #positions do
            local ch = chars[positions[i]]
            if ch then
                selected[#selected + 1] = ch
            end
        end
        return match_subsequence(aux_table, selected, aux)
    end
    return false
end

function M.init(env)
    local config = env.engine.schema.config
    env.trigger_key = config:get_string("jdaux/trigger_key") or "`"

    -- 选中候选后剥离 `辅码 后缀这件事，统一由 jdaux_processor 的
    -- select_notifier（finish_selection）负责，这里不再重复处理。
    -- 原先本滤镜也连了 select_notifier，做法是「改写 ctx.input 后调
    -- ctx:commit()」——改写输入串会重建 composition 并丢掉刚刚选中的
    -- 候选，commit 提交的是新表的首选而不是用户选的那一项。
end

function M.fini(env)
end

-- 句中辅助码约束筛选（由 jdaux_processor 捕获，见 jdaux_state）。
--
-- 约束是精确位置匹配：候选第 pos 个字（1 起）的辅助码必须以 aux 开头。
-- 全部约束都满足的候选排到最前；若没有任何候选满足，则原样放行全部候选，
-- 避免输错辅码导致“没有候选”。
local function apply_constraints(input, constraints)
    local aux_table = load_aux_table()
    local candidates = collect_candidates(input)

    local matched, rest = {}, {}
    for i = 1, #candidates do
        local item = candidates[i]
        local ok = true
        for j = 1, #constraints do
            local c = constraints[j]
            local ch = item.chars[c.pos]
            if not ch or not char_matches_prefix(aux_table, ch, c.aux) then
                ok = false
                break
            end
        end
        if ok then
            matched[#matched + 1] = item
        else
            rest[#rest + 1] = item
        end
    end

    if #matched > 0 then
        for i = 1, #matched do
            yield(matched[i].cand)
        end
    else
        for i = 1, #rest do
            yield(rest[i].cand)
        end
    end
end

function M.func(input, env)
    local input_code = env.engine.context.input

    -- 句中/句末辅助码约束。约束路径无条件优先：捕获期间输入区里
    -- 会短暂存在字面触发键（jdaux_processor 的可见模式），此时
    -- 绝不能再走旧路径，否则会双重过滤互相打架。
    local constraints = state.active_constraints()
    local trigger_pos = input_code:find(env.trigger_key, 1, true)

    if #constraints > 0 then
        apply_constraints(input, constraints)
        return
    end

    -- 普通输入的快速路径。这里仍然有 Lua filter 的透传成本，
    -- 但不会加载辅码表，也不会扫描候选文本。
    if not trigger_pos then
        pass_through(input)
        return
    end

    local aux = input_code:sub(trigger_pos + #env.trigger_key):match("^([^,']+)") or ""
    aux = aux:sub(1, 2)
    if aux == "" then
        pass_through(input)
        return
    end

    local aux_table = load_aux_table()
    local candidates = collect_candidates(input)
    local variant_group, variant_positions = find_variant_group(candidates)
    local yielded = {}
    local has_variant_match = false

    -- 第一轮：如果可比较候选只在特定位置不同，就只按这些位置筛选。
    -- 这一步用于提高整句纠错的精度。
    if variant_group and variant_positions then
        for i = 1, #variant_group do
            local item = variant_group[i]
            if candidate_matches_positions(aux_table, item.chars, aux, variant_positions) then
                yielded[item] = true
                has_variant_match = true
                yield(item.cand)
            end
        end
    end

    -- 第二轮：如果没有差异位置命中，则退回到候选任意字匹配。
    -- 如果已经有精确的差异位置命中，就不再追加无关的模糊命中结果。
    for i = 1, #candidates do
        local item = candidates[i]
        if not yielded[item] then
            if (not has_variant_match) and candidate_matches(aux_table, item.cand.text, aux) then
                yield(item.cand)
            end
        end
    end
end

return M
