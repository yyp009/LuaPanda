--[[
Tencent is pleased to support the open source community by making LuaPanda available.
Copyright (C) 2019 THL A29 Limited, a Tencent company. All rights reserved.
Licensed under the BSD 3-Clause License (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at
https://opensource.org/licenses/BSD-3-Clause
Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

API:
    LuaPanda.printToVSCode(logStr, printLevel, type)
        打印日志到VSCode Output下Debugger/log中
        @printLevel: debug(0)/info(1)/error(2) 这里的日志等级需高于launch.json中配置等级日志才能输出 (可选参数，默认0)
        @type: 0:VSCode output console  1:VSCode tip (可选参数，默认0)

    LuaPanda.BP()
        强制打断点，可以在协程中使用。建议使用以下写法:
        local ret = LuaPanda and LuaPanda.BP and LuaPanda.BP();
        如果成功加入断点ret返回true，否则是nil

    LuaPanda.getInfo()
        返回获取调试器信息。包括版本号，是否使用lib库，系统是否支持loadstring(load方法)。返回值类型string, 推荐在调试控制台中使用。

    LuaPanda.doctor()
        返回对当前环境的诊断信息，提示可能存在的问题。返回值类型string, 推荐在调试控制台中使用。

    LuaPanda.getCWD()
        用户可以调用或在调试控制台中输出这个函数，返回帮助设置CWD的路径。比如
        cwd:      F:/1/2/3/4/5
        getinfo:  @../../../../../unreal_10/slua-unreal_1018/Content//Lua/TestArray.lua
        format:   f:/unreal_10/slua-unreal_1018/Content/Lua/TestArray.lua
        cwd是vscode传来的配置路径。getinfo是通过getinfo获取到的正在运行的文件路径。format是经过 cwd + getinfo 整合后的格式化路径。
        format是传给VSCode的最终路径。
        如果format路径和文件真实路径不符，导致VSCode找不到文件，通过调整工程中launch.json的cwd，使format路径和真实路径一致。
        返回值类型string, 推荐在调试控制台中使用。

    LuaPanda.getBreaks()
        获取断点信息，返回值类型string, 推荐在调试控制台中使用。

    LuaPanda.serializeTable(table)
        把table序列化为字符串，返回值类型是string。
]]

--用户设置项
local openAttachMode = true;            --是否开启attach模式。attach模式开启后可以在任意时刻启动vscode连接调试。缺点是没有连接调试时也会略降低lua执行效率(会不断进行attach请求)
local attachInterval = 1;               --attach间隔时间(s)
local customGetSocketInstance = nil;    --支持用户实现一个自定义调用luasocket的函数，函数返回值必须是一个socket实例。例: function() return require("socket.core").tcp() end;
local consoleLogLevel = 2;           --打印在控制台(print)的日志等级 0 : all/ 1: info/ 2: error.
local connectTimeoutSec = 0.005;       --等待连接超时时间, 单位s. 时间过长等待attach时会造成卡顿，时间过短可能无法连接。建议值0.005 - 0.05
--用户设置项END

local debuggerVer = "2.3.0";                 --debugger版本号
LuaPanda = {};
local this = LuaPanda;
local tools = require("DebugTools");     --引用的开源工具，包括json解析和table展开工具等
this.tools = tools;
this.curStackId = 0;
--json处理
local json = tools.createJson()
--hook状态列表
local hookState = {
    DISCONNECT_HOOK = 0,                --断开连接
    LITE_HOOK = 1,              --全局无断点
    MID_HOOK = 2,               --全局有断点，本文件无断点
    ALL_HOOK = 3,               --本文件有断点
};
--运行状态列表
local runState = {
    DISCONNECT = 0,             --未连接
    WAIT_CMD = 1,               --已连接，等待命令
    STOP_ON_ENTRY = 2,          --初始状态
    RUN = 3,
    STEPOVER = 4,
    STEPIN = 5,
    STEPOUT = 6,
    STEPOVER_STOP = 7,
    STEPIN_STOP = 8,
    STEPOUT_STOP = 9,
    HIT_BREAKPOINT = 10
};

local TCPSplitChar = "|*|";             --json协议分隔符，请不要修改
local MAX_TIMEOUT_SEC = 3600 * 24;   --网络最大超时等待时间
--当前运行状态
local currentRunState;
local currentHookState;
--断点信息
local breaks = {};              --保存断点的数组
this.breaks = breaks;           --供hookLib调用
local recCallbackId = "";
--VSCode端传过来的配置，在VSCode端的launch配置，传过来并赋值
local luaFileExtension = "";    --脚本后缀
local cwd = "";                 --工作路径
local DebuggerFileName = "";    --Debugger文件名(原始,未经path处理), 函数中会自动获取
local DebuggerToolsName = "";
local lastRunFunction = {};     --上一个执行过的函数。在有些复杂场景下(find,getcomponent)一行会挺两次
local currentCallStack = {};    --获取当前调用堆栈信息
local hitBP = false;            --BP()中的强制断点命中标记
local TempFilePath_luaString = ""; --VSCode端配置的临时文件存放路径
local connectHost;              --记录连接端IP
local connectPort;              --记录连接端口号
local sock;                     --tcp socket
local OSType;                --VSCode识别出的系统类型，也可以自行设置。Windows_NT | Linux | Darwin
local clibPath;                 --chook库在VScode端的路径，也可自行设置。
local hookLib;                  --chook库的引用实例
local adapterVer;               --VScode传来的adapter版本号
--标记位
local logLevel = 1;             --日志等级all/info/error. 此设置对应的是VSCode端设置的日志等级.
local variableRefIdx = 1;       --变量索引
local variableRefTab = {};      --变量记录table
local lastRunFilePath = "";     --最后执行的文件路径
local pathCaseSensitivity = true;  --路径是否发大小写敏感，这个选项接收VScode设置，请勿在此处更改
local recvMsgQueue = {};        --接收的消息队列
local coroutinePool = {};       --保存用户协程的队列
local winDiskSymbolUpper = false;--设置win下盘符的大小写。以此确保从VSCode中传入的断点路径,cwd和从lua虚拟机获得的文件路径盘符大小写一致
local isNeedB64EncodeStr = false;-- 记录是否使用base64编码字符串
local loadclibErrReason = 'launch.json文件的配置项useCHook被设置为false.';
local OSTypeErrTip = "";
local pathErrTip = ""
local winDiskSymbolTip = "";
local isAbsolutePath = false;
local stopOnEntry;         --用户在VSCode端设置的是否打开stopOnEntry
local userSetUseClib;    --用户在VSCode端设置的是否是用clib库
local autoPathMode = false;
--Step控制标记位
local stepOverCounter = 0;      --STEPOVER over计数器
local stepOutCounter = 0;       --STEPOVER out计数器
local HOOK_LEVEL = 3;           --调用栈偏移量，使用clib时为3，lua中不再使用此变量，而是通过函数getSpecificFunctionStackLevel获取
local isUseLoadstring = 0;
local debugger_loadString;
--临时变量
local coroutineCreate;          --用来记录lua原始的coroutine.create函数
local stopConnectTime = 0;      --用来临时记录stop断开连接的时间
local isInMainThread;
local receiveMsgTimer = 0;
local formatPathCache = {};     -- getinfo -> format
local isUserSetClibPath = false;        --用户是否在本文件中自设了clib路径
--5.1/5.3兼容
if _VERSION == "Lua 5.1" then
    debugger_loadString = loadstring;
else
    debugger_loadString = load;
end

--用户在控制台输入信息的环境变量
local env = setmetatable({ }, {
    __index = function( _ , varName )
        local ret =  this.getWatchedVariable( varName, _G.LuaPanda.curStackId , false);
        return ret;
    end,

    __newindex = function( _ , varName, newValue )
        this.setVariableValue( varName, _G.LuaPanda.curStackId, newValue);
    end
});

-----------------------------------------------------------------------------
-- 流程
-----------------------------------------------------------------------------

-- 启动调试器
-- @host adapter端ip, 默认127.0.0.1
-- @port adapter端port ,默认8818
function this.start(host, port)
    host = tostring(host or "127.0.0.1") ;
    port = tonumber(port) or 8818;
    this.printToConsole("Debugger start. connect host:" .. host .. " port:".. tostring(port), 1);
    if sock ~= nil then
        this.printToConsole("[Warning] 调试器已经启动，请不要再次调用start()" , 1);
        return;
    end

    --尝试初次连接
    this.changeRunState(runState.DISCONNECT);
    if not this.reGetSock() then
        this.printToConsole("[Error] Start debugger but get Socket fail , please install luasocket!", 2);
        return;
    end
    connectHost = host;
    connectPort = port;
    local sockSuccess = sock and sock:connect(connectHost, connectPort);
    if sockSuccess ~= nil then
        this.printToConsole("first connect success!");
        this.connectSuccess();
    else
        this.printToConsole("first connect failed!");
        this.changeHookState(hookState.DISCONNECT_HOOK);
    end
end

-- 连接成功，开始初始化
function this.connectSuccess()
    this.changeRunState(runState.WAIT_CMD);
    this.printToConsole("connectSuccess", 1);
    --设置初始状态
    local ret = this.debugger_wait_msg();

    --获取debugger文件路径
    if DebuggerFileName == "" then
        local info = debug.getinfo(1, "S")
        for k,v in pairs(info) do
            if k == "source" then
                DebuggerFileName = v;
                this.printToVSCode("DebuggerFileName:" .. tostring(DebuggerFileName));

                if hookLib ~= nil then
                    hookLib.sync_debugger_path(DebuggerFileName);
                end
            end
        end
    end
    if DebuggerToolsName == "" then
        DebuggerToolsName = tools.getFileSource();
        if hookLib ~= nil then
            hookLib.sync_tools_path(DebuggerToolsName);
        end
    end

    if ret == false then
        this.printToVSCode("[debugger error]初始化未完成, 建立连接但接收初始化消息失败。请更换端口重试", 2);
        return;
    end
    this.printToVSCode("debugger init success", 1);

    this.changeHookState(hookState.ALL_HOOK);
    if hookLib == nil then
        --协程调试
        if coroutineCreate == nil and type(coroutine.create) == "function" then
            this.printToConsole("change coroutine.create");
            coroutineCreate = coroutine.create;
            coroutine.create = function(...)
                local co =  coroutineCreate(...)
                table.insert(coroutinePool,  co);
                --运行状态下，创建协程即启动hook
                this.changeCoroutineHookState();
                return co;
            end
        else
            this.printToConsole("restart coroutine");
            this.changeCoroutineHookState();
        end
    end

end

--重置数据
function this.clearData()
    OSType = nil;
    clibPath = nil;
    -- reset breaks
    breaks = {};
    formatPathCache = {};
    this.breaks = breaks;
    if hookLib ~= nil then
        hookLib.sync_breakpoints(); --清空断点信息
        hookLib.clear_pathcache(); --清空路径缓存
    end
end

--断开连接
function this.disconnect()
    this.printToConsole("Debugger disconnect", 1);
    this.clearData()
    this.changeHookState( hookState.DISCONNECT_HOOK );
    stopConnectTime = os.time();
    this.changeRunState(runState.DISCONNECT);

    if sock ~= nil then
        sock:close();
    end

    if connectPort == nil or connectHost == nil then
        --异常情况处理, 在调用LuaPanda.start()前首先调用了LuaPanda.disconnect()
        this.printToConsole("[Warning] User call LuaPanda.disconnect() before set debug ip & port, please call LuaPanda.start() first!", 2);
        return;
    end

    this.reGetSock();
end

-----------------------------------------------------------------------------
-- 调试器通用方法
-----------------------------------------------------------------------------
-- 返回断点信息
function this.getBreaks()
    return breaks;
end

-- 返回路径相关信息
-- cwd:配置的工程路径  |  info["source"]:通过 debug.getinfo 获得执行文件的路径  |  format：格式化后的文件路径
function this.getCWD()
    local ly = this.getSpecificFunctionStackLevel(lastRunFunction.func);
    if type(ly) ~= "number" then
        ly = 2;
    end
    local runSource = lastRunFunction["source"];
    if runSource == nil and hookLib ~= nil then
        runSource = this.getPath(tostring(hookLib.get_last_source()));
    end
    local info = debug.getinfo(ly, "S");
    return "cwd:      "..cwd .."\ngetinfo:  ".. info["source"] .. "\nformat:   " .. tostring(runSource) ;
end

--返回版本号等配置
function this.getBaseInfo()
    local strTable = {};
    local jitVer = "";
    if jit and jit.version then
        jitVer = "," .. tostring(jit.version);
    end

    strTable[#strTable + 1] = "Lua Ver:" .. _VERSION .. jitVer .." | adapterVer:" .. tostring(adapterVer) .. " | Debugger Ver:" .. tostring(debuggerVer);
    local moreInfoStr = "";
    if hookLib ~= nil then
        local clibVer, forluaVer = hookLib.sync_getLibVersion();
        local clibStr = forluaVer ~= nil and tostring(clibVer) .. " for " .. tostring(math.ceil(forluaVer)) or tostring(clibVer);
        strTable[#strTable + 1] = " | hookLib Ver:" .. clibStr;
        moreInfoStr = moreInfoStr .. "说明: 已加载 libpdebug 库.";
    else
        moreInfoStr = moreInfoStr .. "说明: 未能加载 libpdebug 库。原因请使用 LuaPanda.doctor() 查看";
    end

    local outputIsUseLoadstring = false
    if type(isUseLoadstring) == "number" and isUseLoadstring == 1 then
        outputIsUseLoadstring = true;
    end

    strTable[#strTable + 1] = " | supportREPL:".. tostring(outputIsUseLoadstring);
    strTable[#strTable + 1] = " | useBase64EncodeString:".. tostring(isNeedB64EncodeStr);
    strTable[#strTable + 1] = " | codeEnv:" .. tostring(OSType) .. '\n';
    strTable[#strTable + 1] = moreInfoStr;
    if OSTypeErrTip ~= nil and OSTypeErrTip ~= '' then
        strTable[#strTable + 1] = '\n' ..OSTypeErrTip;
    end
    return table.concat(strTable);
end

--自动诊断当前环境的错误，并输出信息
function this.doctor()
    local strTable = {};
    if debuggerVer ~= adapterVer then
        strTable[#strTable + 1] = "\n- 建议更新版本\nLuaPanda VSCode插件版本是" ..  adapterVer .. ", LuaPanda.lua文件版本是" ..  debuggerVer .. "。建议检查并更新到最新版本。";
        strTable[#strTable + 1] = "\n更新方式   : https://github.com/Tencent/LuaPanda/blob/master/Docs/Manual/update.md";
        strTable[#strTable + 1] = "\nRelease版本: https://github.com/Tencent/LuaPanda/releases";
    end
    --plibdebug
    if hookLib == nil then
        strTable[#strTable + 1] = "\n\n- libpdebug 库没有加载\n";
        if userSetUseClib then
            --用户允许使用clib插件
            if isUserSetClibPath == true then
                --用户自设了clib地址
                strTable[#strTable + 1] = "用户使用 LuaPanda.lua 中 clibPath 变量指定了 plibdebug 的位置: " .. clibPath;
                if this.tryRequireClib("libpdebug", clibPath) then
                    strTable[#strTable + 1] = "\n引用成功";
                else
                    strTable[#strTable + 1] = "\n引用错误:" .. loadclibErrReason;
                end
            else
                --使用默认clib地址
                local clibExt, platform;
                if OSType == "Darwin" then clibExt = "/?.so;"; platform = "mac";
                elseif OSType == "Linux" then clibExt = "/?.so;"; platform = "linux";
                else clibExt = "/?.dll;"; platform = "win";   end
                local lua_ver;
                if _VERSION == "Lua 5.1" then
                    lua_ver = "501";
                else
                    lua_ver = "503";
                end
                local x86Path = clibPath .. platform .."/x86/".. lua_ver .. clibExt;
                local x64Path = clibPath .. platform .."/x86_64/".. lua_ver .. clibExt;

                strTable[#strTable + 1] = "尝试引用x64库: ".. x64Path;
                if this.tryRequireClib("libpdebug", x64Path) then
                    strTable[#strTable + 1] = "\n引用成功";
                else
                    strTable[#strTable + 1] = "\n引用错误:" .. loadclibErrReason;
                    strTable[#strTable + 1] = "\n尝试引用x86库: ".. x86Path;
                    if this.tryRequireClib("libpdebug", x86Path) then
                        strTable[#strTable + 1] = "\n引用成功";
                    else
                        strTable[#strTable + 1] = "\n引用错误:" .. loadclibErrReason;
                    end
                end
            end
        else
            strTable[#strTable + 1] = "原因是" .. loadclibErrReason;
        end
    end

    --path
    --尝试直接读当前getinfo指向的文件，看能否找到。如果能，提示正确，如果找不到，给出提示，建议玩家在这个文件中打一个断点
    --检查断点，文件和当前文件的不同，给出建议
    local runSource = lastRunFilePath;
    if hookLib ~= nil then
        runSource = this.getPath(tostring(hookLib.get_last_source()));
    end

    -- 在精确路径模式下的路径错误检测
    if not autoPathMode and runSource and runSource ~= "" then
        -- 读文件
        local isFileExist = this.fileExists(runSource);
        if not isFileExist then
            strTable[#strTable + 1] = "\n\n- 路径存在问题\n";
            --解析路径，得到文件名，到断点路径中查这个文件名
            local pathArray = this.stringSplit(runSource, '/');
            --如果pathArray和断点能匹配上
            local fileMatch= false;
            for key, _ in pairs(this.getBreaks()) do
                if string.find(key, pathArray[#pathArray], 1, true) then
                    --和断点匹配了
                    fileMatch = true;
                    -- retStr = retStr .. "\n请对比如下路径:\n";
                    strTable[#strTable + 1] = this.getCWD();
                    strTable[#strTable + 1] = "\nfilepath: " .. key;
                    if isAbsolutePath then
                        strTable[#strTable + 1] = "\n说明:从lua虚拟机获取到的是绝对路径，format使用getinfo路径。";
                    else
                        strTable[#strTable + 1] = "\n说明:从lua虚拟机获取到的是相对路径，调试器运行依赖的绝对路径(format)是来源于cwd+getinfo拼接。";
                    end
                    strTable[#strTable + 1] = "\nfilepath是VSCode通过获取到的文件正确路径 , 对比format和filepath，调整launch.json中CWD，或改变VSCode打开文件夹的位置。使format和filepath一致即可。\n如果format和filepath路径仅大小写不一致，设置launch.json中 pathCaseSensitivity:false 可忽略路径大小写";
                end
            end

            if fileMatch == false then
                 --未能和断点匹配
                 strTable[#strTable + 1] = "\n找不到文件:"  .. runSource .. ", 请检查路径是否正确。\n或者在VSCode文件" .. pathArray[#pathArray] .. "中打一个断点后，再执行一次doctor命令，查看路径分析结果。";
            end
        end
    end

    --日志等级对性能的影响
    if logLevel < 1 or consoleLogLevel < 1 then
        strTable[#strTable + 1] = "\n\n- 日志等级\n";
        if logLevel < 1 then
            strTable[#strTable + 1] = "当前日志等级是" ..  logLevel .. ", 会产生大量日志，降低调试速度。建议调整launch.json中logLevel:1";
        end
        if consoleLogLevel < 1 then
            strTable[#strTable + 1] = "当前console日志等级是" ..  consoleLogLevel .. ", 过低的日志等级会降低调试速度，建议调整LuaPanda.lua文件头部consoleLogLevel=2";
        end
    end
    
    if #strTable == 0 then
        strTable[#strTable + 1] = "未检测出问题";
    end
    return table.concat(strTable);
end

function this.fileExists(path)
    local f=io.open(path,"r");
    if f~= nil then io.close(f) return true else return false end
 end

--返回一些信息，帮助用户定位问题
function this.getInfo()
    --用户设置项
    local strTable = {};
    strTable[#strTable + 1] = "\n- Base Info: \n";
    strTable[#strTable + 1] = this.getBaseInfo();
    --已经加载C库，x86/64  未能加载，原因
    strTable[#strTable + 1] = "\n\n- User Setting: \n";
    strTable[#strTable + 1] = "stopOnEntry:" .. tostring(stopOnEntry) .. ' | ';
    -- strTable[#strTable + 1] = "luaFileExtension:" .. luaFileExtension .. ' | ';
    strTable[#strTable + 1] = "logLevel:" .. logLevel .. ' | ' ;
    strTable[#strTable + 1] = "consoleLogLevel:" .. consoleLogLevel .. ' | ';
    strTable[#strTable + 1] = "pathCaseSensitivity:" .. tostring(pathCaseSensitivity) .. ' | ';
    strTable[#strTable + 1] = "attachMode:".. tostring(openAttachMode).. ' | ';
    strTable[#strTable + 1] = "autoPathMode:".. tostring(autoPathMode).. ' | ';

    if userSetUseClib then
        strTable[#strTable + 1] = "useCHook:true";
    else
        strTable[#strTable + 1] = "useCHook:false";
    end

    if logLevel == 0 or consoleLogLevel == 0 then
        strTable[#strTable + 1] = "\n说明:日志等级过低，会影响执行效率。请调整logLevel和consoleLogLevel值 >= 1";
    end

    strTable[#strTable + 1] = "\n\n- Path Info: \n";
    strTable[#strTable + 1] = "clibPath: " .. tostring(clibPath) .. '\n';
    strTable[#strTable + 1] = "debugger: " .. this.getPath(DebuggerFileName) .. '\n';
    strTable[#strTable + 1] = this.getCWD();

    if not autoPathMode then
        if isAbsolutePath then
            strTable[#strTable + 1] = "\n说明:从lua虚拟机获取到的是绝对路径，format使用getinfo路径。" .. winDiskSymbolTip;
        else
            strTable[#strTable + 1] = "\n说明:从lua虚拟机获取到的路径(getinfo)是相对路径，调试器运行依赖的绝对路径(format)是来源于cwd+getinfo拼接。如format路径错误请尝试调整cwd或改变VSCode打开文件夹的位置。也可以在format对应的文件下打一个断点，调整直到format和Breaks Info中断点路径完全一致。" .. winDiskSymbolTip;
        end
    else
        strTable[#strTable + 1] = "\n说明:已开启autoPathMode自动路径模式，调试器会根据getinfo获得的文件名自动查找文件位置，请确保VSCode打开的工程中不存在同名lua文件。";
    end

    if pathErrTip ~= nil and pathErrTip ~= '' then
        strTable[#strTable + 1] = '\n' .. pathErrTip;
    end

    strTable[#strTable + 1] = "\n\n- Breaks Info: \n";
    strTable[#strTable + 1] = this.serializeTable(this.getBreaks(), "breaks");
    return table.concat(strTable);
end

--判断是否在协程中
function this.isInMain()
    return isInMainThread;
end

--添加路径，尝试引用库。完成后把cpath还原，返回引用结果true/false
-- @libName 库名
-- path lib的cpath路径
function this.tryRequireClib(libName , libPath)
    this.printToVSCode("tryRequireClib search : [" .. libName .. "] in "..libPath);
    local savedCpath = package.cpath;
    package.cpath = package.cpath  .. ';' .. libPath;
    this.printToVSCode("package.cpath:" .. package.cpath);
    local status, err = pcall(function() hookLib = require(libName) end);
    if status then
        if type(hookLib) == "table" and this.getTableMemberNum(hookLib) > 0 then
            this.printToVSCode("tryRequireClib success : [" .. libName .. "] in "..libPath);
            package.cpath = savedCpath;
            return true;
        else
            loadclibErrReason = "tryRequireClib fail : require success, but member function num <= 0; [" .. libName .. "] in "..libPath;
            this.printToVSCode(loadclibErrReason);
            hookLib = nil;
            package.cpath = savedCpath;
            return false;
        end
    else
        -- 此处考虑到tryRequireClib会被调用两次，日志级别设置为0，防止输出不必要的信息。
        loadclibErrReason = err;
        this.printToVSCode("[Require clib error]: " .. err, 0);
    end
    package.cpath = savedCpath;
    return false
end
------------------------字符串处理-------------------------
-- 倒序查找字符串 a.b/c查找/ , 返回4
-- @str 被查找的长串
-- @subPattern 查找的子串, 也可以是pattern
-- @plain plane text / pattern
-- @return 未找到目标串返回nil. 否则返回倒序找到的字串位置
function this.revFindString(str, subPattern, plain)
    local revStr = string.reverse(str);
    local _, idx = string.find(revStr, subPattern, 1, plain);
    if idx == nil then return nil end;
    return string.len(revStr) - idx + 1;
end

-- 反序裁剪字符串 如:print(subString("a.b/c", "/"))输出c
-- @return 未找到目标串返回nil. 否则返回被裁剪后的字符串
function this.revSubString(str, subStr, plain)
    local idx = this.revFindString(str, subStr, plain)
    if idx == nil then return nil end;
    return string.sub(str, idx + 1, str.length)
end

-- 把字符串按reps分割成并放入table
-- @str 目标串
-- @reps 分割符。注意这个分隔符是一个pattern
function this.stringSplit( str, separator )
    local retStrTable = {}
    string.gsub(str, '[^' .. separator ..']+', function ( word )
        table.insert(retStrTable, word)
    end)
    return retStrTable;
end

-- 保存CallbackId(通信序列号)
function this.setCallbackId( id )
    if id ~= nil and  id ~= "0" then
        recCallbackId = tostring(id);
    end
end

-- 读取CallbackId(通信序列号)。读取后记录值将被置空
function this.getCallbackId()
    if recCallbackId == nil then
        recCallbackId = "0";
    end
    local id = recCallbackId;
    recCallbackId = "0";
    return id;
end

-- reference from https://www.lua.org/pil/20.1.html
function this.trim (s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

--返回table中成员数量(数字key和非数字key之和)
-- @t 目标table
-- @return 元素数量
function this.getTableMemberNum(t)
    local retNum = 0;
    if type(t) ~= "table" then
        this.printToVSCode("[debugger Error] getTableMemberNum get "..tostring(type(t)), 2)
        return retNum;
    end
    for k,v in pairs(t) do
        retNum = retNum + 1;
    end
    return retNum;
end

-- 生成一个消息Table
function this.getMsgTable(cmd ,callbackId)
    callbackId = callbackId or 0;
    local msgTable = {};
    msgTable["cmd"] = cmd;
    msgTable["callbackId"] = callbackId;
    msgTable["info"] = {};
    return msgTable;
end

function this.serializeTable(tab, name)
    local sTable = tools.serializeTable(tab, name);
    return sTable;
end
------------------------日志打印相关-------------------------
-- 把日志打印在VSCode端
-- @str: 日志内容
-- @printLevel: all(0)/info(1)/error(2)
-- @type: 0:vscode console  1:vscode tip
function this.printToVSCode(str, printLevel, type)
    type = type or 0;
    printLevel = printLevel or 0;
    if currentRunState == runState.DISCONNECT or logLevel > printLevel then
        return;
    end

    local sendTab = {};
    sendTab["callbackId"] = "0";
    if type == 0 then
        sendTab["cmd"] = "log";
    else
        sendTab["cmd"] =  "tip";
    end
    sendTab["info"] = {};
    sendTab["info"]["logInfo"] = tostring(str);
    this.sendMsg(sendTab);
end

-- 把日志打印在控制台
-- @str: 日志内容
-- @printLevel: all(0)/info(1)/error(2)
function this.printToConsole(str, printLevel)
    printLevel = printLevel or 0;
    if consoleLogLevel > printLevel then
        return;
    end
    print("[LuaPanda] ".. tostring(str));
end

-----------------------------------------------------------------------------
-- 提升兼容性方法
-----------------------------------------------------------------------------
--生成平台无关的路径。
--return:nil(error)/path
function this.genUnifiedPath(path)
    if path == "" or path == nil then
        return "";
    end
    --大小写不敏感时，路径全部转为小写
    if pathCaseSensitivity == false then
        path = string.lower(path);
    end
    --统一路径全部替换成/
    path = string.gsub(path, [[\]], "/");
    --处理 /../   /./
    local pathTab = this.stringSplit(path, '/');
    local newPathTab = {};
    for k, v in ipairs(pathTab) do
        if v == '.' then
            --continue
        elseif v == ".." and #newPathTab >= 1 and newPathTab[#newPathTab]:sub(2,2) ~= ':' then
            --newPathTab有元素，最后一项不是X:
            table.remove(newPathTab);
        else
            table.insert(newPathTab, v);
        end
    end
    --重新拼合后如果是mac路径第一位是/
    local newpath = table.concat(newPathTab, '/');
    if path:sub(1,1) == '/' then
        newpath = '/'.. newpath;
    end

    --win下按照winDiskSymbolUpper的设置修改盘符大小
    if "Windows_NT" == OSType then
        if winDiskSymbolUpper then
            newpath = newpath:gsub("^%a:", string.upper);
            winDiskSymbolTip = "路径中Windows盘符已转为大写。"
        else
            newpath = newpath:gsub("^%a:", string.lower);
            winDiskSymbolTip = "路径中Windows盘符已转为小写。"
        end
    end

    return newpath;
end

function this.getCacheFormatPath(source)
    if source == nil then return formatPathCache end;
    return  formatPathCache[source];
end

function this.setCacheFormatPath(source, dest)
    formatPathCache[source] = dest;
end
-----------------------------------------------------------------------------
-- 内存相关
-----------------------------------------------------------------------------
function this.sendLuaMemory()
    local luaMem = collectgarbage("count");
    local sendTab = {};
    sendTab["callbackId"] = "0";
    sendTab["cmd"] = "refreshLuaMemory";
    sendTab["info"] = {};
    sendTab["info"]["memInfo"] = tostring(luaMem);
    this.sendMsg(sendTab);
end

-----------------------------------------------------------------------------
-- 网络相关方法
-----------------------------------------------------------------------------
-- 刷新socket
-- @return true/false 刷新成功/失败
function this.reGetSock()
    if sock ~= nil then
        pcall(function() sock:close() end);
    end
    --call ue4 luasocket
    sock = lua_extension and lua_extension.luasocket and lua_extension.luasocket().tcp();
    if sock == nil then
        --call u3d luasocket
       if pcall(function() sock =  require("socket.core").tcp(); end) then
            this.printToConsole("reGetSock success");
            sock:settimeout(connectTimeoutSec);
       else
            --call custom function to get socket
            if customGetSocketInstance and pcall( function() sock =  customGetSocketInstance(); end ) then
                this.printToConsole("reGetSock custom success");
                sock:settimeout(connectTimeoutSec);      
            else
                this.printToConsole("[Error] reGetSock fail", 2);
                return false;
            end
       end
    else
        --set ue4 luasocket
        this.printToConsole("reGetSock ue4 success");
        sock:settimeout(connectTimeoutSec);
    end
    return true;
end

-- 定时(以函数return为时机) 进行attach连接
function this.reConnect()
    if currentHookState == hookState.DISCONNECT_HOOK then
        if os.time() - stopConnectTime < attachInterval then
            this.printToConsole("Reconnect time less than 1s");
            this.printToConsole("os.time:".. os.time() .. " | stopConnectTime:" ..stopConnectTime);
            return 1;
        end

        if sock == nil then
            this.reGetSock();
        end

        local sockSuccess, status = sock:connect(connectHost, connectPort);
        if sockSuccess == 1 or status == "already connected" then
            this.printToConsole("reconnect success");
            this.connectSuccess();
        else
            this.printToConsole("reconnect failed . retCode:" .. tostring(sockSuccess) .. "  status:" .. status);
            stopConnectTime = os.time();
        end
        return 1;
    end
    return 0;
end

-- 向adapter发消息
-- @sendTab 消息体table
function this.sendMsg( sendTab )
    if isNeedB64EncodeStr and sendTab["info"] ~= nil then
        for _, v in ipairs(sendTab["info"]) do
            if v["type"] == "string" then
                v["value"] = tools.base64encode(v["value"])
            end
        end
    end

    local sendStr = json.encode(sendTab);
    if currentRunState == runState.DISCONNECT then
        this.printToConsole("[debugger error] disconnect but want sendMsg:" .. sendStr, 2);
        this.disconnect();
        return;
    end

    local succ,err;
    if pcall(function() succ,err = sock:send(sendStr..TCPSplitChar.."\n"); end) then
        if succ == nil then
            if err == "closed" then
                this.disconnect();
            end
        end
    end
end

-- 处理 收到的消息
-- @dataStr 接收的消息json
function this.dataProcess( dataStr )
    this.printToVSCode("debugger get:"..dataStr);
    local dataTable = json.decode(dataStr);
    if dataTable == nil then
        this.printToVSCode("[error] Json is error", 2);
        return;
    end

    if dataTable.callbackId ~= "0" then
        this.setCallbackId(dataTable.callbackId);
    end

    if dataTable.cmd == "continue" then
        this.changeRunState(runState.RUN);
        local msgTab = this.getMsgTable("continue", this.getCallbackId());
        this.sendMsg(msgTab);

    elseif dataTable.cmd == "stopOnStep" then
        this.changeRunState(runState.STEPOVER);
        local msgTab = this.getMsgTable("stopOnStep", this.getCallbackId());
        this.sendMsg(msgTab);
        this.changeHookState(hookState.ALL_HOOK);

    elseif dataTable.cmd == "stopOnStepIn" then
        this.changeRunState(runState.STEPIN);
        local msgTab = this.getMsgTable("stopOnStepIn", this.getCallbackId());
        this.sendMsg(msgTab);
        this.changeHookState(hookState.ALL_HOOK);

    elseif dataTable.cmd == "stopOnStepOut" then
        this.changeRunState(runState.STEPOUT);
        local msgTab = this.getMsgTable("stopOnStepOut", this.getCallbackId());
        this.sendMsg(msgTab);
        this.changeHookState(hookState.ALL_HOOK);

    elseif dataTable.cmd == "setBreakPoint" then
        this.printToVSCode("dataTable.cmd == setBreakPoint");
        local bkPath = dataTable.info.path;
        bkPath = this.genUnifiedPath(bkPath);
        if autoPathMode then 
            -- 自动路径模式下，仅保留文件名
            bkPath = this.getFilenameFromPath(bkPath);
        end
        this.printToVSCode("setBreakPoint path:"..tostring(bkPath));
        breaks[bkPath] = dataTable.info.bks;

        -- 当v为空时，从断点列表中去除文件
        for k, v in pairs(breaks) do
            if next(v) == nil then
                breaks[k] = nil;
            end
        end

        --sync breaks to c
        if hookLib ~= nil then
            hookLib.sync_breakpoints();
        end

        if currentRunState ~= runState.WAIT_CMD then
            if hookLib == nil then
                local fileBP, G_BP =this.checkHasBreakpoint(lastRunFilePath);
                if fileBP == false then
                    if G_BP == true then
                        this.changeHookState(hookState.MID_HOOK);
                    else
                        this.changeHookState(hookState.LITE_HOOK);
                    end
                else
                    this.changeHookState(hookState.ALL_HOOK);
                end
            end
        else
            local msgTab = this.getMsgTable("setBreakPoint", this.getCallbackId());
            this.sendMsg(msgTab);
            return;
        end
        --其他时机收到breaks消息
        local msgTab = this.getMsgTable("setBreakPoint", this.getCallbackId());
        this.sendMsg(msgTab);
        -- 打印调试信息
        this.printToVSCode("LuaPanda.getInfo()\n" .. this.getInfo())
        this.debugger_wait_msg();
    elseif dataTable.cmd == "setVariable" then
        if currentRunState == runState.STOP_ON_ENTRY or
            currentRunState == runState.HIT_BREAKPOINT or
            currentRunState == runState.STEPOVER_STOP or
            currentRunState == runState.STEPIN_STOP or
            currentRunState == runState.STEPOUT_STOP then
            local msgTab = this.getMsgTable("setVariable", this.getCallbackId());
            local varRefNum = tonumber(dataTable.info.varRef);
            local newValue = tostring(dataTable.info.newValue);
            local needFindVariable = true;    --如果变量是基础类型，直接赋值，needFindVariable = false; 如果变量是引用类型，needFindVariable = true
            local varName = tostring(dataTable.info.varName);
            -- 根据首末含有" ' 判断 newValue 是否是字符串
            local first_chr = string.sub(newValue, 1, 1);
            local end_chr = string.sub(newValue, -1, -1);
            if first_chr == end_chr then
                if first_chr == "'" or first_chr == '"' then
                    newValue = string.sub(newValue, 2, -2);
                    needFindVariable = false;
                end
            end
            --数字，nil，false，true的处理
            if newValue == "nil" and needFindVariable == true  then newValue = nil; needFindVariable = false;
            elseif newValue == "true" and needFindVariable == true then newValue = true; needFindVariable = false;
            elseif newValue == "false" and needFindVariable == true then newValue = false; needFindVariable = false;
            elseif tonumber(newValue) and needFindVariable == true then newValue = tonumber(newValue); needFindVariable = false;
            end

            -- 如果新值是基础类型，则不需边历
            if dataTable.info.stackId ~= nil and tonumber(dataTable.info.stackId) ~= nil and tonumber(dataTable.info.stackId) > 1 then
                this.curStackId = tonumber(dataTable.info.stackId);
            else
                this.printToVSCode("未能获取到堆栈层级，默认使用 this.curStackId;")
            end

            if varRefNum < 10000 then
                -- 如果修改的是一个 引用变量，那么可直接赋值。但还是要走变量查询过程。查找和赋值过程都需要steakId。 目前给引用变量赋值Object，steak可能有问题
                msgTab.info = this.createSetValueRetTable(varName, newValue, needFindVariable, this.curStackId, variableRefTab[varRefNum]);
            else
                -- 如果修改的是一个基础类型
                local setLimit; --设置检索变量的限定区域
                if varRefNum >= 10000 and varRefNum < 20000 then setLimit = "local";
                elseif varRefNum >= 20000 and varRefNum < 30000 then setLimit = "global";
                elseif varRefNum >= 30000 then setLimit = "upvalue";
                end
                msgTab.info = this.createSetValueRetTable(varName, newValue, needFindVariable, this.curStackId, nil, setLimit);
            end

            this.sendMsg(msgTab);
            this.debugger_wait_msg();
        end

    elseif dataTable.cmd == "getVariable" then
        --仅在停止时处理消息，其他时刻收到此消息，丢弃
        if currentRunState == runState.STOP_ON_ENTRY or
        currentRunState == runState.HIT_BREAKPOINT or
        currentRunState == runState.STEPOVER_STOP or
        currentRunState == runState.STEPIN_STOP or
        currentRunState == runState.STEPOUT_STOP then
            --发送变量给游戏，并保持之前的状态,等待再次接收数据
            --dataTable.info.varRef  10000~20000局部变量
            --                       20000~30000全局变量
            --                       30000~     upvalue
            -- 1000~2000局部变量的查询，2000~3000全局，3000~4000upvalue
            local msgTab = this.getMsgTable("getVariable", this.getCallbackId());
            local varRefNum = tonumber(dataTable.info.varRef);
            if varRefNum < 10000 then
                --查询变量, 此时忽略 stackId
                local varTable = this.getVariableRef(dataTable.info.varRef, true);
                msgTab.info = varTable;
            elseif varRefNum >= 10000 and varRefNum < 20000 then
                --局部变量
                if dataTable.info.stackId ~= nil and tonumber(dataTable.info.stackId) > 1 then
                    this.curStackId = tonumber(dataTable.info.stackId);
                    if type(currentCallStack[this.curStackId - 1]) ~= "table" or  type(currentCallStack[this.curStackId - 1].func) ~= "function" then
                        local str = "getVariable getLocal currentCallStack " .. this.curStackId - 1   .. " Error\n" .. this.serializeTable(currentCallStack, "currentCallStack");
                        this.printToVSCode(str, 2);
                        msgTab.info = {};
                    else
                        local stackId = this.getSpecificFunctionStackLevel(currentCallStack[this.curStackId - 1].func); --去除偏移量
                        local varTable = this.getVariable(stackId, true);
                        msgTab.info = varTable;
                    end
                end

            elseif varRefNum >= 20000 and varRefNum < 30000 then
                --全局变量
                local varTable = this.getGlobalVariable();
                msgTab.info = varTable;
            elseif varRefNum >= 30000 then
                --upValue
                if dataTable.info.stackId ~= nil and tonumber(dataTable.info.stackId) > 1 then
                    this.curStackId = tonumber(dataTable.info.stackId);
                    if type(currentCallStack[this.curStackId - 1]) ~= "table" or  type(currentCallStack[this.curStackId - 1].func) ~= "function" then
                        local str = "getVariable getUpvalue currentCallStack " .. this.curStackId - 1   .. " Error\n" .. this.serializeTable(currentCallStack, "currentCallStack");
                        this.printToVSCode(str, 2);
                        msgTab.info = {};
                    else
                        local varTable = this.getUpValueVariable(currentCallStack[this.curStackId - 1 ].func, true);
                        msgTab.info = varTable;
                    end
                end
            end
            this.sendMsg(msgTab);
            this.debugger_wait_msg();
        end
    elseif dataTable.cmd == "initSuccess" then
        --初始化会传过来一些变量，这里记录这些变量
        --Base64
        if dataTable.info.isNeedB64EncodeStr == "true" then
            isNeedB64EncodeStr = true;
        else
            isNeedB64EncodeStr = false;
        end
        --path
        luaFileExtension = dataTable.info.luaFileExtension
        local TempFilePath = dataTable.info.TempFilePath;
        if TempFilePath:sub(-1, -1) == [[\]] or TempFilePath:sub(-1, -1) == [[/]] then
            TempFilePath = TempFilePath:sub(1, -2);
        end
        TempFilePath_luaString = TempFilePath;
        cwd = this.genUnifiedPath(dataTable.info.cwd);
        --logLevel
        logLevel = tonumber(dataTable.info.logLevel) or 1;
        --autoPathMode
        if dataTable.info.autoPathMode == "true" then
            autoPathMode = true;
        else
            autoPathMode = false;
        end

        if  dataTable.info.pathCaseSensitivity == "true" then
            pathCaseSensitivity =  true;
        else
            pathCaseSensitivity =  false;
        end
 
        --OS type
        if nil == OSType then
            --用户未主动设置OSType, 接收VSCode传来的数据
            if type(dataTable.info.OSType) == "string" then 
                OSType = dataTable.info.OSType;
            else
                OSType = "Windows_NT";
                OSTypeErrTip = "未能检测出OSType, 可能是node os库未能加载，系统使用默认设置Windows_NT"
            end
        else
            --用户自设OSType, 使用用户的设置
        end

        --检测用户是否自设了clib路径
        isUserSetClibPath = false;
        if nil == clibPath then
            --用户未设置clibPath, 接收VSCode传来的数据
            if type(dataTable.info.clibPath) == "string" then  
                clibPath = dataTable.info.clibPath;
            else 
                clibPath = ""; 
                pathErrTip = "未能正确获取libpdebug库所在位置, 可能无法加载libpdebug库。";
            end
        else
            --用户自设clibPath
            isUserSetClibPath = true;
        end

        --查找c++的hook库是否存在
        if tostring(dataTable.info.useCHook) == "true" then
            userSetUseClib = true;      --用户确定使用clib
            if isUserSetClibPath == true then   --如果用户自设了clib路径
                if luapanda_chook ~= nil then
                    hookLib = luapanda_chook;
                else
                    if not(this.tryRequireClib("libpdebug", clibPath)) then
                        this.printToVSCode("Require clib failed, use Lua to continue debug, use LuaPanda.doctor() for more information.", 1);
                    end
                end
            else
                local clibExt, platform;
                if OSType == "Darwin" then clibExt = "/?.so;"; platform = "mac";
                elseif OSType == "Linux" then clibExt = "/?.so;"; platform = "linux";
                else clibExt = "/?.dll;"; platform = "win";   end

                local lua_ver;
                if _VERSION == "Lua 5.1" then
                    lua_ver = "501";
                else
                    lua_ver = "503";
                end

                local x86Path = clibPath.. platform .."/x86/".. lua_ver .. clibExt;
                local x64Path = clibPath.. platform .."/x86_64/".. lua_ver .. clibExt;

                if luapanda_chook ~= nil then
                    hookLib = luapanda_chook;
                else
                    if not(this.tryRequireClib("libpdebug", x64Path) or this.tryRequireClib("libpdebug", x86Path)) then
                        this.printToVSCode("Require clib failed, use Lua to continue debug, use LuaPanda.doctor() for more information.", 1);
                    end
                end
            end
        else
            userSetUseClib = false;
        end

        --adapter版本信息
        adapterVer = tostring(dataTable.info.adapterVersion);
        local msgTab = this.getMsgTable("initSuccess", this.getCallbackId());
        --回传是否使用了lib，是否有loadstring函数
        local isUseHookLib = 0;
        if hookLib ~= nil then
            isUseHookLib = 1;
            --同步数据给c hook
            -- hookLib.sync_config(logLevel, pathCaseSensitivity and 1 or 0, autoPathMode and 1 or 0);
            hookLib.sync_config(logLevel, pathCaseSensitivity and 1 or 0);
            hookLib.sync_tempfile_path(TempFilePath_luaString);
            hookLib.sync_cwd(cwd);
            hookLib.sync_file_ext(luaFileExtension);
        end
        --detect LoadString
        isUseLoadstring = 0;
        if debugger_loadString ~= nil and type(debugger_loadString) == "function" then
            if(pcall(debugger_loadString("return 0"))) then
                isUseLoadstring = 1;
            end
        end
        local tab = { debuggerVer = tostring(debuggerVer) , UseHookLib = tostring(isUseHookLib) , UseLoadstring = tostring(isUseLoadstring), isNeedB64EncodeStr = tostring(isNeedB64EncodeStr) };
        msgTab.info  = tab;
        this.sendMsg(msgTab);
        --上面getBK中会判断当前状态是否WAIT_CMD, 所以最后再切换状态。
        stopOnEntry = dataTable.info.stopOnEntry;
        if dataTable.info.stopOnEntry == "true" then
            this.changeRunState(runState.STOP_ON_ENTRY);   --停止在STOP_ON_ENTRY再接收breaks消息
        else
            this.debugger_wait_msg(1);  --等待1s bk消息 如果收到或超时(没有断点)就开始运行
            this.changeRunState(runState.RUN);
        end

    elseif dataTable.cmd == "getWatchedVariable" then
        local msgTab = this.getMsgTable("getWatchedVariable", this.getCallbackId());
        local stackId = tonumber(dataTable.info.stackId);
        --loadstring系统函数, watch插件加载
        if isUseLoadstring == 1 then
            --使用loadstring
            this.curStackId = stackId;
            local retValue = this.processWatchedExp(dataTable.info);
            msgTab.info = retValue
            this.sendMsg(msgTab);
            this.debugger_wait_msg();
            return;
        else
            --旧的查找方式
            local wv =  this.getWatchedVariable(dataTable.info.varName, stackId, true);
            if wv ~= nil then
                msgTab.info = wv;
            end
            this.sendMsg(msgTab);
            this.debugger_wait_msg();
        end
    elseif dataTable.cmd == "stopRun" then
        --停止hook，已不在处理任何断点信息，也就不会产生日志等。发送消息后等待前端主动断开连接
        local msgTab = this.getMsgTable("stopRun", this.getCallbackId());
        this.sendMsg(msgTab);
        this.disconnect();
    elseif "LuaGarbageCollect" == dataTable.cmd then
        this.printToVSCode("collect garbage!");
        collectgarbage("collect");
        --回收后刷一下内存
        this.sendLuaMemory();
        this.debugger_wait_msg();
    elseif "runREPLExpression" == dataTable.cmd then
        this.curStackId = tonumber(dataTable.info.stackId);
        local retValue = this.processExp(dataTable.info);
        local msgTab = this.getMsgTable("runREPLExpression", this.getCallbackId());
        msgTab.info = retValue
        this.sendMsg(msgTab);
        this.debugger_wait_msg();
    else
    end
end

-- 变量赋值的处理函数。基本逻辑是先从当前栈帧（curStackId）中取 newValue 代表的变量，找到之后再把找到的值通过setVariableValue写回。
-- @varName             被设置值的变量名
-- @newValue            新值的名字，它是一个string
-- @needFindVariable    是否需要查找引用变量。（用户输入的是否是一个Object）
-- @curStackId          当前栈帧（查找和变量赋值用）
-- @assigndVar          被直接赋值（省去查找过程）
-- @setLimit            赋值时的限制范围（local upvalue global）
function this.createSetValueRetTable(varName, newValue, needFindVariable, curStackId,  assigndVar , setLimit)
    local info;
    local getVarRet;
    -- needFindVariable == true，则使用getWatchedVariable处理（可选, 用来支持 a = b (b为变量的情况)）。
    if needFindVariable == false then
        getVarRet = {};
        getVarRet[1] = {variablesReference = 0, value = newValue, name = varName, type = type(newValue)};
    else
        getVarRet =  this.getWatchedVariable( tostring(newValue), curStackId, true);
    end
    if getVarRet ~= nil then
        -- newValue赋变量真实值
        local realVarValue;
        local displayVarValue = getVarRet[1].value;
        if needFindVariable == true then
            if tonumber(getVarRet[1].variablesReference) > 0 then
                realVarValue = variableRefTab[tonumber(getVarRet[1].variablesReference)];
            else
                if getVarRet[1].type == 'number' then realVarValue = tonumber(getVarRet[1].value) end
                if getVarRet[1].type == 'string' then
                    realVarValue = tostring(getVarRet[1].value);
                    local first_chr = string.sub(realVarValue, 1, 1);
                    local end_chr = string.sub(realVarValue, -1, -1);
                    if first_chr == end_chr then
                        if first_chr == "'" or first_chr == '"' then
                            realVarValue = string.sub(realVarValue, 2, -2);
                            displayVarValue  = realVarValue;
                        end
                    end
                end
                if getVarRet[1].type == 'boolean' then
                    if getVarRet[1].value == "true" then
                        realVarValue = true;
                    else
                        realVarValue = false;
                    end
                end
                if getVarRet[1].type == 'nil' then realVarValue = nil end
            end
        else
            realVarValue = getVarRet[1].value;
        end

        local setVarRet;
        if type(assigndVar) ~= table  then
            setVarRet = this.setVariableValue( varName, curStackId, realVarValue, setLimit );
        else
            assigndVar[varName] = realVarValue;
            setVarRet = true;
        end

        if getVarRet[1].type == "string" then
            displayVarValue = '"' .. displayVarValue .. '"';
        end

        if setVarRet ~= false and setVarRet ~= nil then
            local retTip = "变量 ".. varName .." 赋值成功";
            info = { success = "true", name = getVarRet[1].name , type = getVarRet[1].type , value = displayVarValue, variablesReference = tostring(getVarRet[1].variablesReference), tip = retTip};
        else
            info = { success = "false", type = type(realVarValue), value = displayVarValue, tip = "找不到要设置的变量"};
        end

    else
        info = { success = "false", type = nil, value = nil, tip = "输入的值无意义"};
    end
    return info
end

--接收消息
--这里维护一个接收消息队列，因为Lua端未做隔断符保护，变量赋值时请注意其中不要包含隔断符 |*|
-- @timeoutSec 超时时间
-- @return  boolean 成功/失败
function this.receiveMessage( timeoutSec )
    timeoutSec = timeoutSec or MAX_TIMEOUT_SEC;
    sock:settimeout(timeoutSec);
    --如果队列中还有消息，直接取出来交给dataProcess处理
    if #recvMsgQueue > 0 then
        local saved_cmd = recvMsgQueue[1];
        table.remove(recvMsgQueue, 1);
        this.dataProcess(saved_cmd);
        return true;
    end

    if currentRunState == runState.DISCONNECT then
        this.disconnect();
        return false;
    end

    if sock == nil then
        this.printToConsole("[debugger error]接收信息失败  |  reason: socket == nil", 2);
        return;
    end
    local response, err = sock:receive();
    if response == nil then
        if err == "closed" then
            this.printToConsole("[debugger error]接收信息失败  |  reason:"..err, 2);
            this.disconnect();
        end
        return false;
    else

        --判断是否是一条消息，分拆
        local proc_response = string.sub(response, 1, -1 * (TCPSplitChar:len() + 1 ));
        local match_res = string.find(proc_response, TCPSplitChar, 1, true);
        if match_res == nil then
            --单条
            this.dataProcess(proc_response);
        else
            --有粘包
            repeat
                --待处理命令
                local str1 = string.sub(proc_response, 1, match_res - 1);
                table.insert(recvMsgQueue, str1);
                --剩余匹配
                local str2 = string.sub(proc_response, match_res + TCPSplitChar:len() , -1);
                match_res = string.find(str2, TCPSplitChar, 1, true);
            until not match_res
            this.receiveMessage();
        end
        return true;
    end
end

--这里不用循环，在外面处理完消息会在调用回来
-- @timeoutSec 等待时间s
-- @entryFlag 入口标记，用来标识是从哪里调入的
function this.debugger_wait_msg(timeoutSec)
    timeoutSec = timeoutSec or MAX_TIMEOUT_SEC;

    if currentRunState == runState.WAIT_CMD then
        local ret = this.receiveMessage(timeoutSec);
        return ret;
    end

    if currentRunState == runState.STEPOVER or
    currentRunState == runState.STEPIN or
    currentRunState == runState.STEPOUT or
    currentRunState == runState.RUN then
        this.receiveMessage(0);
        return
    end

    if currentRunState == runState.STEPOVER_STOP or
    currentRunState == runState.STEPIN_STOP or
    currentRunState == runState.STEPOUT_STOP or
    currentRunState == runState.HIT_BREAKPOINT or
    currentRunState == runState.STOP_ON_ENTRY
    then
        this.sendLuaMemory();
        this.receiveMessage(MAX_TIMEOUT_SEC);
        return
    end
end

-----------------------------------------------------------------------------
-- 调试器核心方法
-----------------------------------------------------------------------------

------------------------堆栈管理-------------------------


--getStackTable需要建立stackTable，保存每层的lua函数实例(用来取upvalue)，保存函数展示层级和ly的关系(便于根据前端传来的stackId查局部变量)
-- @level 要获取的层级
function this.getStackTable( level )
    local functionLevel = 0
    if hookLib ~= nil then
        functionLevel = level or HOOK_LEVEL;
    else
        functionLevel = level or this.getSpecificFunctionStackLevel(lastRunFunction.func);
    end
    local stackTab = {};
    local userFuncSteakLevel = 0; --用户函数的steaklevel
    repeat
        local info = debug.getinfo(functionLevel, "SlLnf")
        if info == nil then
            break;
        end
        if info.source == "=[C]" then
            break;
        end

        local ss = {};
        ss.file = this.getPath(info);
        ss.name = "文件名"; --这里要做截取
        ss.line = tostring(info.currentline);
        --使用hookLib时，堆栈有偏移量，这里统一调用栈顶编号2
        local ssindex = functionLevel - 3;
        if hookLib ~= nil then
            ssindex = ssindex + 2;
        end
        ss.index = tostring(ssindex);
        table.insert(stackTab,ss);
        --把数据存入currentCallStack
        local callStackInfo = {};
        callStackInfo.name = ss.file;
        callStackInfo.line = ss.line;
        callStackInfo.func = info.func;     --保存的function
        callStackInfo.realLy = functionLevel;              --真实堆栈层functionLevel(仅debug时用)
        table.insert(currentCallStack, callStackInfo);

        --level赋值
        if userFuncSteakLevel == 0 then
            userFuncSteakLevel = functionLevel;
        end
        functionLevel = functionLevel + 1;
    until info == nil
    return stackTab, userFuncSteakLevel;
end

--这个方法是根据工程中的cwd和luaFileExtension修改
-- @info getInfo获取的包含调用信息table
function this.getPath( info )
    local filePath = info;
    if type(info) == "table" then
        filePath = info.source;
    end
    --尝试从Cache中获取路径
    local cachePath = this.getCacheFormatPath(filePath);
    if cachePath~= nil and type(cachePath) == "string" then
        return cachePath;
    end

    -- originalPath是getInfo的原始路径，后面用来填充缓存key
    local originalPath = filePath;
    
    --后缀处理
    if luaFileExtension ~= "" then
        --判断后缀中是否包含%1等魔法字符.用于从lua虚拟机获取到的路径含.的情况
        if string.find(luaFileExtension, "%%%d") then
            filePath = string.gsub(filePath, "%.[%w%.]+$", luaFileExtension);
        else
            filePath = string.gsub(filePath, "%.[%w%.]+$", "");
            filePath = filePath .. "." .. luaFileExtension;
        end
    end

    --如果路径头部有@,去除
    if filePath:sub(1,1) == '@' then
        filePath = filePath:sub(2);
    end

    if not autoPathMode then
        --绝对路径和相对路径的处理  |  若在Mac下以/开头，或者在Win下以*:开头，说明是绝对路径，不需要再拼。
        if filePath:sub(1,1) == [[/]] or filePath:sub(1,2):match("^%a:") then
            isAbsolutePath = true;
        else
            isAbsolutePath = false;
            if cwd ~= "" then
                --查看filePath中是否包含cwd
                local matchRes = string.find(filePath, cwd, 1, true);
                if matchRes == nil then
                    filePath = cwd.."/"..filePath;
                end
            end
        end
    end
    filePath = this.genUnifiedPath(filePath);

    if autoPathMode then
        -- 自动路径模式下，只保留文件名
        filePath = this.getFilenameFromPath(filePath)
    end
    --放入Cache中缓存
    this.setCacheFormatPath(originalPath, filePath);
    return filePath;
end

--从路径中获取文件名
function this.getFilenameFromPath(path)
    if path == nil then 
        return ''; 
    end

    return string.match(path, "([^/]*)$");
end

--获取当前函数的堆栈层级
--原理是向上查找，遇到DebuggerFileName就调过。但是可能存在代码段和C导致不确定性。目前使用getSpecificFunctionStackLevel代替。
function this.getCurrentFunctionStackLevel()
    -- print(debug.traceback("===getCurrentFunctionStackLevel Stack trace==="))
    local funclayer = 2;
    repeat
        local info = debug.getinfo(funclayer, "S"); --通过name来判断
        if info ~= nil then
            local matchRes = ((info.source == DebuggerFileName) or (info.source == DebuggerToolsName));
            if matchRes == false then
                return (funclayer - 1);
            end
        end
        funclayer = funclayer + 1;
    until not info
    return 0;
end

--获取指定函数的堆栈层级
--通常用来获取最后一个用户函数的层级，用法是从currentCallStack取用户点击的栈，再使用本函数取对应层级。
-- @func 被获取层级的function
function this.getSpecificFunctionStackLevel( func )
    local funclayer = 2;
    repeat
        local info = debug.getinfo(funclayer, "f"); --通过name来判断
        if info ~= nil then
            if info.func == func then
                return (funclayer - 1);
            end
        end
        funclayer = funclayer + 1;
    until not info
    return 0;
end

--检查当前堆栈是否是Lua
-- @checkLayer 指定的栈层
function this.checkCurrentLayerisLua( checkLayer )
    local info = debug.getinfo(checkLayer, "S");
    if info == nil then
        return nil;
    end
    info.source = this.genUnifiedPath(info.source);
    if info ~= nil then
        for k,v in pairs(info) do
            if k == "what" then
                if v == "C" then
                    return false;
                else
                    return true;
                end
            end
        end
    end
    return nil;
end


------------------------断点处理-------------------------
-- 参数info是当前堆栈信息
-- @info getInfo获取的当前调用信息
function this.isHitBreakpoint( info )
    local curLine = tostring(info.currentline);
    local breakpointPath = info.source;
    local isPathHit = false;
    
    if breaks[breakpointPath] then
        isPathHit = true;
    end

    if isPathHit then
        for k,v in ipairs(breaks[breakpointPath]) do
            if tostring(v["line"]) == tostring(curLine) then
                -- type是TS中的枚举类型，其定义在BreakPoint.tx文件中
                --[[
                    enum BreakpointType {
                        conditionBreakpoint = 0,
                        logPoint,
                        lineBreakpoint
                    }
                ]]

                if v["type"] == "0" then
                    -- condition breakpoint
                    -- 注意此处不要使用尾调用，否则会影响调用栈，导致Lua5.3和Lua5.1中调用栈层级不同
                    local conditionRet = this.IsMeetCondition(v["condition"]);
                    return conditionRet;
                elseif v["type"] == "1" then
                    -- log point
                    this.printToVSCode("[log point output]: " .. v["logMessage"], 1);
                else
                    -- line breakpoint
                    return true;
                end
            end
        end
    end
    return false;
end

-- 条件断点处理函数
-- 返回true表示条件成立
-- @conditionExp 条件表达式
function this.IsMeetCondition(conditionExp)
    -- 判断条件之前更新堆栈信息
    currentCallStack = {};
    variableRefTab = {};
    variableRefIdx = 1;
    this.getStackTable();
    this.curStackId = 2; --在用户空间最上层执行

    local conditionExpTable = {["varName"] = conditionExp}
    local retTable = this.processWatchedExp(conditionExpTable)

    local isMeetCondition = false;
    local function HandleResult()
        if retTable[1]["isSuccess"] == "true" then
            if retTable[1]["value"] == "nil" or (retTable[1]["value"] == "false" and retTable[1]["type"] == "boolean") then
                isMeetCondition = false;
            else
                isMeetCondition = true;
            end
        else
            isMeetCondition = false;
        end
    end

    xpcall(HandleResult, function() isMeetCondition = false; end)
    return isMeetCondition;
end

--加入断点函数
function this.BP()
    this.printToConsole("BP()");
    if hookLib == nil then
        if currentHookState == hookState.DISCONNECT_HOOK then
            this.printToConsole("BP() but NO HOOK");
            return;
        end

        local co, isMain = coroutine.running();
        if _VERSION == "Lua 5.1" then
            if co == nil then
                isMain = true;
            else
                isMain = false;
            end
        end

        if isMain == true then
            this.printToConsole("BP() in main");
        else
            this.printToConsole("BP() in coroutine");
            debug.sethook(co, this.debug_hook, "lrc");
        end
        hitBP = true;
    else
        if hookLib.get_libhook_state() == hookState.DISCONNECT_HOOK then
            this.printToConsole("BP() but NO C HOOK");
            return;
        end

        --clib, set hitBP
        hookLib.sync_bp_hit(1);
    end
    this.changeHookState(hookState.ALL_HOOK);
    return true;
end

-- 检查当前文件中是否有断点
-- 如果填写参数fileName  返回fileName中有无断点， 全局有无断点
-- fileName为空，返回全局是否有断点
function this.checkHasBreakpoint(fileName)
    local hasBk = false;
    --有无全局断点
    if next(breaks) == nil then
        hasBk = false;
    else
        hasBk = true;
    end
    --当前文件中是否有断点
    if fileName ~= nil then
        return breaks[fileName] ~= nil, hasBk;
    else
        return hasBk;
    end
end

function this.checkfuncHasBreakpoint(sLine, eLine, fileName)
    if breaks[fileName] == nil then
        return false;
    end
    sLine = tonumber(sLine);
    eLine = tonumber(eLine);

    --起始行号>结束行号，或者sLine = eLine = 0
    if sLine >= eLine then
        return true;
    end

    if #breaks[fileName] <= 0 then
        return false;
    else
        for k,v in ipairs(breaks[fileName]) do
            if tonumber(v.line) > sLine and tonumber(v.line) <= eLine then
                return true;
            end
        end
    end
    return false;
end
------------------------HOOK模块-------------------------
-- 钩子函数
-- @event 执行状态(call,return,line)
-- @line    行号
function this.debug_hook(event, line)
    if this.reConnect() == 1 then return; end

    if logLevel == 0 then
        local logTable = {"-----enter debug_hook-----\n", "event:", event, "  line:", tostring(line), " currentHookState:",currentHookState," currentRunState:", currentRunState};
        local logString = table.concat(logTable);
        this.printToVSCode(logString);
    end

    --litehook 仅非阻塞接收断点
    if currentHookState ==  hookState.LITE_HOOK then
        local ti = os.time();
        if ti - receiveMsgTimer > 1 then
            this.debugger_wait_msg(0);
            receiveMsgTimer = ti;
        end
        return;
    end

    --运行中
    local info;
    local co, isMain = coroutine.running();
    if _VERSION == "Lua 5.1" then
        if co == nil then
            isMain = true;
        else
            isMain = false;
        end
    end
    isInMainThread = isMain;
    if isMain == true then
        info = debug.getinfo(2, "Slf")
    else
        info = debug.getinfo(co, 2, "Slf")
    end
    info.event = event;

    this.real_hook_process(info);
end

function this.real_hook_process(info)
    local jumpFlag = false;
    local event = info.event;

    --如果当前行在Debugger中，不做处理
    local matchRes = ((info.source == DebuggerFileName) or (info.source == DebuggerToolsName));
    if matchRes == true then
        return;
    end

    --即使MID hook在C中, 或者是Run或者单步时也接收消息
    if currentRunState == runState.RUN or
    currentRunState == runState.STEPOVER or
    currentRunState == runState.STEPIN or
    currentRunState == runState.STEPOUT then
        local ti = os.time();
        if ti - receiveMsgTimer > 1 then
            this.debugger_wait_msg(0);
            receiveMsgTimer = ti;
        end
    end

    --不处理C函数
    if info.source == "=[C]" then
        this.printToVSCode("current method is C");
        return;
    end

    --不处理 slua "temp buffer"
    if info.source == "temp buffer" then
        this.printToVSCode("current method is in temp buffer");
        return;
    end

    --不处理 xlua "chunk"
    if info.source == "chunk" then
        this.printToVSCode("current method is in chunk");
        return;
    end

    --lua 代码段的处理，目前暂不调试代码段。
    if info.short_src:match("%[string \"")  then
            --当shortSrc中出现[string时]。要检查一下source, 区别是路径还是代码段. 方法是看路径中有没有\t \n ;
            if info.source:match("[\n;=]") then
                --是代码段，调过
                this.printToVSCode("hook jump Code String!");
                jumpFlag = true;
            end
    end

    --标准路径处理
    if jumpFlag == false then
        info.source = this.getPath(info);
    end
    --本次执行的函数和上次执行的函数作对比，防止在一行停留两次
    if lastRunFunction["currentline"] == info["currentline"] and lastRunFunction["source"] == info["source"] and lastRunFunction["func"] == info["func"] and lastRunFunction["event"] == event then
        this.printToVSCode("run twice");
    end
    --记录最后一次调用信息
    if jumpFlag == false then
        lastRunFunction = info;
        lastRunFunction["event"] = event;
        lastRunFilePath = info.source;
    end
    --输出函数信息到前台
    if logLevel == 0 and jumpFlag == false then
        local logTable = {"[lua hook] event:", tostring(event), " currentRunState:",tostring(currentRunState)," currentHookState:",tostring(currentHookState)," jumpFlag:", tostring(jumpFlag)};
        for k,v in pairs(info) do
            table.insert(logTable, tostring(k));
            table.insert(logTable, ":");
            table.insert(logTable, tostring(v));
            table.insert(logTable, " ");
        end
        local logString = table.concat(logTable);
        this.printToVSCode(logString);
    end

    --仅在line时做断点判断。进了断点之后不再进入本次STEP类型的判断，用Aflag做标记
    local isHit = false;
    if tostring(event) == "line" and jumpFlag == false then
        if currentRunState == runState.RUN or currentRunState == runState.STEPOVER or currentRunState == runState.STEPIN or currentRunState == runState.STEPOUT then
            --断点判断
            isHit = this.isHitBreakpoint(info) or hitBP;
            if isHit == true then
                this.printToVSCode(" + HitBreakpoint true");
                hitBP = false; --hitBP是断点硬性命中标记
                --计数器清0
                stepOverCounter = 0;
                stepOutCounter = 0;
                this.changeRunState(runState.HIT_BREAKPOINT);
                --发消息并等待
                this.SendMsgWithStack("stopOnBreakpoint");
            end
        end
    end

    if  isHit == true then
        return;
    end

    if currentRunState == runState.STEPOVER then
        -- line stepOverCounter!= 0 不作操作
        -- line stepOverCounter == 0 停止
        if event == "line" and stepOverCounter <= 0 and jumpFlag == false then
            stepOverCounter = 0;
            this.changeRunState(runState.STEPOVER_STOP)
            this.SendMsgWithStack("stopOnStep");
        elseif event == "return" or event == "tail return" then
            --5.1中是tail return
            if stepOverCounter ~= 0 then
                stepOverCounter = stepOverCounter - 1;
            end
        elseif event == "call" then
            stepOverCounter = stepOverCounter + 1;
        end
    elseif currentRunState == runState.STOP_ON_ENTRY then
        --在Lua入口点处直接停住
        if event == "line" and jumpFlag == false then
            --初始化内存分析的变量
            -- MemProfiler.getSystemVar();
            --这里要判断一下是Lua的入口点，否则停到
            this.SendMsgWithStack("stopOnEntry");
        end
    elseif currentRunState == runState.STEPIN then
        if event == "line" and jumpFlag == false then
            this.changeRunState(runState.STEPIN_STOP)
            this.SendMsgWithStack("stopOnStepIn");
        end
    elseif currentRunState == runState.STEPOUT then
        --line 不做操作
        --in 计数器+1
        --out 计数器-1
        if jumpFlag == false then
            if stepOutCounter <= -1 then
                stepOutCounter = 0;
                this.changeRunState(runState.STEPOUT_STOP)
                this.SendMsgWithStack("stopOnStepOut");
            end
        end

        if event == "return" or event == "tail return" then
            stepOutCounter = stepOutCounter - 1;
        elseif event == "call" then
            stepOutCounter = stepOutCounter + 1;
        end
    end

    --在RUN时检查并改变状态
    if hookLib == nil then
        if currentRunState == runState.RUN and jumpFlag == false and currentHookState ~= hookState.DISCONNECT_HOOK then
            local fileBP, G_BP = this.checkHasBreakpoint(lastRunFilePath);
            if fileBP == false then
                --文件无断点
                if G_BP == true then
                    this.changeHookState(hookState.MID_HOOK);
                else
                    this.changeHookState(hookState.LITE_HOOK);
                end
            else
                --文件有断点, 判断函数内是否有断点
                local funHasBP = this.checkfuncHasBreakpoint(lastRunFunction.linedefined, lastRunFunction.lastlinedefined, lastRunFilePath);
                if  funHasBP then
                    --函数定义范围内
                    this.changeHookState(hookState.ALL_HOOK);
                else
                    this.changeHookState(hookState.MID_HOOK);
                end
            end

            --MID_HOOK状态下，return需要在下一次hook检查文件（return时，还是当前文件，检查文件时状态无法转换）
            if  (event == "return" or event == "tail return") and currentHookState == hookState.MID_HOOK then
                this.changeHookState(hookState.ALL_HOOK);
            end
        end
    end
end

-- 向Vscode发送标准通知消息，cmdStr是消息类型
-- @cmdStr  命令字
function this.SendMsgWithStack(cmdStr)
    local msgTab = this.getMsgTable(cmdStr);
    local userFuncLevel = 0;
    msgTab["stack"] , userFuncLevel= this.getStackTable();
    if userFuncLevel ~= 0 then
        lastRunFunction["func"] = debug.getinfo( (userFuncLevel - 1) , 'f').func;
    end
    this.sendMsg(msgTab);
    this.debugger_wait_msg();
end

-- hook状态改变
-- @s 目标状态
function this.changeHookState( s )
    if hookLib == nil and currentHookState == s then
        return;
    end

    this.printToConsole("change hook state :"..s)
    if s ~= hookState.DISCONNECT_HOOK then
        this.printToVSCode("change hook state : "..s)
    end

    currentHookState = s;
    if s == hookState.DISCONNECT_HOOK then
        --为了实现通用attach模式，require即开始hook，利用r作为时机发起连接
        if openAttachMode == true then
            if hookLib then hookLib.lua_set_hookstate(hookState.DISCONNECT_HOOK); else debug.sethook(this.debug_hook, "r", 1000000); end
        else
            if hookLib then hookLib.endHook(); else debug.sethook(); end
        end
    elseif s == hookState.LITE_HOOK then
        if hookLib then hookLib.lua_set_hookstate(hookState.LITE_HOOK); else debug.sethook(this.debug_hook, "r"); end
    elseif s == hookState.MID_HOOK then
        if hookLib then hookLib.lua_set_hookstate(hookState.MID_HOOK); else debug.sethook(this.debug_hook, "rc"); end
    elseif s == hookState.ALL_HOOK then
        if hookLib then hookLib.lua_set_hookstate(hookState.ALL_HOOK); else debug.sethook(this.debug_hook, "lrc");end
    end
    --coroutine
    if hookLib == nil then
        this.changeCoroutineHookState();
    end
end

-- 运行状态机，状态变更
-- @s 目标状态
-- @isFromHooklib 1:从libc库中发来的状态改变 | 0:lua发来的状态改变
function this.changeRunState(s , isFromHooklib)
    local msgFrom;
    if isFromHooklib == 1 then
        msgFrom = "libc";
    else
        msgFrom = "lua";
    end

    --WAIT_CMD状态会等待接收消息，以下两个状态下不能发消息
    this.printToConsole("changeRunState :"..s.. " | from:"..msgFrom);
    if s ~= runState.DISCONNECT and s ~= runState.WAIT_CMD then
        this.printToVSCode("changeRunState :"..s.." | from:"..msgFrom);
    end

    if hookLib ~= nil and isFromHooklib ~= 1 then
        hookLib.lua_set_runstate(s);
    end
    currentRunState = s;
    --状态切换时，清除记录栈信息的状态
    currentCallStack = {};
    variableRefTab = {};
    variableRefIdx = 1;
end

-- 修改协程状态
-- @s hook标志位
function this.changeCoroutineHookState(s)
    s = s or currentHookState;
    this.printToConsole("change [Coroutine] HookState: "..tostring(s));
    for k ,co in pairs(coroutinePool) do
        if coroutine.status(co) == "dead" then
            table.remove(coroutinePool, k)
        else
            if s == hookState.DISCONNECT_HOOK then
                if openAttachMode == true then
                    debug.sethook(co, this.debug_hook, "r", 1000000);
                else
                    debug.sethook(co, this.debug_hook, "");
                end
            elseif s == hookState.LITE_HOOK then debug.sethook(co , this.debug_hook, "r");
            elseif s == hookState.MID_HOOK then debug.sethook(co , this.debug_hook, "rc");
            elseif s == hookState.ALL_HOOK then debug.sethook(co , this.debug_hook, "lrc");
            end
        end
    end
end
-------------------------变量处理相关-----------------------------

--清空REPL的env环境
function this.clearEnv()
    if this.getTableMemberNum(env) > 0 then
        --清空env table
        env = setmetatable({}, getmetatable(env));
    end
end

--返回REPL的env环境
function this.showEnv()
    return env;
end

-- 用户观察table的查找函数。用tableVarName作为key去查逐层级查找realVar是否匹配
-- @tableVarName 是用户观察的变量名，已经按层级被解析成table。比如用户输出a.b.c，tableVarName是 a = { b = { c } }
-- @realVar 是待查询 table
-- @return  返回查到的table。没查到返回nil
function this.findTableVar( tableVarName,  realVar)
    if type(tableVarName) ~= "table" or type(realVar) ~= "table" then
        return nil;
    end

    local layer = 2;
    local curVar = realVar;
    local jumpOutFlag = false;
    repeat
        if tableVarName[layer] ~= nil then
            --这里优先展示数字key，比如a{"1" = "aa", [1] = "bb"} 会展示[1]的值
            local tmpCurVar = nil;
            xpcall(function() tmpCurVar = curVar[tonumber(tableVarName[layer])]; end , function() tmpCurVar = nil end );
            if tmpCurVar == nil then
                xpcall(function() curVar = curVar[tostring(tableVarName[layer])]; end , function() curVar = nil end );
            else
                curVar = tmpCurVar;
            end
            layer = layer + 1;
            if curVar == nil then
                return nil;
            end
        else
            --找到
            jumpOutFlag = true;
        end
    until(jumpOutFlag == true)
    return curVar;
end

-- 根据传入信息生成返回的变量信息
-- @variableName    变量名
-- @variableIns        变量实例
-- @return              包含变量信息的格式化table
function this.createWatchedVariableInfo(variableName, variableIns)
    local var = {};
    var.name = variableName;
    var.type = tostring(type(variableIns));
    xpcall(function() var.value = tostring(variableIns) end , function() var.value = tostring(type(variableIns)) .. " [value can't trans to string]" end );
    var.variablesReference = "0";  --这个地方必须用“0”， 以免variableRefTab[0]出错

    if var.type == "table" or var.type == "function" then
        var.variablesReference = variableRefIdx;
        variableRefTab[variableRefIdx] = variableIns;
        variableRefIdx = variableRefIdx + 1;
        if var.type == "table" then
            local memberNum = this.getTableMemberNum(variableIns);
            var.value = memberNum .." Members ".. var.value;
        end
    elseif var.type == "string" then
        var.value = '"' ..variableIns.. '"';
    end
    return var;
end

-- 设置 global 变量
-- @varName 被修改的变量名
-- @newValue 新的值
function this.setGlobal(varName, newValue)
    _G[varName] = newValue;
    this.printToVSCode("[setVariable success] 已设置  _G.".. varName .. " = " .. tostring(newValue) );
    return true;
end

-- 设置 upvalue 变量
-- @varName 被修改的变量名
-- @newValue 新的值
-- @stackId 变量所在stack栈层
-- @tableVarName 变量名拆分成的数组
function this.setUpvalue(varName, newValue, stackId, tableVarName)
    local ret = false;
    local upTable = this.getUpValueVariable(currentCallStack[stackId - 1 ].func, true);
    for i, realVar in ipairs(upTable) do
        if realVar.name == varName then
            if #tableVarName > 0 and type(realVar) == "table" then
                --处理a.b.c的table类型
                local findRes = this.findTableVar(tableVarName,  variableRefTab[realVar.variablesReference]);
                if findRes ~= nil then
                    --命中
                        local setVarRet = debug.setupvalue (currentCallStack[stackId - 1 ].func, i, newValue);
                        if setVarRet == varName then
                            this.printToConsole("[setVariable success1] 已设置 upvalue ".. varName .. " = " .. tostring(newValue) );
                            ret = true;
                        else
                            this.printToConsole("[setVariable error1] 未能设置 upvalue ".. varName .. " = " .. tostring(newValue).." , 返回结果: ".. tostring(setVarRet));
                        end
                        return ret;
                end
            else
                --命中
                local setVarRet = debug.setupvalue (currentCallStack[stackId - 1 ].func, i, newValue);
                if setVarRet == varName then
                    this.printToConsole("[setVariable success] 已设置 upvalue ".. varName .. " = " .. tostring(newValue) );
                    ret = true;
                else
                    this.printToConsole("[setVariable error] 未能设置 upvalue ".. varName .. " = " .. tostring(newValue).." , 返回结果: ".. tostring(setVarRet));
                end
                return ret;
            end
        end
    end
    return ret;
end

-- 设置local 变量
-- @varName 被修改的变量名
-- @newValue 新的值
-- @tableVarName 变量名拆分成的数组
function this.setLocal( varName, newValue, tableVarName, stackId)
    local istackId = tonumber(stackId);
    local offset = (istackId and istackId - 2) or 0;
    local layerVarTab, ly = this.getVariable(nil , true, offset);
    local ret = false;
    for i, realVar in ipairs(layerVarTab) do
        if realVar.name == varName then
            if #tableVarName > 0 and type(realVar) == "table" then
                --处理a.b.c的table类型
                local findRes = this.findTableVar(tableVarName,  variableRefTab[realVar.variablesReference]);
                if findRes ~= nil then
                        --命中
                        local setVarRet = debug.setlocal(ly , layerVarTab[i].index, newValue);
                        if setVarRet == varName then
                            this.printToConsole("[setVariable success1] 已设置 local ".. varName .. " = " .. tostring(newValue) );
                            ret = true;
                        else
                            this.printToConsole("[setVariable error1] 未能设置 local ".. varName .. " = " .. tostring(newValue).." , 返回结果: ".. tostring(setVarRet));
                        end
                        return ret;
                end
            else

                local setVarRet = debug.setlocal(ly , layerVarTab[i].index, newValue);

                if setVarRet == varName then
                    this.printToConsole("[setVariable success] 已设置 local ".. varName .. " = " .. tostring(newValue) );
                    ret = true;
                else
                    this.printToConsole("[setVariable error] 未能设置 local ".. varName .. " = " .. tostring(newValue) .." , 返回结果: ".. tostring(setVarRet));
                end
                return ret;
            end
        end
    end
    return ret;
end


-- 设置变量的值
-- @varName 被修改的变量名
-- @curStackId 调用栈层级(仅在固定栈层查找)
-- @newValue 新的值
-- @limit 限制符， 10000表示仅在局部变量查找 ，20000 global, 30000 upvalue
function this.setVariableValue (varName, stackId, newValue , limit)
    this.printToConsole("setVariableValue | varName:" .. tostring(varName) .. " stackId:".. tostring(stackId) .." newValue:" .. tostring(newValue) .." limit:"..tostring(limit) )
    if tostring(varName) == nil or tostring(varName) == "" then
        --赋值错误
        this.printToConsole("[setVariable Error] 被赋值的变量名为空", 2 );
        this.printToVSCode("[setVariable Error] 被赋值的变量名为空", 2 );
        return false;
    end

    --支持a.b.c形式。切割varName
    local tableVarName = {};
    if varName:match('%.') then
        tableVarName = this.stringSplit(varName , '%.');
        if type(tableVarName) ~= "table" or #tableVarName < 1 then
            return false;
        end
        varName = tableVarName[1];
    end

    if limit == "local" then
        local ret = this.setLocal( varName, newValue, tableVarName, stackId);
        return ret;
    elseif limit == "upvalue" then
        local ret = this.setUpvalue(varName, newValue, stackId, tableVarName);
        return ret
    elseif limit == "global" then
        local ret = this.setGlobal(varName, newValue);
        return ret;
    else
        local ret = this.setLocal( varName, newValue, tableVarName, stackId) or this.setUpvalue(varName, newValue, stackId, tableVarName) or this.setGlobal(varName, newValue);
        this.printToConsole("set Value res :".. tostring(ret));
        return ret;
    end
end

-- 按照local -> upvalue -> _G 顺序查找观察变量
-- @varName 用户输入的变量名
-- @stackId 调用栈层级(仅在固定栈层查找)
-- @isFormatVariable    是否把变量格式化为VSCode接收的形式
-- @return 查到返回信息，查不到返回nil
function this.getWatchedVariable( varName , stackId , isFormatVariable )
    this.printToConsole("getWatchedVariable | varName:" .. tostring(varName) .. " stackId:".. tostring(stackId) .." isFormatVariable:" .. tostring(isFormatVariable) )
    if tostring(varName) == nil or tostring(varName) == "" then
        return nil;
    end

    if type(currentCallStack[stackId - 1]) ~= "table" or  type(currentCallStack[stackId - 1].func) ~= "function" then
        local str = "getWatchedVariable currentCallStack " .. stackId - 1 .. " Error\n" .. this.serializeTable(currentCallStack, "currentCallStack");
        this.printToVSCode(str, 2);
        return nil;
    end

    --orgname 记录原名字. 用来处理a.b.c的形式
    local orgname = varName;
    --支持a.b.c形式。切割varName
    local tableVarName = {};
    if varName:match('%.') then
        tableVarName = this.stringSplit(varName , '%.');
        if type(tableVarName) ~= "table" or #tableVarName < 1 then
            return nil;
        end
        varName = tableVarName[1];
    end
    --用来返回，带有查到变量的table
    local varTab = {};
    local ly = this.getSpecificFunctionStackLevel(currentCallStack[stackId - 1].func);

    local layerVarTab = this.getVariable(ly, isFormatVariable);
    local upTable = this.getUpValueVariable(currentCallStack[stackId - 1 ].func, isFormatVariable);
    local travelTab = {};
    table.insert(travelTab, layerVarTab);
    table.insert(travelTab, upTable);
    for _, layerVarTab in ipairs(travelTab) do
        for i,realVar in ipairs(layerVarTab) do
            if realVar.name == varName then
                if #tableVarName > 0 and type(realVar) == "table" then
                    --处理a.b.c的table类型
                    local findRes = this.findTableVar(tableVarName,  variableRefTab[realVar.variablesReference]);
                    if findRes ~= nil then
                        --命中
                        if isFormatVariable then
                            local var = this.createWatchedVariableInfo( orgname , findRes );
                            table.insert(varTab, var);
                            return varTab;
                        else
                            return findRes.value;
                        end
                    end
                else
                    --命中
                    if isFormatVariable then
                        table.insert(varTab, realVar);
                        return varTab;
                    else
                        return realVar.value;
                    end
                end
            end
        end
    end

    --在全局变量_G中查找
    if _G[varName] ~= nil then
        --命中
        if #tableVarName > 0 and type(_G[varName]) == "table" then
            local findRes = this.findTableVar(tableVarName,  _G[varName]);
            if findRes ~= nil then
                if isFormatVariable then
                    local var = this.createWatchedVariableInfo( orgname , findRes );
                    table.insert(varTab, var);
                    return varTab;
                else
                    return findRes;
                end
            end
        else
            if isFormatVariable then
                local var = this.createWatchedVariableInfo( varName , _G[varName] );
                table.insert(varTab, var);
                return varTab;
            else
                return _G[varName];
            end
        end
    end
    this.printToConsole("getWatchedVariable not find variable");
    return nil;
end

-- 查询引用变量
-- @refStr 变量记录id(variableRefTab索引)
-- @return 格式化的变量信息table
function this.getVariableRef( refStr )
    local varRef = tonumber(refStr);
    local varTab = {};

    if tostring(type(variableRefTab[varRef])) == "table" then
        for n,v in pairs(variableRefTab[varRef]) do
            local var = {};
            var.name = tostring(n);
            var.type = tostring(type(v));
            xpcall(function() var.value = tostring(v) end , function() var.value = tostring(type(v)) .. " [value can't trans to string]" end );
            var.variablesReference = "0";
            if var.type == "table" or var.type == "function" then
                var.variablesReference = variableRefIdx;
                variableRefTab[variableRefIdx] = v;
                variableRefIdx = variableRefIdx + 1;
                if var.type == "table" then
                    local memberNum = this.getTableMemberNum(v);
                    var.value = memberNum .." Members ".. ( var.value or '' );
                end
            elseif var.type == "string" then
                var.value = '"' ..v.. '"';
            end
            table.insert(varTab, var);
        end
        --获取一下mtTable
        local mtTab = getmetatable(variableRefTab[varRef]);
        if mtTab ~= nil and type(mtTab) == "table" then
            local var = {};
            var.name = "_Metatable_";
            var.type = tostring(type(mtTab));
            xpcall(function() var.value = "元表 "..tostring(mtTab); end , function() var.value = "元表 [value can't trans to string]" end );
            var.variablesReference = variableRefIdx;
            variableRefTab[variableRefIdx] = mtTab;
            variableRefIdx = variableRefIdx + 1;
            table.insert(varTab, var);
        end
    elseif tostring(type(variableRefTab[varRef])) == "function" then
        --取upvalue
        varTab = this.getUpValueVariable(variableRefTab[varRef], true);
    elseif tostring(type(variableRefTab[varRef])) == "userdata" then
        --取mt table
        local udMtTable = getmetatable(variableRefTab[varRef]);
        if udMtTable ~= nil and type(udMtTable) == "table" then
            local var = {};
            var.name = "_Metatable_";
            var.type = tostring(type(udMtTable));
            xpcall(function() var.value = "元表 "..tostring(udMtTable); end , function() var.value = "元表 [value can't trans to string]" end );
            var.variablesReference = variableRefIdx;
            variableRefTab[variableRefIdx] = udMtTable;
            variableRefIdx = variableRefIdx + 1;
            table.insert(varTab, var);
        end
    end
    return varTab;
end

-- 获取全局变量。方法和内存管理中获取全局变量的方法一样
-- @return 格式化的信息, 若未找到返回空table
function this.getGlobalVariable( ... )
    --成本比较高，这里只能遍历_G中的所有变量，并去除系统变量，再返回给客户端
    local varTab = {};
    for k,v in pairs(_G) do
        local var = {};
        var.name = tostring(k);
        var.type = tostring(type(v));
        xpcall(function() var.value = tostring(v) end , function() var.value =  tostring(type(v)) .." [value can't trans to string]" end );
        var.variablesReference = "0";
        if var.type == "table" or var.type == "function" then
            var.variablesReference = variableRefIdx;
            variableRefTab[variableRefIdx] = v;
            variableRefIdx = variableRefIdx + 1;
            if var.type == "table" then
                local memberNum = this.getTableMemberNum(v);
                var.value = memberNum .." Members ".. ( var.value or '' );
            end
        elseif var.type == "string" then
            var.value = '"' ..v.. '"';
        end
        table.insert(varTab, var);
    end
    return varTab;
end

-- 获取upValues
-- @isFormatVariable  true返回[值]  true返回[格式化的数据]
function this.getUpValueVariable( checkFunc , isFormatVariable)
    local isGetValue = true;
    if isFormatVariable == true then
        isGetValue = false;
    end

    --通过Debug获取当前函数的Func
    checkFunc = checkFunc or lastRunFunction.func;

    local varTab = {};
    if checkFunc == nil then
        return varTab;
    end
    local i = 1
    repeat
        local n, v = debug.getupvalue(checkFunc, i)
        if n then

        local var = {};
        var.name = n;
        var.type = tostring(type(v));
        var.variablesReference = "0";

        if isGetValue == false then
            xpcall(function() var.value = tostring(v) end , function() var.value = tostring(type(v)) .. " [value can't trans to string]" end );
            if var.type == "table" or var.type == "function" then
                var.variablesReference = variableRefIdx;
                variableRefTab[variableRefIdx] = v;
                variableRefIdx = variableRefIdx + 1;
                if var.type == "table" then
                    local memberNum = this.getTableMemberNum(v);
                    var.value = memberNum .." Members ".. ( var.value or '' );
                end
            elseif var.type == "string" then
                var.value = '"' ..v.. '"';
            end
        else
            var.value = v;
        end

        table.insert(varTab, var);
        i = i + 1
        end
    until not n
    return varTab;
end

-- 获取局部变量 checkLayer是要查询的层级，如果不设置则查询当前层级
-- @isFormatVariable 是否取值，true:取值的tostring
function this.getVariable( checkLayer, isFormatVariable , offset)
    local isGetValue = true;
    if isFormatVariable == true then
        isGetValue = false;
    end

    local ly = 0;
    if checkLayer ~= nil and type(checkLayer) == "number" then ly = checkLayer + 1;
    else  ly = this.getSpecificFunctionStackLevel(lastRunFunction.func); end

    if ly == 0 then
        this.printToVSCode("[error]获取层次失败！", 2);
        return;
    end
    local varTab = {};
    local stacklayer = ly;
    local k = 1;

    if type(offset) == 'number' then
        stacklayer = stacklayer + offset;
    end

    repeat
        local n, v = debug.getlocal(stacklayer, k)
        if n == nil then
            break;
        end

        --(*temporary)是系统变量，过滤掉。这里假设(*temporary)仅出现在最后
        if "(*temporary)" ~= tostring(n) then
            local var = {};
            var.name = n;
            var.type = tostring(type(v));
            var.variablesReference = "0";
            var.index = k;

            if isGetValue == false then
                xpcall(function() var.value = tostring(v) end , function() var.value = tostring(type(v)) .. " [value can't trans to string]" end );
                if var.type == "table" or var.type == "function" then
                    var.variablesReference = variableRefIdx;
                    variableRefTab[variableRefIdx] = v;
                    variableRefIdx = variableRefIdx + 1;
                    if var.type == "table" then
                        local memberNum = this.getTableMemberNum(v);
                        var.value = memberNum .." Members ".. ( var.value or '' );
                    end
                elseif var.type == "string" then
                        var.value = '"' ..v.. '"';
                end
            else
                var.value = v;
            end

            local sameIdx = this.checkSameNameVar(varTab, var);
            if sameIdx ~= 0 then
                varTab[sameIdx] = var;
            else
                table.insert(varTab, var);
            end
        end
        k = k + 1
    until n == nil
    return varTab, stacklayer - 1;
end

--检查变量列表中的同名变量
function this.checkSameNameVar(varTab, var)
    for k , v in pairs(varTab) do
        if v.name == var.name then
            return k;
        end
    end
    return 0;
end

-- 执行表达式
function this.processExp(msgTable)
    local retString;
    local var = {};
    var.isSuccess = "true";
    if msgTable ~= nil then
        local expression = this.trim(tostring(msgTable.Expression));
        local isCmd = false;
        if isCmd == false then
            --兼容旧版p 命令
            if expression:find("p ", 1, true) == 1 then
                expression = expression:sub(3);
            end

            local expressionWithReturn = "return " .. expression;
            local f = debugger_loadString(expressionWithReturn) or debugger_loadString(expression);
            --判断结果，如果表达式错误会返回nil
            if type(f) == "function" then
                if _VERSION == "Lua 5.1" then
                    setfenv(f , env);
                else
                    debug.setupvalue(f, 1, env);
                end
                --表达式要有错误处理
                xpcall(function() retString = f() end , function() retString = "输入错误指令。\n + 请检查指令是否正确\n + 指令仅能在[暂停在断点时]输入, 请不要在程序持续运行时输入"; var.isSuccess = false; end)
            else
                retString = "指令执行错误。\n + 请检查指令是否正确\n + 可以直接输入表达式，执行函数或变量名，并观察执行结果";
                var.isSuccess = false;
            end
        end
    end

    var.name = "Exp";
    var.type = tostring(type(retString));
    xpcall(function() var.value = tostring(retString) end , function(e) var.value = tostring(type(retString))  .. " [value can't trans to string] ".. e; var.isSuccess = false; end);
    var.variablesReference = "0";
    if var.type == "table" or var.type == "function" then
        variableRefTab[variableRefIdx] = retString;
        var.variablesReference = variableRefIdx;
        variableRefIdx = variableRefIdx + 1;
        if var.type == "table" then
            local memberNum = this.getTableMemberNum(retString);
            var.value = memberNum .." Members ".. var.value;
        end
    elseif var.type == "string" then
        var.value = '"' ..retString.. '"';
    end
    --string执行完毕后清空env环境
    this.clearEnv();
    local retTab = {}
    table.insert(retTab ,var);
    return retTab;
end

--执行变量观察表达式
function this.processWatchedExp(msgTable)
    local retString;
    local expression = "return ".. tostring(msgTable.varName)
    this.printToConsole("processWatchedExp | expression: " .. expression);
    local f = debugger_loadString(expression);
    local var = {};
    var.isSuccess = "true";
    --判断结果，如果表达式错误会返回nil
    if type(f) == "function" then
        --表达式正确
        if _VERSION == "Lua 5.1" then
            setfenv(f , env);
        else
            debug.setupvalue(f, 1, env);
        end
        xpcall(function() retString = f() end , function() retString = "输入了错误的变量信息"; var.isSuccess = "false"; end)
    else
        retString = "未能找到变量的值";
        var.isSuccess = "false";
    end

    var.name = msgTable.varName;
    var.type = tostring(type(retString));
    xpcall(function() var.value = tostring(retString) end , function() var.value = tostring(type(retString)) .. " [value can't trans to string]"; var.isSuccess = "false"; end );
    var.variablesReference = "0";

    if var.type == "table" or var.type == "function" then
        variableRefTab[variableRefIdx] = retString;
        var.variablesReference = variableRefIdx;
        variableRefIdx = variableRefIdx + 1;
        if var.type == "table" then
            local memberNum = this.getTableMemberNum(retString);
            var.value = memberNum .." Members ".. var.value;
        end
    elseif var.type == "string" then
        var.value = '"' ..retString.. '"';
    end

    local retTab = {}
    table.insert(retTab ,var);
    return retTab;
end

this.printToConsole("load LuaPanda success", 1);
return this;
