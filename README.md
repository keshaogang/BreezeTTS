# Breeze TTS for macOS

原生 macOS 语音合成应用。SwiftUI 界面 + Objective-C++ 桥 + Breeze-TTS-2.cpp 的 C++ 引擎，
**没有 WebView、没有本地 HTTP 服务、没有浏览器**，推理全部在进程内完成。

- 引擎：[`HoppouAI/Breeze-TTS-2.cpp`](https://github.com/HoppouAI/Breeze-TTS-2.cpp)（Metal 后端）
- 界面：SwiftUI，液态玻璃（macOS 26+）/ 毛玻璃（macOS 13–25）自动降级
- 产物：Universal Binary（arm64 + x86_64）`.app`

## 快速开始

```bash
# 1. 引擎（arm64 + x86_64，产出 Vendor/libbreeze.dylib）
scripts/build_mac.sh

# 2. 生成工程 + 编译 app（产物在 dist/BreezeTTS.app）
scripts/build_app.sh

# 3. 模型（默认下到 ~/Library/Application Support/BreezeTTS/models）
scripts/download_models.sh q8_0

open dist/BreezeTTS.app
```

首次启动进入引导：读机型内存按「听你的」策略推荐档位（16 GB 机器落在 Q8_0），
下完模型才会解锁主界面；引导结束后可在设置里「重新运行引导」。

## 三策略选模

| 策略 | 行为 |
| --- | --- |
| 我想省内存 | 固定 Q4_K，后台常驻不抢内存 |
| 我想跑全量 | 内存 ≥ 24 GB 给 F16，否则 Q8_0 |
| 听你的（默认） | ≤ 8 GB → Q4_K；9–23 GB → Q8_0；≥ 24 GB → Q8_0 |

红线：**16 GB 及以下不推荐超过 6 GB 的权重**；F16 只对「跑全量」且 ≥ 24 GB 开放。
所有档位都可以手动覆盖（超约束只提示「需更大内存」，不禁止），也可以手动导入任意 `.gguf`。

| 档位 | 文件 | 峰值内存 |
| --- | --- | --- |
| F16 | 6.3 GB | ~7 GB |
| Q8_0 | 3.6 GB | ~4 GB |
| Q6_K | 3.0 GB | ~3.5 GB |
| Q4_K | 2.5 GB | ~3 GB |
| Q8_0-dd2 / Q8_0-dd4 / Q4_K-dd2 | 2.5–3.4 GB | ~2.8–3.9 GB（实验，长文本不建议） |

## 界面

极简黑白：默认跟随系统深色 / 浅色，不铺任何彩色渐变，只用系统语义色（背景、主/次/三级文字、发丝分隔线）。

- **首次启动走引导**（欢迎 → 选模型并下载 → 就绪），模型没落地之前不会进主界面
- **主界面只有一块书写区 + 一条悬浮工具栏**，音色 / 历史 / 模型 / 设置全部收进 sheet，不做多分区仪表盘
- **生成的音频可播放 / 暂停**：工具栏出现 `⏯` + 进度条 + `0:03 / 0:09` 时间，进度条可直接点击或拖拽定位；
  历史记录里的每一条也能就地播放 / 暂停
- **液态玻璃**：`glassEffect` / `GlassEffectContainer` / `glassEffectID` / `.buttonStyle(.glass)` 集中在
  `UI/DesignSystem.swift`，macOS 13–25 自动降级为 `regularMaterial` + 发丝描边

## 功能

- 文本 → 流式合成 → 实时播放（生成边出音频边放），也可导出 WAV
- **时长预估**：输入时就在底部给出「约 N 秒语音 · 预计 M 分」；点生成后变成「38% · 还需 1 分 8 秒」实时倒计时。
  预估 = 音节/标点推出的音频长度 × 本机实测 RTF + 首包延迟 +（未加载时的）模型加载时间，
  每跑完一次自动写入校准样本（`Core/GenerationEstimator.swift`），纯本地计算、不调模型
- 音色设计（`instruction` 情绪/风格导向）
- **声线推荐**：按输入文本的关键词、长度、标点、数字密度打分，给出 1–2 个适配风格（`Core/VoiceStyles.swift`，纯本地启发式，无模型）；
  有更合适的声线时工具栏音色按钮上会出现一个小圆点
- **音色二级菜单**：点工具栏的音色按钮弹出 popover —— 顶部「根据当前文本推荐」→ 中部「我的音色」（已保存的克隆音色）
  → 底部「音色管理…」（打开完整面板）
- 风格与克隆音色**叠加生效**：克隆决定「谁在说」，风格决定「怎么说」；手写的自定义指令被预设替换时会留一份备份，菜单里可一键恢复
- 音色克隆：录 5–20 秒参考音频，**说话内容自动识别成逐字稿**，保存后可复用（`ref_audio` + `ref_text`）
- 语音识别优先走系统**本地**模型（`requiresOnDeviceRecognition`），本机缺语言包时才回退系统在线识别；
  首次录音会请求一次「语音识别」权限，拒绝后可用面板里的「打开设置」直接跳到隐私面板
- 录音**录完即可试听**（播放 / 暂停 / 时长），也可以**直接导入已有音频**：选文件 → 自动识别逐字稿 → 试听、改名称 → 保存
- 文件选择统一走 SwiftUI `.fileImporter`；不要在 sheet 里调 `NSOpenPanel.runModal()`，sheet 的模态会话会把它吞掉（按钮看起来像没反应）
- 长文本自动分段（默认 600 字一段，单段上限约 60 秒）
- 历史记录、一键导出、模型断点续传与按字节校验

## 听书 · 角色声线

听书把小说拆成「旁白 + 每句对话」，每个角色有一套**档案**和一段**基准参考音色（ref）**。
两条链路刻意分开，不要混：

1. **基准 ref 链路**（一次性）：档案（年龄 / 性别 / 音色特征）拼成 `baseInstruction`，
   连同 `seed`、`cfg`、ref 台词一起生成一段 wav，存到 `~/Library/Application Support/BreezeTTS/story-refs`。
   缓存 key = `baseInstruction + seed + refText + cfg`，同样的 key 不会重复推理。
2. **正文朗读链路**（每一句）：`ref_audio + ref_text` 锁住音色，只把该句的情绪/语速提示当 `instruction`。

因此：改档案**不会**自动重生成 ref，面板上会标「基准音色待更新」，由用户主动点「重新生成」。
角色面板分两层——普通视图只放试听 / 生成，高级设置里才有年龄描述、性别、音色特征、ref 台词、seed、cfg（2.0–6.0）。

LLM 也是两次独立调用：

- **任务 A · 角色档案**：分析时直接写在人物表里；后来才出场的角色走单独一次 `extractProfiles` 批量补全。
  只输出 `ageDesc / gender / feature`，`feature` 只写稳定底色，禁止写情绪与语速。
- **任务 B · 逐句情绪**：只给每句写表演提示，提示词里不允许出现音色、年龄、性别。

设置 → 听书分析里两个开关：**自动识别新角色人设**（默认开）、**识别到新角色自动打开角色面板**（默认关）。

## 与 iPhone / iPad 配对

只有**完整版**（bundle id `com.breezespeak.mac`）会开配对服务，精简版没有——这是有意的。

- Mac 引导最后一步（或 设置 → iPhone 连接）显示二维码：局域网地址 + 端口 + 6 位配对码
- 手机扫码后走 `POST /pair` 校验，`edition != full` 直接拒绝
- 配对后手机能调：`/status`、`/audiobook/*`（含 `/audiobook/role`、`/audiobook/ref`）、`/chat`、`/history`
- 端口 4747 被占用时自动回落 4748

## 命令行自检

```bash
BIN=dist/BreezeTTS.app/Contents/MacOS/BreezeTTS
$BIN --estimate "要合成的文本" [q8_0]   # 打印时长预估、逐段倒计时（不加载模型）
$BIN --runtest "要合成的文本"          # 真跑一次：预估 → 实时进度 → 写入校准 → 复算
$BIN --recommend "文本"                # 声线推荐打分
$BIN --smoke model.gguf out.wav "文本" # 只测引擎，打印 RTF / 首包
$BIN --snapshot out.png [main|dark-main|running|recorder|voice-menu|role|role-advanced|audiobook|onboarding*]
$BIN --reftest /tmp/refout            # 真跑两条链路：档案→基准 ref，再用 ref 读一句正文
$BIN --asr clip.wav zh-CN --out r.txt  # 语音识别（需 LaunchServices 启动，终端直跑会被 TCC 终止）
```

`--estimate` / `--runtest` 读的是真实 `UserDefaults` 里的校准样本，所以跑过几次之后数字会越来越准。

## 目录

```
BreezeTTS-macOS/
├─ BreezeTTS.xcodeproj        # 由 scripts/gen_project.py 生成，勿手改
├─ BreezeTTS/
│  ├─ App.swift               # 入口 + 窗口配置
│  ├─ Core/                   # Paths / DeviceInfo / ModelCatalog / ModelSelection / AppSettings / AppModel / VoiceStyles（声线预设与推荐）/ GenerationEstimator（时长预估）
│  ├─ Bridge/                 # BreezeBridge.{h,mm} + 桥接头
│  ├─ Services/               # SpeechEngine / AudioPlayer（流式）/ PlaybackService（成品播放）/ VoiceRecorder / SpeechTranscriber（语音识别）/ ModelDownloader / Stores / Export
│  ├─ Models/                 # GenParams / VoiceMeta / HistoryItem
│  ├─ UI/                     # DesignSystem（黑白 + 液态玻璃）/ MainView / VoiceMenu（二级菜单）/ OnboardingView / 各 sheet
│  └─ Resources/AppIcon.icns
├─ Vendor/                    # libbreeze.dylib + breeze.h（编译产物，勿提交）
├─ Breeze-TTS-2.Cpp/          # 上游源码 + 子模块
├─ scripts/                   # build_mac.sh / build_app.sh / download_models.sh / gen_project.py
├─ tools/                     # engine_smoke.c / generate_icon.swift
└─ docs/                      # BUILD.md（构建细节与坑）
```

## 已踩过的坑

- `breeze_context` **不可重入**：所有生成走一条串行队列，桥内再加一把锁
- `breeze_generate` **阻塞**：必须放后台队列，回调里再切主线程刷 UI
- 回调 `samples` 只在回调期内有效：桥里立刻 `NSData` 拷贝
- context 持有整套权重（数 GB）：只建一次，切换档位时先 `breeze_free` 再建新的
- 模型文件按**精确字节数**校验，避免半成品 gguf 被当成可用模型
- 声线推荐只做**加性打分**（关键词 ×2、长度/标点/数字小权重），并且要求「有关键词 / 强标点 / 长文」这类明确线索才出推荐，
  否则直接给「中性自然」——早期版本让「短句」单独构成理由，结果随便一句话都推「活泼轻快」，噪声太大
- 快照要跑在独立的 `UserDefaults` suite 上：用户手写的 `instruction` 会让工具栏按钮在每张截图里都显示「自定义」
- 时长预估**不能只按字数线性外推**：发音长度 = 音节数 / 6.2 + 停顿 + 0.45 秒固定尾巴，且短句有 ~1.1 秒地板
  （「你好」实测 1.2–1.9 秒，跟字数完全不成比例）；真正的耗时大头是 RTF，
  本机 Q8_0 实测流式 RTF ≈ 13.8（7.2 秒音频要 105 秒），换档位按文件体积近似线性缩放
- 预估要**跑一次就自校准**：`GenerationEstimator` 把每次真实（音频秒数、耗时、首包、加载）存进 UserDefaults，
  同档位攒到 2 条就参与加权；实测首轮估 52.9 秒 / 真实 46.0 秒，第二轮收敛到 46.7 秒
- 倒计时用**已出音频**推进百分比、用实测 RTF 推剩余时间；首包前只能靠先验，所以要给前 25% 留出混合权重，
  否则一开始的百分比会跳
- 语音识别（TCC）：**不要**从终端直接跑 `BreezeTTS.app/Contents/MacOS/BreezeTTS` 去测识别，
  `TCCAccessRequest` 会以「隐私违规」直接 abort 进程（responsible process 是终端，终端没有 `NSSpeechRecognitionUsageDescription`）；
  要么用 `open -n dist/BreezeTTS.app` 启动，要么就在 app 里点录音验证
- `on-device` 识别只在系统装好该语言听写资源时可用，`supportsOnDeviceRecognition` 为 false 时回退在线识别并在面板上说明
- 上游仓库真实地址是 `HoppouAI/Breeze-TTS-2.cpp`（早期文档里的 `HoppouAl` 是大小写笔误）
