# (TTA) Terminal Agent Assistant

> Terminal Agent Assistant is a tool for managing multiple terminal-based Agents. It currently supports Claude Code, OpenCode, Hermes, and KimiCode.
>
> In theory, the software can work with more terminal-based Agents, and users can add their own. Since those Agents have not been specifically adapted yet, some features may be missing.
>
> As of now, the software offers better management of conversation history and the models used by multiple Agents.
>
> The software studied and drew inspiration from the following open-source projects: Ghostty and CCswitch.
>
> Most of this project was built with Codex.

## 中文说明

Terminal Agent Assistant 是一款面向 macOS 的本地 AI Agent 终端工作台。它把 Claude Code、KimiCode、OpenCode、Hermes 等命令行 Agent 放进统一的原生桌面应用中，提供多会话管理、终端标签页、对话恢复、供应商配置和模型映射等能力。

## 功能特性

- 原生 macOS SwiftUI 应用，界面轻量、响应快。
- 内置现代化终端，支持标签页、多会话和会话窗口。
- 支持 Claude Code、KimiCode、OpenCode、Hermes 等主流 Agent。
- 支持 Agent 原生历史恢复，避免多个对话恢复串台。
- 支持 Provider 配置管理，可为不同 Agent 配置不同模型供应商。
- 支持自动识别供应商模型列表，并进行模型映射。
- 支持浅色和深色主题，终端样式已针对 AI TUI 工具优化。
- 支持中文界面切换。
- 本地保存会话、配置和 transcript，不依赖云端同步。

## 系统要求

- macOS 14.0 或更高版本
- Xcode 15 或更高版本
- 已安装需要使用的命令行 Agent，例如 `claude`、`kimi`、`opencode` 或 `hermes`

## 构建方法

在项目根目录执行：

```bash
xcodebuild -project TerminalAgents.xcodeproj -scheme TerminalAgents -configuration Debug build
```

也可以直接用 Xcode 打开：

```bash
open TerminalAgents.xcodeproj
```

然后选择 `TerminalAgents` scheme 运行。

## 使用方式

1. 启动应用。
2. 在左侧选择或创建 Agent。
3. 为 Agent 配置启动命令，例如 `claude`、`kimi`、`opencode`。
4. 在 Provider 管理界面配置 API Key、Base URL 和模型映射。
5. 点击新建会话开始使用。
6. 重启应用后，支持恢复的 Agent 会话会自动回到对应历史对话。

## 目录结构

```text
TerminalAgents/              应用源码
TerminalAgents.xcodeproj/    Xcode 工程
Vendor/SwiftTerm/            内置终端渲染与 PTY 依赖
project.yml                  XcodeGen 项目配置
```

## 说明

本项目仍在快速开发中，当前重点是提升多 Agent 会话恢复、Provider 配置和内置终端体验。发布前建议先在本机完成 Agent 命令、Provider 配置和会话恢复测试。

## License

请查看项目根目录的 `LICENSE` 文件。
