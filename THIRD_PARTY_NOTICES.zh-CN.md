# 第三方组件及来源说明

[English](THIRD_PARTY_NOTICES.md) · **简体中文**

| 文件 | 上游来源与许可 |
| --- | --- |
| `rtl/i2c_master.v` | [Alex Forencich 的 verilog-i2c](https://github.com/alexforencich/verilog-i2c/tree/a65be4045e898a52e791c6ee71f8f79a7cd2e129)，MIT 许可证。源文件保留原始声明。 |
| `rtl/picorv32_pcpi_div.v` | [Claire Xenia Wolf 的 PicoRV32](https://github.com/YosysHQ/picorv32/tree/ef203c2b0a3fb793280f5114941416c425c5b461)，ISC 许可证。源文件保留原始声明。 |
| `rtl/pcm_reverb.v` | 改编自 [xls32-fpga-synth](https://github.com/kazunori279/xls32-fpga-synth/blob/39fbb1bd7627ca5450bce69ffb00a87b07d528d8/boards/basys3/rtl/top.v)，采用 [Apache-2.0](licenses/Apache-2.0.txt) 许可证。修改包括单声道 48 kHz 工作方式、压缩状态存储以及定点运算。 |
| `rtl/display_font.hex` | BeatIt 使用 [Noto Sans CJK SC Regular，Sans2.004](https://github.com/notofonts/noto-cjk/releases/tag/Sans2.004) 栅格化生成的位图字形子集。版权归 Adobe（2014—2021）所有。字形子集依据 [SIL Open Font License 1.1](licenses/Noto-CJK-OFL-1.1.txt) 分发。 |
| `android_app/gradlew`、`android_app/gradlew.bat`、`android_app/gradle/wrapper/gradle-wrapper.jar` | [Gradle Wrapper](https://docs.gradle.org/current/userguide/gradle_wrapper.html)，[Apache-2.0](licenses/Apache-2.0.txt) 许可证。 |

HDMI 引脚分配参考了 [Sipeed 官方开发板示例](https://github.com/sipeed/TangNano-20K-example/tree/e23949a0a77381b94960cbc4e97a7c5e5ba8d222/hdmi)。

如需重新生成 HDMI ROM 数据，应下载[锁定版本的 CJK 字体](https://raw.githubusercontent.com/notofonts/noto-cjk/Sans2.004/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf)，安装 Pillow 后从仓库根目录执行：

```console
python scripts/generate_display_assets.py --font path/to/NotoSansCJKsc-Regular.otf
```

字体文件的 SHA-256 为：

```text
2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b
```

各组件的法律授权条件以对应许可证原文为准；本文件是英文来源说明的中文译本。
