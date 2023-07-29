---@type Mq
local mq = require('mq')
---@type ImGui
require('ImGui')
local Write = require('Write')
Write.loglevel = 'info'

local HAS_TASK = 'Task[%s]'
local TASK_STEP_PROGRESS = 'Task[%s].Objective[%s].Status'

local open, draw = true, true
local anon = false

local peers = {}
local peerTaskStatus = {}

local peerRefreshTime = 0
local hasTaskSubmittedTime = 0
local hasTaskProcessedTime = 0
local taskStepsSubmittedTime = 0
local taskStepsProcessedTime = 0

local currentTask = ''
local taskList = {}

local function imguiCallback()
    if not open then return end
    open, draw = ImGui.Begin('TaskWindow', open)
    if draw then
        if ImGui.BeginCombo('Task', currentTask) then
            for i,j in pairs(taskList) do
                if ImGui.Selectable(j, j == currentTask) then
                    currentTask = j
                end
            end
            ImGui.EndCombo()
        end
        ImGui.SameLine()
        anon = ImGui.Checkbox('Anon', anon)
        ImGui.Separator()
        local peersWithTask = 0
        if currentTask ~= '' then
            for _,peer in ipairs(peers) do
                if peerTaskStatus[peer] and peerTaskStatus[peer][currentTask] then
                    peersWithTask = peersWithTask + 1
                end
            end
        end
        if ImGui.BeginTable('Status', peersWithTask+1) then
            ImGui.TableSetupColumn('Objective', 0, 4)
            for i,peer in ipairs(peers) do
                if peerTaskStatus[peer] and peerTaskStatus[peer][currentTask] then
                    if anon then
                        ImGui.TableSetupColumn(('toon_%s'):format(i), 0, 1)
                    else
                        ImGui.TableSetupColumn(peer)
                    end
                end
            end
            ImGui.TableSetupScrollFreeze(0, 1)
            ImGui.TableHeadersRow()

            if currentTask ~= '' then
                for i=1,25 do
                    local objective = mq.TLO.Task(currentTask).Objective(i)()
                    if objective then
                        ImGui.TableNextRow()
                        ImGui.TableNextColumn()
                        ImGui.Text('%s', objective)
                        ImGui.TableNextColumn()
                        for _,peer in ipairs(peers) do
                            if peerTaskStatus[peer] and peerTaskStatus[peer][currentTask] then
                                ImGui.Text('%s', peerTaskStatus[peer][currentTask][objective])
                            end
                            ImGui.TableNextColumn()
                        end
                    end
                end
            end

            ImGui.EndTable()
        end
    end
    ImGui.End()
end

local function submitQuery(peer, query)
    mq.cmdf('/dquery %s -q "%s"', peer, query)
end

local function isQueryResultAvailable(peer, query, time)
    return time - mq.TLO.DanNet(peer).QReceived(query)() < 5000
end

local function getQueryResult(peer, query)
    return mq.TLO.DanNet(peer).Q(query)()
end

local function split(input, sep)
    if sep == nil then
        sep = "|"
    end
    local t={}
    for str in string.gmatch(input, "([^"..sep.."]+)") do
        table.insert(t, str)
    end
    return t
end

local function submitHasTaskQueries(currentTime)
    local hasTaskFormatted = HAS_TASK:format(currentTask)
    if currentTime - hasTaskSubmittedTime > 3000 and hasTaskSubmittedTime <= hasTaskProcessedTime then
        Write.Debug('HAS_TASK submitted is stale, refreshing')
        for _,peer in ipairs(peers) do
            submitQuery(peer, hasTaskFormatted)
        end
        hasTaskSubmittedTime = mq.gettime()
    end
end

local function processHasTaskResponses(currentTime)
    if currentTime - hasTaskProcessedTime > 3000 then
        Write.Debug('HAS_TASK processed is stale, refreshing')
        local numReceived = 0
        local hasTaskFormatted = HAS_TASK:format(currentTask)
        for _,peer in ipairs(peers) do
            if isQueryResultAvailable(peer, hasTaskFormatted, currentTime) then
                numReceived = numReceived + 1
                local hasTaskResult = getQueryResult(peer, hasTaskFormatted)
                if hasTaskResult ~= '' then
                    peerTaskStatus[peer] = peerTaskStatus[peer] or {[currentTask] = {}}
                    peerTaskStatus[peer][currentTask] = peerTaskStatus[peer][currentTask] or {}
                end
            end
        end
        if numReceived == #peers then
            hasTaskProcessedTime = mq.gettime()
        end
    end
end

local function submitTaskStepQueries(currentTime)
    local numQueriesSubmitted = 0
    if currentTime - taskStepsSubmittedTime > 3000 and taskStepsSubmittedTime <= taskStepsProcessedTime then
        Write.Debug('TASK_STEPS submitted is stale, refreshing')
        for _,peer in ipairs(peers) do
            if peerTaskStatus[peer] and peerTaskStatus[peer][currentTask] then
                for i=1,25 do
                    if mq.TLO.Task(currentTask).Objective(i)() then
                        submitQuery(peer, TASK_STEP_PROGRESS:format(currentTask, i))
                        numQueriesSubmitted = numQueriesSubmitted + 1
                    else
                        break
                    end
                end
            end
        end
        taskStepsSubmittedTime = mq.gettime()
    end
    return numQueriesSubmitted
end

local function processTaskStepResponses(numQueriesSubmitted, currentTime)
    local numQueriesReceived = 0
    if currentTime - taskStepsProcessedTime > 3000 then
        Write.Debug('TASK_STEPS processed is stale, refreshing')
        for _,peer in ipairs(peers) do
            if peerTaskStatus[peer] and peerTaskStatus[peer][currentTask] then
                for i=1,25 do
                    local objective = mq.TLO.Task(currentTask).Objective(i)()
                    if objective then
                        local taskStepProgressFormatted = TASK_STEP_PROGRESS:format(currentTask, i)
                        if isQueryResultAvailable(peer, taskStepProgressFormatted, currentTime) then
                            local statusResult = getQueryResult(peer, taskStepProgressFormatted)
                            peerTaskStatus[peer][currentTask][objective] = statusResult
                            numQueriesReceived = numQueriesReceived + 1
                        end
                    else
                        break
                    end
                end
            end
        end
        if numQueriesSubmitted == numQueriesReceived then
            taskStepsProcessedTime = mq.gettime()
        end
    end
end

local function runCurrentTaskQueries(currentTime)
    if currentTask ~= '' then
        submitHasTaskQueries(currentTime)
        processHasTaskResponses(currentTime)
        local numQueriesSubmitted = submitTaskStepQueries(currentTime)
        processTaskStepResponses(numQueriesSubmitted, currentTime)
    end
end

local function validateCurrentTask()
    if not mq.TLO.Task(currentTask)() then currentTask = '' end
end

local function refreshPeers(currentTime)
    if currentTime - peerRefreshTime > 3000 then
        Write.Debug('peer list is stale, refreshing')
        peerRefreshTime = mq.gettime()
        peers = split(mq.TLO.DanNet.Peers())
    end
end

local function buildTaskList()
    for i=1,25 do
        local task = mq.TLO.Task(i)
        if task() ~= '' then
            taskList[i] = task()
        else
            taskList[i] = nil
            break
        end
    end
end

local function checkDependencies()
    if not mq.TLO.Plugin('MQ2DanNet').IsLoaded() then
        mq.cmd('/plugin dannet')
        mq.delay(500)
    end
end

mq.imgui.init('Task', imguiCallback)

while true do
    local currentTime = mq.gettime()
    checkDependencies()
    refreshPeers(currentTime)
    buildTaskList()
    validateCurrentTask()
    runCurrentTaskQueries(currentTime)
    mq.delay(1000)
end