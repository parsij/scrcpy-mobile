# scrcpy v3.3.4 → v4.0 升级基线

## 范围
本仓库的工作集中在两侧：
- **server/** — 编进 `scrcpy-app/ADBClient/scrcpy-server` 推送到 Android 端运行；
- **app/src/** — 通过 `porting/` 的 hijack 机制编为 iOS 静态库给 `scrcpy-app` link。

`app/data/`、`app/deps/`（FFmpeg/SDL/dav1d 的 deps 脚本，仅 Linux/Win/Mac 桌面用）、`server/build.gradle` 等仅 desktop/gradle 范围的改动我们自带构建脚本，参考意义有限，不在本基线表内。

## 统计（仅 `server/` + `app/src/`）

- **server**：modified 28，added 7，removed 2，renamed 11
- **app**：modified 71，added 10，removed 4

完整 raw 表：`docs/upgrade-v4-files.tsv`（每行 `status<TAB>+<TAB>-<TAB>path`）。

## 结构性变化（added / removed / renamed）

### Server

新增：
- `server/.../display/DisplayProperties.java` (+52)
- `server/.../display/DisplayPropertiesTracker.java` (+84)
- `server/.../display/DisplayResizeDebouncer.java` (+85)
- `server/.../model/Size.java` (+144) — 替代被删的 `device/Size.java`
- `server/.../video/CaptureControl.java` (+42) — 抽象 camera torch/zoom 的运行时控制
- `server/.../video/VideoConstraints.java` (+86) — `--max-size` / `--min-size-alignment` 等约束的承载
- `server/test/.../model/SizeTest.java` (+75)

删除：
- `server/.../device/Size.java` (-112) → 迁到 `model/Size.java`
- `server/.../video/CaptureReset.java` (-37) → 被 `CaptureControl` 取代

重命名（device → model）：`Codec`、`CodecOption`、`ConfigurationException`、`DeviceApp`、`NewDisplay`、`Orientation`、`Point`、`Position`、`DisplayInfo`、`DisplayMonitor`、test 的 `CodecOptionsTest`。

**对本仓库的影响**：
- `porting/server/src/main/java/com/genymobile/scrcpy/` 现有的 patch 只触及 `FakeContext.java` 和 `control/Controller.java`，不在被重命名的列表中，路径仍然成立。
- `Makefile::scrcpy-server` 用 `find src -name "*.java" -exec cp -v {} scrcpy-$$SCRCPY_VERSION/server/{} \;` 按相对路径覆盖，路径未变所以仍 OK。
- 内部类型迁移到 `model/`：如果未来要在 `Controller.java` patch 里引用 `Point`/`Position` 等类，import 路径需写新的 `com.genymobile.scrcpy.model.*`（当前 patch 不涉及）。

### App（client，仅 `app/src/`）

新增：
- `disconnect.c/.h` (+88/+47) — 断线时显示 disconnect icon（#6662）
- `sdl_hints.c/.h` (+47/+12) — SDL3 hint 统一管理（#6809）
- `texture.c/.h` (+235/+47) — 纹理上传逻辑从 `display.c` / `screen.c` 中拆出
- `util/sdl.c/.h` (+128/+40) — SDL3 兼容辅助层
- `util/command.c/.h` (+98/+17) — 命令解析重构（独立于 cli）

删除：
- `display.c/.h` (-351/-64) — 内容拆入 `screen.c` 与新的 `texture.c`
- `usb/screen_otg.c/.h` (-326/-52) — OTG 模式 screen 抽象被合并/替代（iOS 不用，可忽略影响）

**对本仓库的影响**：
- `porting/src/display-porting.c` 通过 `#include "display.c"` 包含的源已不复存在 → 必须删除并把其中的 `SDL_UpdateYUVTexture_hijack` / `SDL_RenderPresent_hijack` 迁到 `screen-porting.c` 或新的 `texture-porting.c`。
- `porting/src/screen-porting.c` 中 `#include "screen.c"` 仍然成立，但 screen.c 本身 +659/-306，hijack 的函数签名（`sc_screen_init`、`sc_screen_handle_event`、`SDL_CreateWindow`）需要在 v4.0 上重新核对，特别是 `SDL_CreateWindow` 在 SDL3 移除了 x/y 参数。

## 高影响模块（modified，按 deletion 倒序，>=30）

### Server

| 文件 | + | - | 升级要点 |
|---|---:|---:|---|
| `control/Controller.java` | 209 | 88 | camera torch/zoom 控制消息、CaptureControl 抽象；本仓库 patch 需在新基础上重做 |
| `video/NewDisplayCapture.java` | 140 | 37 | flex display (`-x`/`--flex-display`, #6772) 核心实现 |
| `video/CameraCapture.java` | 156 | 57 | camera torch/zoom (#6243) |
| `Options.java` | 59 | 11 | 新 CLI flag |
| `video/SurfaceEncoder.java` | 76 | 22 | MediaCodec KEY_PRIORITY/KEY_LATENCY 调到最低（#6670），编码延迟下降 |
| `LogUtils.java` | 38 | 7 | 日志格式微调 |
| `video/ScreenCapture.java` | 41 | 33 | 与新 DisplayPropertiesTracker 配合 |
| `display/DisplayMonitor.java`(renamed) | 36 | 33 | display 监控重构 |
| `device/Streamer.java` | 26 | 11 | session metadata for video stream (#6159) |

### App（仅本仓库 porting 触及的会受影响）

| 文件 | + | - | 升级要点 |
|---|---:|---:|---|
| `screen.c` | 659 | 306 | 整体重写，SDL3 + 吸收 display.c |
| `input_manager.c` | 338 | 213 | SDL3 事件常量重命名（`SDL_WINDOWEVENT_*` → `SDL_EVENT_WINDOW_*`），mouse/touch/键盘事件类型变化 |
| `cli.c` | 333 | 150 | 新 flag |
| `demuxer.c` | 109 | 51 | session metadata 解析 |
| `delay_buffer.c` | 100 | 43 | 音频延迟队列重写（与 audio_player 重构配合） |
| `input_events.h` | 92 | 97 | 输入事件结构 SDL3 化 |
| `audio_player.c` | 70 | 24 | OPUS 静音解码高 CPU 修复 (#6715) |
| `decoder.c` | 57 | 4 | 视频解码器接口与 FFmpeg 8 / SDL3 配合 |
| `icon.c` | 59 | 47 | 图标/disconnect icon 路径 |
| `mouse_capture.c` | 19 | 42 | mouse capture 简化 |
| `controller.c` | 38 | 5 | 新增 camera torch/zoom 控制消息 |
| `scrcpy.c` | 77 | 132 | 主流程精简 |

## 与本仓库现有 patch / hijack 的对应表

| 本仓库改动 | v4.0 是否仍需 | 备注 |
|---|---|---|
| `porting/server/.../Controller.java`: `lastTouchCont` 平滑触摸时间戳 hack | **待定** | v4.0 Controller 重写，要在新源码上重新核对触摸事件 timestamp 处理是否已改 |
| `porting/server/.../Controller.java`: `displayDataAvailable.wait(timeout)` 去掉 `timeout > 0` 守卫 | **待定** | 上游 v4.0 是否已修需 diff 该处 |
| `porting/server/.../Controller.java`: `try/catch (RuntimeException)` 包 `handleEvent()`（本次新增，issue #125） | **可能可移除** | v4.0 通过 #6224 "Fix copy-paste on rooted device" 修了根因，但保留兜底也无害 |
| `porting/server/.../FakeContext.java` patch | **多半仍需** | 该文件 v4.0 未删未重命名，diff 需要在新源上重新生成 |
| `porting/src/display-porting.c` | **必删** | display.c 已删；hijack 迁到 screen / texture porting |
| `porting/src/screen-porting.c` 中的 `SDL_CreateWindow` hijack | **改签名** | SDL3 移除 x/y |
| `make-libsdl.sh` 的 `SDL_UpdateCommandGeneration` 注入 | **多半可去** | SDL3 内部已有 generation 机制 |
| `make-libsdl.sh` 的 `UITouchTypeIndirectPointer` 屏蔽 | **重评** | SDL3 iOS backend 改写，触摸类型分发可能已不同 |
| `make-ffmpeg.sh` 的 `h264_slice.c` colorspace patch | **重评** | FFmpeg 8.1 该处函数已重构，新行号/上下文 |
| `SDL_uikitviewcontroller+Extend.m`: `SDL_WINDOWEVENT_SIZE_CHANGED` 事件 push | **必改** | SDL3 单级事件常量 `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED` |
| `SDL_uikitviewcontroller+Extend.m`: ObjC category override | **核对** | SDL3 iOS backend ivar/selector 可能变 |

## 关键 issue 与 v4.0 修复对应

- ✅ #6224 Fix copy-paste on rooted device — 对应本仓库 issue [#125](https://github.com/wsvn53/scrcpy-mobile/issues/125)
- ✅ #6670 MediaCodec KEY_PRIORITY/KEY_LATENCY — 触摸到画面延迟下降
- ✅ #6794 OpenGL runner shutdown deadlock 修复
- ✅ #5913 Meta Quest flicker 修复
- ❌ #6704 副屏触摸丢失（对应 issue [#127](https://github.com/wsvn53/scrcpy-mobile/issues/127)）—— v4.0 未修，仍 OPEN
- ✅ #6770 square display 旋转修复
- ✅ #6772 flex display + 物理/逻辑尺寸混淆修复

## 关键 release 内容（与升级决策相关）

- SDL2 → SDL3 (#6216)，FFmpeg → 8.1.1，dav1d → 1.5.3，platform-tools (adb) → 37.0.0
- `--flex-display` / `-x`：虚拟显示可随窗口动态 resize
- `--camera-torch` / `--camera-zoom`，运行时快捷键 `MOD+t` / `MOD+Shift+t` / `MOD+↑/↓`
- `--keep-active`：保持设备活动而不改全局设置
- `--background-color`（默认深灰）
- `--no-window-aspect-ratio-lock`：恢复旧版自由 resize 行为
- `--render-fit`、`--min-size-alignment`
- F11 全屏，MOD+q 退出
- 断线显示 disconnect icon 2s 后再关窗

## 分阶段执行索引

详见 task 列表（TaskList），Phase 0 → Phase 5。
