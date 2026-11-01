# 构建说明

## 环境

| 工具 | 版本 / 说明 |
| --- | --- |
| Xcode | 15+（本机验证：Xcode 27.1 / macOS 27.0.1） |
| CMake | ≥ 3.19（`pip install cmake` 或 `brew install cmake`） |
| Ninja | 可选但明显更快（`pip install ninja`） |
| 部署目标 | macOS 13.0（液态玻璃 API 用 `#available(macOS 26.0, *)` 保护） |

CMake 4.x 需要 `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`，`scripts/build_mac.sh` 里已经带上。

## 取源码（无 `git clone` 也能走）

正常情况：

```bash
git clone --recursive https://github.com/HoppouAI/Breeze-TTS-2.cpp.git Breeze-TTS-2.Cpp
```

如果 `github.com:443` 连不通（本机就是这样，`git clone` 会报 HTTP/2 framing 或超时），
用 codeload 的 tarball，按 `.gitmodules` 里的固定 commit 分别拉主仓库和子模块：

```bash
curl -L https://codeload.github.com/HoppouAI/Breeze-TTS-2.cpp/tar.gz/refs/heads/main -o main.tar.gz
curl -L https://codeload.github.com/ggml-org/ggml/tar.gz/36da5713... -o ggml.tar.gz
curl -L https://codeload.github.com/toots/shine/tar.gz/ab5e3526... -o shine.tar.gz
# 解包到 Breeze-TTS-2.Cpp/、Breeze-TTS-2.Cpp/third_party/ggml/、Breeze-TTS-2.Cpp/third_party/shine/
```

子模块 commit 可以从 GitHub API 读：

```bash
curl -s https://api.github.com/repos/HoppouAI/Breeze-TTS-2.cpp/git/trees/main \
  | python3 -c "import json,sys;[print(t['path'],t['sha']) for t in json.load(sys.stdin)['tree'] if t['mode']=='160000']"
```

## 编译引擎

```bash
scripts/build_mac.sh            # arm64 + x86_64，lipo 成 Universal
scripts/build_mac.sh arm64      # 只编当前架构，迭代用
```

脚本等价于：

```bash
cmake -S Breeze-TTS-2.Cpp -B build/arm64 -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DBUILD_SHARED_LIBS=OFF \        # 关键：让 ggml 静态链进去，只有一个 dylib
  -DBREEZE_VULKAN=OFF \            # macOS 上 Vulkan 基本不可用
  -DBREEZE_BUILD_CLI=OFF -DBREEZE_BUILD_SERVER=OFF -DBREEZE_MP3=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF                # 交叉编 x86_64 时必须关掉 -march=native
cmake --build build/arm64 --target breeze breeze_core -j
```

产物：`Vendor/libbreeze.dylib`（Universal，install_name 改成 `@rpath/libbreeze.dylib`）、
`Vendor/libbreeze_core.a`、`Vendor/include/breeze/breeze.h`。

`otool -L Vendor/libbreeze.dylib` 只应该看到系统库：Accelerate / Foundation / Metal /
MetalKit / libc++ / libSystem。如果看到 `@rpath/libggml*.dylib`，说明 `BUILD_SHARED_LIBS`
没关，app 里还要多带 4 个 dylib。

## 生成工程并编译 app

```bash
python3 scripts/gen_project.py     # 生成 BreezeTTS.xcodeproj/project.pbxproj
xcodebuild -project BreezeTTS.xcodeproj -scheme BreezeTTS \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/xc build
```

或者一步到位：

```bash
scripts/build_app.sh               # 引擎 + 工程 + app，产物拷到 dist/BreezeTTS.app
```

注意：**不加 `-destination 'generic/platform=macOS'` 时 xcodebuild 只会编当前架构**
（`ONLY_ACTIVE_ARCH` / 本机 destination 会覆盖 ARCHS），产出的就不是 Universal。

### 工程关键设置

| 设置 | 值 |
| --- | --- |
| `MACOSX_DEPLOYMENT_TARGET` | 13.0 |
| `ARCHS` | `arm64 x86_64` |
| `SWIFT_VERSION` | 5.0 |
| `SWIFT_OBJC_BRIDGING_HEADER` | `BreezeTTS/Bridge/BreezeTTS-Bridging-Header.h` |
| `HEADER_SEARCH_PATHS` | `$(SRCROOT)/Vendor/include` |
| `LD_RUNPATH_SEARCH_PATHS` | `@executable_path/../Frameworks` |
| `ENABLE_APP_SANDBOX` | NO（要读写 `~/Library/Application Support/BreezeTTS`） |
| `ENABLE_HARDENED_RUNTIME` | NO |
| `CODE_SIGN_IDENTITY` | `-`（ad-hoc，本机运行足够） |

`libbreeze.dylib` 走 Embed Frameworks（CodeSignOnCopy），所以只需要 rpath
指向 `Contents/Frameworks`。

## 模型

```bash
scripts/download_models.sh q8_0      # 3.57 GB
scripts/download_models.sh q4_k      # 2.54 GB
scripts/download_models.sh ref_voice # 官方参考音色 251 KB
```

默认走 `hf-mirror.com`（huggingface.co 在部分网络不通）。下载按 `Range` 断点续传，
落盘后必须与上表的字节数完全一致才算可用。

## 无界面验证

```bash
clang -O2 -I Vendor/include tools/engine_smoke.c \
      -L Vendor -lbreeze -Wl,-rpath,"$PWD/Vendor" -o build-static/engine_smoke

./build-static/engine_smoke ~/Library/Application\ Support/BreezeTTS/models/breeze-tts-2-q8_0.gguf \
    /tmp/smoke.wav "这是一段用来验证引擎链路的测试语音。"
```

输出会给出采样率、chunk 数、音频时长、首块延迟和总耗时，可以和 App 里显示的数字对照。

## 常见问题

**`third_party/ggml is missing`** — 子模块没放好，见上面 tarball 步骤。

**链接时报 `Undefined symbols: _ggml_backend_metal_reg`** — `GGML_METAL` 没开，
或者链接的是旧的 `libbreeze_core.a`。删掉 `build/` 重编。

**App 启动后一直「正在加载模型」** — Q8_0 需要约 4 GB 峰值内存，检查活动监视器；
首次加载 3–8 秒属正常。若直接失败，看 `Console.app` 里 `BreezeTTS:` 开头的日志。

**只有 arm64** — 见上面的 `-destination 'generic/platform=macOS'`。
