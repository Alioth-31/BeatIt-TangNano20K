package cn.nano20k.synth.core;

import java.util.*;

/** Self-paced onset practice with a release between groups. */
public final class Practice {
    private final List<Set<Integer>> steps;
    private final Set<Integer> pitches = new TreeSet<>();
    private int[] physicalKeys;
    private int step, held, wrong;
    private boolean matched, needsRelease;

    public Practice(Midi.Song song) {
        Map<Long, Set<Integer>> groups = new TreeMap<>();
        for (Midi.Event event : song.events) {
            if (!event.down) continue;
            if (event.note < 0 || event.note > 127) throw new IllegalArgumentException("曲谱音高无效");
            groups.computeIfAbsent(event.ms, time -> new TreeSet<>()).add(event.note);
            pitches.add(event.note);
        }
        steps = new ArrayList<>(groups.values());
        if (steps.isEmpty()) throw new IllegalArgumentException("曲谱没有可练习的音符");
        for (Set<Integer> group : steps) {
            if (group.size() > 8) throw new IllegalArgumentException("曲谱有超过八个同时起音的音符");
        }
    }

    public void reset(int[] mapping, int heldKeys) {
        if (mapping != null) {
            if (mapping.length != 8) throw new IllegalArgumentException("需要八个实体键位");
            Set<Integer> missing = new TreeSet<>(pitches);
            for (int pitch : mapping) missing.remove(pitch);
            if (!missing.isEmpty()) throw new IllegalArgumentException("当前琴键缺少 " + labels(missing));
        }
        physicalKeys = mapping == null ? null : mapping.clone();
        step = wrong = 0;
        held = heldKeys & 255;
        matched = false;
        needsRelease = held != 0;
    }

    public int[] keys() {
        if (physicalKeys != null) return physicalKeys.clone();
        int[] result = new int[8];
        Arrays.fill(result, -1);
        Set<Integer> visible = new TreeSet<>();
        if (!done()) visible.addAll(steps.get(step));
        for (int pitch : pitches) {
            if (visible.size() == 8) break;
            visible.add(pitch);
        }
        int index = 0;
        for (int pitch : visible) result[index++] = pitch;
        return result;
    }

    public int target() {
        if (done()) return 0;
        int mask = 0;
        int[] layout = keys();
        for (int i = 0; i < layout.length; i++) {
            if (steps.get(step).contains(layout[i])) mask |= 1 << i;
        }
        return mask;
    }

    public void input(int key, boolean down) {
        if (done() || key < 0 || key >= 8) return;
        int bit = 1 << key;
        if (down && ((held & bit) != 0 || keys()[key] < 0)) return;
        held = down ? held | bit : held & ~bit;
        if (needsRelease || matched) {
            if (held == 0) {
                if (matched) step++;
                needsRelease = matched = false;
            }
            return;
        }
        int target = target();
        if (down && (target & bit) == 0) wrong++;
        if (down && held == target) matched = true;
    }

    public void cancelTouches() {
        held = 0;
        matched = needsRelease = false;
    }

    public boolean done() { return step == steps.size(); }
    public int step() { return step; }
    public int total() { return steps.size(); }
    public int wrong() { return wrong; }
    public int held() { return held; }
    public boolean waitingForRelease() { return matched || needsRelease; }
    public String targetLabel() { return done() ? "" : labels(steps.get(step)); }
    public boolean hasChords() { return steps.stream().anyMatch(group -> group.size() > 1); }

    private static String labels(Set<Integer> notes) {
        StringJoiner text = new StringJoiner(" + ");
        for (int note : notes) text.add(Notes.midiLabel(note));
        return text.toString();
    }
}
