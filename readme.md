# LuaPanda

LuaPanda 是一个基于 VS Code 的 lua 代码调试器。设计目标是简单易用，支持多种开发框架。它由两部分组成:

- VS Code Extension  调试器 VSCode 插件
- Lua Debugger  调试器的 debugger 部分

Debugger 主体使用 lua 实现，另含一个 C 扩展模块，以保证高速运行。
LuaPanda 支持 lua5.1- 5.3，运行环境要包含 LuaSocket。

LuaPanda 的立项源于潘多拉项目中大量的lua调试需求。`潘多拉`为游戏提供嵌入式跨引擎的运营开发能力，使游戏研发及运营各自独立闭环，在游戏内实现各种营销活动和周边系统，让游戏分工更加专业，团队更加专注，高效产出价值。
潘多拉为游戏提供的服务包括用户生命周期的精细化运营方案、游戏内直播解决方案、游戏内内容社区解决方案、游戏内商城商业化解决方案等，已经在大量腾讯精品游戏中上线、稳定运营。



# Tips

+ 版本说明和升级建议

  目前调试器最新版本是2.3.0（推荐使用），2.2.x和2.1.0 也可使用，更早的版本不再支持。如调试遇到问题建议大家手动把调试器的 `LuaPanda.lua，DebugTools.lua` 两个文件更新到最新版本。`LuaPanda.lua` 的版本可以在此文件头部查看。

  Release下载地址：https://github.com/Tencent/LuaPanda/releases 

  

+ 关于找不到`libpdebug`模块报错

  `libpdebug.so(dll)` 是放置在VSCode插件中的调试器C扩展，会在调试器运行时自动加载，作用是加速调试。

  xlua允许用户重写文件加载函数`CustomLoader`，sluaunreal也提供类似方法`setLoadFileDelegate`。

  发生此问题的原因之一是用户重写的加载函数中没有加入对so/dll的处理，加载so/dll时会报找不到文件错误，但随后执行lua原生loader能够正确加载libpdebug。

  查看libpdebug.so是否加载的方式是在控制台输入`LuaPanda.getInfo()`, 返回信息中有 hookLib Ver 说明libpdebug已经加载。此时可以忽略报错或在文件加载函数函数中正确处理.so/dll。



# 近期更新

+ v2.3.0
  
  + 增加了自动路径识别功能
  
  2.3.0版本插件在launch.json文件中新增了`autoPathMode`设置项。当设置为`true`时，调试器会根据文件名查询完整路径。用户在接入时不必再进行繁琐的路径配置。当此配置项为false或者未配置时，使用传统的路径拼接方式。
  
  另外，用户需要确保**VSCode打开的工程目录**中不存在同名lua文件，才可以使用本功能。否则调试器可能会把断点指向错误的文件，造成执行异常。

  + 测试了在cocos2dx下的运行情况

  之前的版本在cocos2dx中运行时会报查找 c 库错误。2.3.0 修复了此问题，测试 cocos2dx 在 win/mac 下都可以使用c库。
  
  另外调试器目前支持标准lua虚拟机，cocos2dx集成的是luajit，可能会在单步时出现跳步的情况，后续完整支持luajit会解决此问题。
  
  如希望体验新功能，请按照 [升级说明](./Docs/Manual/update.md) 手动替换工程中的 `LuaPanda.lua，DebugTools.lua` 文件。



+ v2.2.1

  小幅更新，优化了单文件调试和调试控制台的使用。

  - 修复单文件调试 文件路径中的 \ 被当做转义符的问题。
  - 修复单文件调试 首次运行窗口报错的问题。
  - 优化调试控制台的使用，动态执行表达式不必再加p 。

  

+ v2.2.0

  增加了`LuaPanda.doctor()` 命令，可以检查环境中的错误(需更新LuaPanda.lua和DebugTools.lua至2.2.0)。

  修复了VSCode请求变量信息但在lua中发生错误，导致调试器卡住的问题。

  修复了c库在一些框架下无法正常运行，导致程序自动退出的问题。

  

# 特性

+ 支持单步调试，条件断点，协程调试，支持调试时变量赋值。
+ 支持lua5.1- 5.3, 支持 slua/xlua/slua-unreal 等框架
+ 在断点处可以监视和运行表达式，返回结果
+ 可以根据断点密集程度调整 hook 频率, 有较高的效率
+ 支持 attach 模式，lua 运行过程中可随时建立连接
+ 使用 lua / C 双调试引擎。lua 部分可动态下发，避免打包后无法调试。C 部分效率高，适合开发期调试。



# 接入和开发指引

接入和使用文档

[项目介绍](./Docs/Manual/feature-introduction.md)	| [快速试用指引](./Docs/Manual/quick-use.md) | [接入指引](./Docs/Manual/access-guidelines.md) |  [真机调试](./Docs/Manual/debug-on-phone.md)  | [单文件调试和运行](./Docs/Manual/debug-file.md) | [升级说明](./Docs/Manual/update.md) | [FAQ](./Docs/Manual/FAQ.md)

调试器开发文档

[工程说明](./Docs/Development-instructions/project-description.md) 	|  [调试器开发指引](./Docs/Development-instructions/how_to_join.md) |  [特性简述](./Docs/Development-instructions/debugger-principle.md) 



# 依赖和适用性

调试器依赖 LuaSocket , 可运行于 slua，slua-unreal ，xlua 等已集成 LuaSocket 的 lua 环境，也可以在 console 中调试。lua 版本支持 5.1- 5.3。



# 参与贡献

我们非常期待您的贡献，无论是完善文档，提出、修复 Bug 或是增加新特性。
如果您在使用过程中发现文档不够完善，欢迎记录下来并提交。
如果发现 Bug，请通过 [issues](https://github.com/Tencent/LuaPanda/issues) 来提交并描述相关的问题，您也可以在这里查看其它的 issue，通过解决这些 issue 来贡献代码。

请将pull request提交在 `dev` 分支上，经过测试后会在下一版本合并到 `master` 分支。更多规范请看[CONTRIBUTING](./CONTRIBUTING.md)

[腾讯开源激励计划](https://opensource.tencent.com/contribution) 鼓励开发者的参与和贡献，期待你的加入。



# 技术支持

如有问题先参阅 [FAQ](./Docs/Manual/FAQ.md) ，如有问题建议使用 [issues](https://github.com/Tencent/LuaPanda/issues) ，我们会关注和回复。

QQ群：974257225

