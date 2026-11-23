# 参与 BeatIt 项目开发

[English](CONTRIBUTING.md) · **简体中文**

欢迎参与 FPGA RTL、测试、Android 联动及项目文档的完善。修改应尽量聚焦，并保持与现有 Tang Nano 20K 构建配置兼容。

## 提交拉取请求前

1. 检查是否已有相关 Issue 或改动，说明需要解决的用户问题或硬件问题。
2. 保持每次改动的范围清晰。不同目的的 RTL、界面和文档重构尽量分别提交。
3. 运行与修改相关的测试。RTL 改动应提供仿真依据；依赖硬件的修改应说明开发板版本、外设和构建配置。
4. 修改通信协议字段、命令、引脚或构建选项时，同步更新相关文档及测试。
5. 修改面向用户的文档时，若已有对应的英文或简体中文版本，应同步维护两种语言。

## 常用检查命令

首先通过 `python -m pip install -r requirements.txt` 安装 Python 依赖。与 RTL 修改相关的测试可运行：

```console
python scripts/run_tests.py tb_adsr tb_i2c_peripherals tb_performance_bridge tb_hdmi_spectrum tb_video_timing
```

主机侧测试：

```console
python -m unittest sim.test_device_protocol sim.test_guide_protocol sim.test_hdmi_build sim.test_flash_guard
```

Android 修改可在 JDK 17+、Android SDK 36 环境下执行：

```console
cd android_app
./gradlew assembleDebug lintDebug
```

上述命令为常用检查项，并不覆盖所有硬件组合。请注明额外执行的测试及未执行的检查。

## 拉取请求应包含什么

简要描述改动目的、受影响的模块或文件、测试命令及结果。涉及 FPGA 实机时，补充构建配置、资源与时序变化，以及相关音频现象或实测数据。日志、波形材料应只包含必要内容，不要上传整个生成目录。

不要提交密钥、设备本地配置、校准数据、位流、APK 或其他构建产物，并遵守现有 `.gitignore`。

## 许可与第三方材料

提交者应确保有权按仓库的 [BeatIt Project License](LICENSE) 贡献材料；如引入采用单独许可证的第三方内容，应明确其来源和授权条件。保留原有版权声明，并同步更新[第三方来源说明](THIRD_PARTY_NOTICES.zh-CN.md)。本项目采用自定义许可协议，不应标注为 MIT。
