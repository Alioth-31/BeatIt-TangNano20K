# NanoSynth UART / BLE Protocol v1

[简体中文](protocol-v1.md) · **English**

**Interface contract for Android 0.3.1 and the FPGA application bridge.** The basic synthesizer top-level does not expose this interface; an application-bridge build is required. Android handles framing, BLE transmission, acknowledgements (ACK), status updates, and reception of physical-key and effective-parameter events.

A BLE module transparently forwards the byte stream. FPGA UART settings: 115200 baud, 8N1 (configured identically at both ends), 3.3 V I/O, and common ground. In the v3923 BLE configuration, module TX connects to PIN71 (FPGA RX), and module RX connects to PIN72 (FPGA TX). USB UART TX69/RX70 is already connected to the onboard BL616; do not connect an additional transmitter in parallel. A bitstream enables only one active control transport.

Split BLE transfers into chunks of 20 bytes; no particular MTU is required. The receiver must not treat a single BLE notification as a complete protocol frame. Prefer Nordic UART Service (NUS), service UUID `6e400001-b5a3-f393-e0a9-e50e24dcca9e`: the app writes to `…0002…` and subscribes to `…0003…`. HM-10 `FFE0/FFE1` is also supported, provided return notifications are available.

## Frame format

| Field | Bytes | Definition |
| --- | ---: | --- |
| Sync | 2 | `A5 5A` |
| Version | 1 | `01` |
| Type | 1 | See message tables below |
| Sequence | 2 | Unsigned 16-bit, little-endian |
| Length | 1 | `0..64` |
| Payload | Length | Type-specific |
| CRC | 2 | CRC16-CCITT-FALSE, little-endian; initial value `FFFF`, polynomial `1021`; covers version through payload |

Discard invalid version, length or CRC and resume scanning for the next `A5 5A` sync word. Never apply invalid state to the synthesizer. The CRC test vector `123456789` must produce `29B1`. The maximum frame length is 73 bytes. The timeout for an incomplete UART frame is 20 ms.

All integers are little-endian. Key IDs follow `rtl/note_table.vh`: IDs `0..7` correspond to MIDI notes `60,62,64,65,67,69,71,72`; IDs `8..31` correspond to MIDI notes `36..59`. Mask bit 31 must be handled as an unsigned bit.

## App → FPGA

| Type | Message | Payload |
| ---: | --- | --- |
| `01` | `HELLO` | Empty |
| `02` | `GET_STATUS` | Empty |
| `03` | `GET_INPUTS` (optional diagnostics) | Empty |
| `10` | `SET_STATE` | `mask:u32, volume:u16, bend:i8, preset:u8` (8 bytes) |
| `11` | `SET_MAP` | Eight `key ID:u8` values (8 bytes) |
| `12` | `SET_KEYS` | Remote `mask:u32` (4 bytes; requires capability bit 3) |
| `13` | `SET_PARAMS` | `fields:u8, volume:u16, bend:i8, preset:u8` (5 bytes; requires bit 3) |

`SET_STATE` specifies the complete **remote-key state**. Remote and physical key states are maintained separately and bitwise-ORed before voice allocation. `volume` `0..65535` maps into core `0..65536`. `bend` `-32..+32` represents `-2..+2` semitones in increments of 1/16 semitone, indexing `bend_table` at `bend+32`. `preset` is `0..2`.

`SET_KEYS` updates only remote keys and leaves parameters unchanged. For `SET_PARAMS`, `fields` ranges from `1..7`: bit 0 selects volume, bit 1 bend, and bit 2 envelope preset. Reject reserved bits and validate/update only selected fields. This command contains no key state and must not refresh the note watchdog. Volume `65535` maps to core `65536`; other values map directly.

Apply state at the `sample_ce` boundary. Send ACK only after range validation and state application. Physical encoder adjustments are relative to the current effective parameter values; physical input takes precedence when both occur in one sample. Standard volume step: `2048` over `0..65535`. Bend step: `1` over `-32..32`. Encoder press resets or switches the preset.

With extended firmware, the app sends `SET_KEYS` immediately, batches parameter edits into `SET_PARAMS` approximately every 50 ms, and sends only changed fields. While idle, it sends `SET_KEYS` every 200 ms. **The firmware must clear remote keys after one second without a valid `SET_KEYS` or `SET_STATE`**, while preserving physical keys—even if the BLE link remains connected. `SET_PARAMS` cannot keep stuck remote notes alive. The app applies a 2-second ACK timeout and a 3-second valid-response timeout; on timeout it disconnects and stops phone-triggered notes.

`SET_MAP` changes the mapping of the eight physical keys; reject it as busy while any key is held. Local app mapping remains independent; download the mapping only if the firmware advertises MAP capability. The initial physical mapping matches the app default. `GET_STATUS` does not report the mapping. Firmware that persists a custom mapping would need a future readback extension.

## FPGA → App

| Type | Message | Payload |
| ---: | --- | --- |
| `80` | `ACK` | `request_type:u8, status:u8` (2 bytes) |
| `81` | `HELLO_REPLY` | `version:u8, voices:u8, capabilities:u8, sample_rate:u32, supported_mask:u32, firmware_id:u16` (13 bytes) |
| `82` | `STATUS` | `active_voices:u8, faults:u8, remote_mask:u32, physical_mask:u32, volume:u16, bend:i8, preset:u8, frame_counter:u32` (18 bytes) |
| `83` | `EVENT` | `frame_counter:u32, key_id:u8, down:u8` (6 bytes) |
| `84` | `PARAM_EVENT` | `frame_counter:u32, volume:u16, bend:i8, preset:u8` (8 bytes) |
| `85` | `INPUTS` (optional diagnostics) | `raw_keys_n:u8, debounced_held:u8` (2 bytes) |

`HELLO_REPLY`, `ACK` and `STATUS` echo the corresponding app request sequence. The app also requires `HELLO_REPLY` to report protocol version 1, sample rate `48000`, `voices>0`, `supported_mask!=0`, and STATE capability; otherwise the connection must not enter the ready state. The bridge firmware reports `capabilities=0x0F` and `firmware_id=0x0101` in HELLO.

Capability bits: bit 0 = STATE (required); bit 1 = MAP (optional); bit 2 = physical-key EVENT (optional); bit 3 = `SET_KEYS` / `SET_PARAMS` / `PARAM_EVENT` extension; remaining bits reserved. `voices` is the actual polyphony count, not the number of selectable pitches. `supported_mask` lists playable key IDs.

ACK status codes: `0` = accepted, `1` = invalid payload/range, `2` = busy, `3` = unsupported. Respond with ACK to every `SET_STATE`, `SET_MAP`, `SET_KEYS` and `SET_PARAMS`, identifying the original message type. Do not advertise capabilities that are not implemented.

Fault bits: bit 0 = audio supply fault; bit 1 = UART receive/command queue overflow; bit 2 = event queue overflow; remaining bits reserved. Fault bits stay set until reset. A nonzero fault value signals an exception and marks the current recording as incomplete. New recordings started while an existing fault remains uncleared must also be marked incomplete.

`GET_INPUTS` / `INPUTS` is intended for host-side wiring diagnostics and echoes the request sequence. `raw_keys_n` contains the eight active-low GPIO levels after two-stage synchronization. `debounced_held` contains the debounced key state entering the bridge; it is zero when physical keys are disabled in a bench build. This diagnostic command does not refresh the remote-key watchdog or affect audio. The current Android app does not use it; older firmware may omit support.

`EVENT` reports **physical-key transitions only**, after synchronization and debouncing; do not echo remote-key events, which would duplicate phone notes in recordings. `down` is either `0` or `1`. `PARAM_EVENT` reports changes to effective global parameters after local and remote operations have been applied, carrying the complete parameter state. `frame_counter` increments on every 48 kHz sample.

`EVENT` and `PARAM_EVENT` **share a single continuous 16-bit event sequence**, wrapping at zero. `ACK` and `STATUS` use the request sequence instead and must not alter the event sequence. The app uses both event types together to detect losses and duplicates. Convert ticks at 48 frames/ms; sort delayed arrivals by sample time before saving a recording. `STATUS` and `PARAM_EVENT` update the UI without triggering feedback commands. Preserve the latest pending and ACK-waiting phone edits; after a parameter ACK, use `GET_STATUS` to read the actual arbitration result. Do not let a status older than an accepted parameter tick overwrite newer UI state.

Maintain live state separately from recording history. Firmware advertising EVENT records physical notes through `EVENT`; firmware advertising bit 3 records effective parameters through `PARAM_EVENT`. `STATUS` updates the UI and the recording's initial baseline only, avoiding duplicate history entries. Queued events arriving after a newer STATUS still enter the recorded history according to their sample ticks, preserving short notes and intermediate parameter changes. Events preceding the recording start boundary may update a still-valid baseline but must not create duplicate note-on events; later events are retained individually. Preserve the `STATUS`-snapshot fallback path for older firmware without the corresponding event capability.

The app handshake is:

```text
HELLO → matching HELLO_REPLY → GET_STATUS → matching valid STATUS
      → SET_KEYS(0) → matching successful ACK → ready
```

The overall handshake deadline is 2500 ms; the clear-keys ACK deadline is 2000 ms. On timeout, actively disconnect and clear unfinished requests; late ACKs must not restore the ready state. Do not write parameters before reading effective values. Synchronize physical-key and parameter events arriving during the clear-keys phase so the handshake does not lose current state. With old firmware lacking capability bit 3, send `SET_STATE(0)` with the read-back parameters to clear keys and retain the legacy full-state path. Its full-parameter heartbeat does not guarantee concurrent physical-encoder arbitration available in the extended path.

`GET_STATUS` must return at least one complete state snapshot. Report current physical state through `STATUS` before subsequent `EVENT` transitions so recording startup does not miss already-held keys. Repeated STATUS messages must not repeatedly record unchanged keys or parameters. A STATUS sample tick marks the boundary covered by that snapshot. If queued events arrive later, the app consumes their old event sequence and preserves history, but live UI ignores physical-key states with tick `<=` the accepted snapshot tick to avoid reactivating released keys.

## Guided practice from the phone library

Instrument-side guided practice requires HELLO capability bits 7 and 2. The app first calls `GET_PERFORMANCE` (`0x24`, reply `0x89`) to retrieve settings, the initial physical-key state, the configuration version, and the sample counter. It then calls `GET_KEY_PITCHES` (`0x25`, reply `0x8B`) to retrieve the eight physical-key MIDI pitches for the same configuration version. Music scores remain on the phone. The app uses physical-key `EVENT` messages to identify note-on and note-off actions. Each batch of key events enters practice evaluation only after the configuration version has been confirmed. A configuration change, event loss, timeout, or disconnect stops the current evaluation.

New bridge builds with physical controls, peripherals and the practice module report firmware version `0x0102` in HELLO. `SET_PRACTICE_LIGHTS` (`0x2A`) accepts three bytes: an 8-bit target physical-key mask and a 16-bit little-endian configuration version. A zero mask releases phone control of the key LEDs. Standard ACK status `1` indicates invalid length; `2` indicates setup mode, onboard practice mode, offline LED driver or configuration-version mismatch; `3` indicates unsupported functionality.

During practice, the app continuously renews the command lease. If no valid target is received for approximately one second, the FPGA restores local LED control. Entering setup or onboard practice, changing key configuration, or losing the LED driver also clears the phone target. Byte 7 (zero-based) of `GET_GUIDE` continues to return the mask actually applied by the LED driver.

## Firmware acceptance checks

1. Verify resynchronization after randomly split UART/BLE frames, bad CRC, noise and maximum-length frames.
2. Check correct HELLO sample rate and capabilities and rejection of invalid parameters; `SET_STATE` must not overwrite the identity of physical keys.
3. When a remote and physical source hold the same note, releasing either side must not silence the other. On disconnection, remote notes must be released within one second.
4. Apply global parameters at sample boundaries with phase-continuous frequency updates. Do not stream prerecorded PCM from the app.
5. Physical-key `EVENT` and `PARAM_EVENT` share the event sequence and sample tick; event-queue overflow sets fault bits and causes incomplete recordings to be flagged.
6. Measure four-voice and wireless performance latency, separately from the existing physical-key path, against the `<=10 ms` acceptance target.

This document translates the protocol contract in [the Chinese source](protocol-v1.md). If translation discrepancies are found, verify behavior against the RTL, app implementation and tests.
