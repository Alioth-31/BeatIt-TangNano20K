# Contributing to BeatIt

**English** · [简体中文](CONTRIBUTING.zh-CN.md)

Contributions to FPGA RTL, tests, Android integration and documentation are welcome. Please keep changes focused and preserve compatibility with the existing Tang Nano 20K build profiles.

## Before opening a pull request

1. Check for an existing issue or related change. Explain the user-visible or hardware-visible problem you are addressing.
2. Make a focused change. Avoid combining unrelated RTL, UI and formatting refactors in one pull request.
3. Run the tests relevant to your change. For RTL work, include simulation evidence; for a hardware-dependent change, state which board revision, peripherals and build profile you used.
4. If you change a protocol field, command, pin or build option, update its documentation and any corresponding tests.
5. For changes to user-facing prose, update both the English and Simplified Chinese documentation where a translated counterpart exists.

## Useful checks

Install Python dependencies with `python -m pip install -r requirements.txt`. Run relevant RTL tests with:

```console
python scripts/run_tests.py tb_adsr tb_i2c_peripherals tb_performance_bridge tb_hdmi_spectrum tb_video_timing
```

Run the host-side test suite with:

```console
python -m unittest sim.test_device_protocol sim.test_guide_protocol sim.test_hdmi_build sim.test_flash_guard
```

For Android changes, build and lint with JDK 17+ and Android SDK 36:

```console
cd android_app
./gradlew assembleDebug lintDebug
```

These are representative checks, not a guarantee of complete coverage. State any additional tests you ran and any checks you could not run.

## Pull request information

Include a concise description, affected modules or files, test commands and results, and—where applicable—FPGA resource/timing changes, audio behavior or measurements, and hardware setup. Attach small, relevant logs or waveforms rather than generated build directories.

Do not commit credentials, local device profiles, calibration data, generated bitstreams, APKs or other build outputs. Respect the existing `.gitignore`.

## Licensing and third-party material

By submitting a contribution, ensure you have the right to provide the material under the repository's [BeatIt Project License](LICENSE) or clearly identify any separately licensed third-party material. Preserve relevant copyright notices and update [third-party notices](THIRD_PARTY_NOTICES.md) when introducing or changing a bundled dependency. This project uses a custom license; do not label it MIT.
