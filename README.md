# BeatIt for Tang Nano 20K

BeatIt is an FPGA music synthesizer and performance instrument for the Sipeed Tang Nano 20K. The Verilog design generates and mixes 48 kHz audio on the FPGA. A companion Android app adds a touch keyboard, MIDI playback and guided practice over Bluetooth Low Energy (BLE).

- Up to 32 voices with two independently tuned and enveloped DDS oscillators per voice, plus a monophonic legato mode.
- Fixed-point audio, live waveform changes, tone filtering, tremolo, delay and reverb, with I²S output.
- Physical keys and rotary encoders, optional I²C expression inputs and key LEDs, and a 640 × 480 HDMI display with a live waveform and 32-bin spectrum.
- USB UART for host control or BLE UART for Android. The app can import local MIDI files and record performances.

## Repository layout

| Path | Contents |
| --- | --- |
| `rtl/` | Verilog tops, audio, control and video logic, and ROM data |
| `constraints/` | Gowin pin assignments and timing constraints |
| `scripts/` | FPGA build, programming, serial control, and ROM generation |
| `sim/` | Verilog testbenches and host-side tests |
| `android_app/` | Android source, Gradle wrapper, and [UART/BLE protocol](android_app/docs/protocol-v1.md) |
| `docs/` | Machine-readable DDS note table |
| `licenses/` | License texts for bundled components |

## Build the FPGA firmware

Use Python 3.10 or later and Gowin EDA on Windows. Set `GOWIN_HOME` to the directory containing `IDE/bin/gw_sh.exe`. If your temporary path contains non-ASCII characters or is long, set `BEATIT_STAGE_DIR` to a short ASCII directory such as `C:\fpga-temp`.

From the repository root, build the USB bench configuration for a board without external controls.

```console
python scripts/build_gowin.py --app --transport usb --voices 4 --performance --no-controls
```

The BLE instrument profile enables the external controls, expression inputs, key LEDs and HDMI.

```console
python scripts/build_gowin.py --app --transport ble --voices 32 --performance --peripherals --guide --mono --tremolo --delay --reverb --dc-block --hdmi --placement-opt
```

Builds produce a bitstream, timing reports and a manifest under `build/`. The board profile expects a 49.152 MHz audio clock. Use the constraints for your transport and peripherals. The BLE profile connects to an external 3.3 V UART module supporting Nordic UART Service or HM-10-style UART at 115200 baud.

Install host-side dependencies with `python -m pip install -r requirements.txt`. For SRAM programming, set `GOWIN_PROGRAMMER_HOME` to a Gowin Programmer 1.9.12.04 or later installation. Run `python scripts/program_sram.py --list` to find the cable location. Use the same profile flags as the build with `--location` and `--verify` when programming. The neutral boot profile leaves expression calibration disabled until configured for the board.

## Simulate

Install Icarus Verilog and put `iverilog` and `vvp` on `PATH`. From the repository root, run the portable checks.

```console
python scripts/run_tests.py tb_adsr tb_i2c_peripherals tb_performance_bridge tb_hdmi_spectrum tb_video_timing
python -m unittest sim.test_device_protocol sim.test_guide_protocol sim.test_hdmi_build sim.test_flash_guard
```

Running `scripts/run_tests.py` without test names also exercises variants using Gowin's simulation models from `GOWIN_HOME`.

## Build the Android app

Install JDK 17 or later and Android SDK 36. Set `JAVA_HOME` and `ANDROID_HOME`, or open `android_app/` in Android Studio. From `android_app/`, run the Gradle wrapper.

```console
./gradlew assembleDebug lintDebug
```

On Windows, run `.\gradlew.bat assembleDebug lintDebug`. The app supports Android 8.0 and later. Use the BLE FPGA build to play and control the instrument from the app.

## License and attribution

You may use, modify and distribute the project-owned code under the [BeatIt Project License](LICENSE). Commercial use or reuse of 80% or more of the project-owned code requires credit to the BeatIt project team and a link to this repository. See the [third-party notices](THIRD_PARTY_NOTICES.md) for separately licensed files.
