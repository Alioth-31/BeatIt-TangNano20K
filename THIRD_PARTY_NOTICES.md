# Third-party notices

| Files | Source and license |
| --- | --- |
| `rtl/i2c_master.v` | [verilog-i2c by Alex Forencich](https://github.com/alexforencich/verilog-i2c/tree/a65be4045e898a52e791c6ee71f8f79a7cd2e129), MIT. The source file carries the original notice. |
| `rtl/picorv32_pcpi_div.v` | [PicoRV32 by Claire Xenia Wolf](https://github.com/YosysHQ/picorv32/tree/ef203c2b0a3fb793280f5114941416c425c5b461), ISC. The source file carries the original notice. |
| `rtl/pcm_reverb.v` | Adapted from [xls32-fpga-synth](https://github.com/kazunori279/xls32-fpga-synth/blob/39fbb1bd7627ca5450bce69ffb00a87b07d528d8/boards/basys3/rtl/top.v), [Apache-2.0](licenses/Apache-2.0.txt). Changes include mono 48 kHz operation, packed state memory and fixed-point arithmetic. |
| `rtl/display_font.hex` | BeatIt bitmap glyph subset rasterized from [Noto Sans CJK SC Regular, Sans2.004](https://github.com/notofonts/noto-cjk/releases/tag/Sans2.004). Copyright 2014–2021 Adobe. The glyph subset is distributed under the [SIL Open Font License 1.1](licenses/Noto-CJK-OFL-1.1.txt). |
| `android_app/gradlew`, `android_app/gradlew.bat`, `android_app/gradle/wrapper/gradle-wrapper.jar` | [Gradle Wrapper](https://docs.gradle.org/current/userguide/gradle_wrapper.html), [Apache-2.0](licenses/Apache-2.0.txt). |

The board HDMI pin assignments reference the [Sipeed board example](https://github.com/sipeed/TangNano-20K-example/tree/e23949a0a77381b94960cbc4e97a7c5e5ba8d222/hdmi).

To regenerate the HDMI ROM data, download [the pinned CJK font](https://raw.githubusercontent.com/notofonts/noto-cjk/Sans2.004/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf), install Pillow, and run `python scripts/generate_display_assets.py --font path/to/NotoSansCJKsc-Regular.otf` from the repository root. The font file's SHA-256 is `2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b`.
