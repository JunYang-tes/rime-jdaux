-- 句中辅助码按键处理器。
--
-- 用法（方案 processors，需放在 speller / ascii_composer 之前）：
--
--   - lua_processor@*jdaux_processor
--
-- 可选配置（与 jdaux_filter 共用）：
--
--   jdaux:
--     trigger_key: "`"
--     mid_enabled: true
--
-- 设计目标：
--   引擎的 script_translator 无法解析“音节 + `辅码 + 音节”混合输入，
--   句中出现反引号会导致整句翻译失败。本处理器按光标位置分两种模式：
--
--   * 光标在输入末尾 —— 可见模式：
--     触发键与辅码字母照常进入输入区（用户始终能看到 nihao`au 这样的
--     preedit），候选实时过滤；在辅码结束的时机把 `` `xx `` 后缀从引擎
--     输入中剥离，同时固化为约束交给 jdaux_filter 执行。
--
--       uiui`oo    -> 输入区显示 uiui`oo，候选按 实=ooo 等实时过滤；
--                     空格/数字上屏时后缀被剥离，不残留。
--       ui`oohk    -> 第三个字母 h 触发固化 {pos=1,aux=oo} 并剥离后缀，
--                     h 作为下一音节声母继续 -> “实好”类句子。
--
--   * 光标在句中（用方向键移入）—— 隐形模式：
--     句中插入字符会破坏整句解析、且剥离逻辑无法安全定位，因此触发键
--     与辅码字母完全不进引擎，只记录约束。空格/数字提交时，整句候选
--     按约束过滤后上屏；退格则交还引擎原生处理。
--
--       uiuihk + <Left><Left> + `oo + 空格 -> 第二个字被 oo 辅码限定
--
-- 按键规则（两种模式通用）：
--   * 触发键：输入非空且长度为偶数（音节边界）时开始捕获；
--     空输入或奇数长度时透传且不捕获（旧行为）。
--   * 捕获中小写字母：前两个字母计入辅码；缓冲满 2 个后再来字母，
--     固化约束并结束本次捕获（可见模式还会剥离后缀）。
--   * 捕获中再按触发键：先固化当前辅码再重新开始捕获；同一位置的旧
--     约束视为“细化”，先移除（一个汉字只保留一条辅码约束）。
--   * 退格：先逐个撤销已输入的辅码字母（可见模式同步删除输入区字符）；
--     辅码空后再退格：可见模式删除触发键并退出捕获，隐形模式直接退出
--     捕获并放行退格（由引擎删除光标前的拼音字母）。
--   * 空格 / 回车 / 数字选键 / 标点等可提交键：固化约束后交由
--     selector / punctuator 正常处理。
--   * 方向键 / Home / End 等导航键：固化约束并结束捕获后放行。
--   * Escape 或组合清空：复位全部状态。
--   * 选中候选（select_notifier）：复位全部状态。

-- 注意：本环境的 librime-lua 并不导出 kRejected/kAccepted/kNoop 全局常量
-- （实测均为 nil），而 ProcessResult 枚举为 kRejected=0 / kAccepted=1 /
-- kNoop=2。返回 0 或 1 会终止后续处理器并吞掉该键；返回 2 或 nil 才是
-- 透传。此处显式定义同值局部常量，切勿依赖全局名。

local state = require("jdaux_state")

local M = {}

local kRejected = 0
local kAccepted = 1
local kNoop = 2

local XK_backspace = 0xff08
local XK_Return = 0xff0d
local XK_KP_Enter = 0xff8d
local XK_Escape = 0xff1b

-- 选中候选之后，丢掉 `辅码 后缀所在的分段，让这次选择直接落地。
--
-- 为什么不能在按键阶段剥离后缀：本处理器排在 selector 之前，此时改写
-- ctx.input 会让 librime 重建 composition 并重新翻译，selector 随后面对
-- 的是一张全新的候选表。实测 du`o 显示 ［度 度 嘟 读 踱 阇］，按 4 上屏
-- 的却是「踱」——正是剥离成 du 之后那张表的第 4 项。
--
-- 而到了这里就是安全的：选择已经落在用户看到的那张表上了。
--
-- 注意别在这里去读 ctx:get_selected_candidate()：引擎把 du`o 切成
-- ［du］［`o］两段，选中第一段后 engine 的 OnSelect 已经把 composition
-- 推进到 ［`o］段，此时取到的是「哦」而不是用户选的字。也别只 pop 掉
-- 后缀分段就提交——输入串里没被分段覆盖的尾巴会被原样附加，实测会得到
-- 「嘟`o」这种上屏结果。
local function finish_selection(env, ctx)
    local trigger_pos = ctx.input:find(env.trigger_key, 1, true)
    if not trigger_pos then
        return
    end

    local stripped = ctx.input:sub(1, trigger_pos - 1)
    if stripped == "" then
        return
    end

    -- 把输入串截回纯拼音。此刻前面那段已经是 kSelected，librime 重新
    -- 分词时会保留它连同刚选中的候选，只重算后面；于是 commit 得到的
    -- 就是用户选的那个字，`辅码 既不残留也不会被当成未翻译的尾巴附加
    -- 上屏。走的是引擎原生 Commit，用户词典的词频学习照常进行。
    ctx.input = stripped
    ctx:commit()
end

function M.init(env)
    local config = env.engine.schema.config
    env.trigger_key = config:get_string("jdaux/trigger_key") or "`"
    local enabled = config:get_bool("jdaux/mid_enabled")
    if enabled == nil then
        enabled = true
    end
    env.mid_enabled = enabled

    env.notifier = env.engine.context.select_notifier:connect(function(ctx)
        finish_selection(env, ctx)
        state.reset()
        env.capture_visible = nil
        env.capture_pos = nil
    end)
end

function M.fini(env)
    if env.notifier then
        env.notifier:disconnect()
    end
end

local function is_lower_letter(keycode)
    return keycode >= 0x61 and keycode <= 0x7a
end

-- 空格、回车、数字、标点等会终结辅码的可打印键。
local function is_flush_key(keycode)
    if keycode == XK_Return or keycode == XK_KP_Enter then
        return true
    end
    return keycode >= 0x20 and keycode <= 0x7e
end

-- 方向键 / Home / End / 翻页等移动光标或浏览候选的键。
local function is_navigation_key(keycode)
    return keycode >= 0xff50 and keycode <= 0xff57
end

-- 按序号或高亮选择候选的按键：数字 1-9、分号（方案里绑定为选第 2 项）、
-- 空格。这些键必须让 selector 在用户眼前的那张候选表上执行选择，因此
-- 处理器在放行前绝不能改写 ctx.input。
-- 小键盘 KP_1..KP_9 由 key_binder 转成数字，但 key_binder 排在本处理器
-- 之后，它们会以 0xffb1.. 的形式落到下面“其它功能键”的放行分支，同样
-- 不会改写输入串，效果一致。
-- 不含 '0'：default.yaml 的 menu/page_size 是 9，'0' 并不选择候选。
local function is_select_key(keycode)
    return (keycode >= 0x31 and keycode <= 0x39)  -- 1-9
        or keycode == 0x3b                        -- ;
        or keycode == 0x20                        -- space
end

-- 从引擎输入末尾剥掉 n 个字符（仅可见模式使用，光标必在末尾）。
local function strip_tail(ctx, n)
    local s = ctx.input
    if #s >= n then
        ctx.input = s:sub(1, #s - n)
    end
end

-- 隐形模式下辅助码按键被吞掉，引擎不会重新翻译；此处强制重翻一次，
-- 让滤镜立即按最新约束过滤候选。
--
-- 注意：原样回写（ctx.input = ctx.input）是无效的——librime 1.17 实测
-- 不会重建 composition，滤镜一次都不会被调用，隐形模式的实时反馈因此
-- 从未生效。这里改用 Context 自带的 refresh_non_confirmed_composition，
-- 它只重算未确认的部分，不动输入串也不动光标。
local function refresh_composition(ctx)
    if ctx.input == "" then
        return
    end
    pcall(function() ctx:refresh_non_confirmed_composition() end)
end

-- 光标是否位于输入末尾。老版本无 caret_pos 属性时按“在末尾”处理。
local function caret_at_end(ctx, input_len)
    local ok, pos = pcall(function() return ctx.caret_pos end)
    if not ok or type(pos) ~= "number" then
        return true
    end
    return pos >= input_len
end

function M.func(key, env)
    if not env.mid_enabled then
        return kNoop
    end

    local keycode = key.keycode

    -- 带修饰键或释放事件的一律放行，不干扰快捷键。
    local okr, is_release = pcall(function() return key:release() end)
    if okr and (is_release or key:ctrl() or key:alt() or key:super()) then
        return kNoop
    end

    local ctx = env.engine.context

    if keycode == XK_Escape then
        state.reset()
        env.capture_visible = nil
        return kNoop
    end

    local inp = ctx.input

    -- 组合为空：复位并放行。
    if inp == "" then
        state.reset()
        env.capture_visible = nil
        return kNoop
    end

    local trigger = string.byte(env.trigger_key) or 0x60
    local visible = env.capture_visible

    if keycode == trigger then
        if state.capturing then
            if state.buf == "" then
                -- 已有裸触发键/空缓冲：忽略重复按键。
                return kAccepted
            end
            local aux_len = #state.buf
            state.push_constraint()
            if visible then
                strip_tail(ctx, 1 + aux_len)
                inp = ctx.input
            else
                -- 隐形模式：固化后重新捕获同一位置（细化替换）。
                state.constraints[#state.constraints] = nil
                state.capturing = true
                state.buf = ""
                state.pos = env.capture_pos or 0
                refresh_composition(ctx)
                return kAccepted
            end
        elseif #inp % 2 ~= 0 then
            -- 奇数长度：透传（旧路径，字面触发键由引擎处理）。
            return kNoop
        elseif not caret_at_end(ctx, #inp) then
            -- 光标在句中：隐形捕获，不向引擎插入任何内容。
            local new_pos = ctx.caret_pos // 2
            if new_pos < 1 then
                -- 光标已在最前面，前面没有可供限定的字。此时若照旧记下
                -- pos=0，约束会永远匹配不上（候选的字序号从 1 起），
                -- 等于把候选全部判为不合格，所以直接吞掉按键不捕获。
                return kAccepted
            end
            local cs = state.constraints
            while #cs > 0 and cs[#cs].pos == new_pos do
                cs[#cs] = nil
            end
            env.capture_visible = false
            env.capture_pos = new_pos
            state.capturing = true
            state.buf = ""
            state.pos = new_pos
            return kAccepted
        end
        -- 光标在末尾：可见模式开始捕获；触发键透传给 speller 保持可见。
        local new_pos = #inp // 2
        local cs = state.constraints
        while #cs > 0 and cs[#cs].pos == new_pos do
            cs[#cs] = nil
        end
        env.capture_visible = true
        env.capture_pos = new_pos
        state.capturing = true
        state.buf = ""
        state.pos = new_pos
        return kNoop
    end

    if state.capturing then
        if is_lower_letter(keycode) then
            if #state.buf < 2 then
                state.buf = state.buf .. string.char(keycode)
                if visible then
                    return kNoop
                end
                refresh_composition(ctx)
                return kAccepted
            end
            -- 第三个字母：固化约束并结束捕获。
            state.push_constraint()
            if visible then
                strip_tail(ctx, 1 + 2)
            end
            return kNoop
        elseif keycode == XK_backspace then
            if #state.buf > 0 then
                state.buf = state.buf:sub(1, #state.buf - 1)
                if visible then
                    strip_tail(ctx, 1)
                else
                    refresh_composition(ctx)
                end
                return kAccepted
            end
            -- 辅码已空：退出捕获。可见模式删掉触发键并吞掉退格；
            -- 隐形模式放行退格，由引擎删除光标前的字母。
            state.capturing = false
            state.pos = 0
            env.capture_visible = nil
            env.capture_pos = nil
            if visible then
                strip_tail(ctx, 1)
                return kAccepted
            end
            return kNoop
        elseif is_navigation_key(keycode) then
            -- 导航键：先固化收尾，再放行。
            if #state.buf > 0 then
                if visible then
                    local aux_len = #state.buf
                    state.push_constraint()
                    strip_tail(ctx, 1 + aux_len)
                else
                    state.push_constraint()
                end
            elseif visible then
                strip_tail(ctx, 1)
            end
            state.capturing = false
            state.buf = ""
            state.pos = 0
            env.capture_visible = nil
            env.capture_pos = nil
            return kNoop
        elseif is_select_key(keycode) then
            -- 选择类按键：只固化约束，输入串一个字符都不动，放行给
            -- selector 在用户看到的候选表上选择；`辅码 后缀的剥离交由
            -- select_notifier 在选中之后完成（见 finish_selection）。
            state.push_constraint()
            state.capturing = false
            state.buf = ""
            state.pos = 0
            env.capture_visible = nil
            env.capture_pos = nil
            return kNoop
        elseif is_flush_key(keycode) then
            -- 回车、标点等提交键：它们提交的是当前首选或输入串本身，
            -- 不按候选序号定位，所以照旧在这里剥离后缀。
            if #state.buf > 0 then
                if visible then
                    local aux_len = #state.buf
                    state.push_constraint()
                    strip_tail(ctx, 1 + aux_len)
                else
                    state.push_constraint()
                end
            elseif visible then
                strip_tail(ctx, 1)
            end
            state.capturing = false
            state.buf = ""
            state.pos = 0
            env.capture_visible = nil
            env.capture_pos = nil
            return kNoop
        end
        -- 其它功能键：放行，捕获状态保留。
        return kNoop
    end

    return kNoop
end

return M
