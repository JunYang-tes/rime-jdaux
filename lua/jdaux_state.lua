-- 句中辅助码共享状态。
--
-- `jdaux_processor`（按键拦截）与 `jdaux_filter`（候选筛选）
-- 通过本模块共享同一份状态。librime-lua 的 require 会缓存模块，
-- 同一 LuaState 内的所有组件看到的是同一张表。
--
-- 工作方式：
--   1. 用户在音节边界（偶数长度输入）按下触发键 `` ` `` 时，
--      processor 进入捕获态，后续 1-2 个字母被当作辅助码吞掉，
--      不进入引擎（避免引擎把辅码当音节或产生不可解析片段）。
--   2. 捕获结束后，辅助码变成一条“约束”（pos = 第几个汉字）。
--   3. filter 读取约束列表，只放行满足全部约束的候选。
--
-- 例子（自然码双拼）：
--   ui`oohk   -> 约束 pos=1 aux=oo（实），再输入 hk -> “实好”类句子
--   ui`oohk`au -> 追加约束 pos=2 aux=au（好）
--
-- 注意：这里的 pos 是 1 起的汉字序号，不是字节偏移。

local M = {
    capturing = false, -- 是否正在捕获辅助码
    buf = "",          -- 当前已捕获的辅助码字母（<=2）
    pos = 0,           -- 待定约束对应的汉字位置（1 起）
    constraints = {},  -- 已确定的约束：{ {pos=int, aux=str}, ... }
}

-- 全部清空（提交、清除组合时调用）。
function M.reset()
    M.capturing = false
    M.buf = ""
    M.pos = 0
    M.constraints = {}
end

-- 结束捕获：若缓冲非空则固化为一条约束。
function M.push_constraint()
    if M.capturing and M.buf ~= "" then
        M.constraints[#M.constraints + 1] = { pos = M.pos, aux = M.buf }
    end
    M.capturing = false
    M.buf = ""
    M.pos = 0
end

-- 当前生效的完整约束列表（含捕获中的待定约束）。
function M.active_constraints()
    local list = {}
    for i = 1, #M.constraints do
        list[#list + 1] = M.constraints[i]
    end
    if M.capturing and M.buf ~= "" then
        list[#list + 1] = { pos = M.pos, aux = M.buf }
    end
    return list
end

return M
