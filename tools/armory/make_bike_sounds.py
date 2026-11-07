# Draws the hover bike's sounds from numbers (nothing recorded, nothing taken from anywhere) into tools\armory\out\wav.
# It's FPVDrone's tools\sound\make_sounds.py made bigger (user 2026-11-04: "its an electric quad so give it the same audio
# as tghe drones but make it sounds bigger and heavier and more powerful"):
#   BikeMotor    one motor and prop, loops. Three big blades at 3600 rpm: 180 Hz blade pass against the quad's 600, its
#                overtones, a sub an octave under the prop's turn for the frame shaking, the electric whine of the motor's
#                fourteen pole pairs, and air chopped by the blades. Driven into a soft limit: more body at the same peak.
#                The game plays it from 0.71x (idle) through 1.08x (hover) to 1.5x (full power), see hoverbike.lua.
#   BikeWind     air rushing past, loops, follows the bike's speed: the quad's, an octave down
#   BikePreview  not used by the game: four motors as hoverbike.noise_mix has them, idle, hover, full power and back, to
#                listen to without starting the game
# A loop can't click where it joins: every partial turns a whole number of times in its length, and the noise is made
# from whole-number frequencies too. Fixed seed: the same files every run.
#   python tools\armory\make_bike_sounds.py
import os
import wave

import numpy as np

SR = 48000
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "wav")
MOTOR_S = 4.0
BLADE_HZ = 180

# hoverbike.lua's numbers, for the preview
PITCH_LOW, PITCH_HIGH = 0.4, 1.5
DETUNE = (0.985, 1.012, 0.994, 1.021)
START = (0, 0.37, 0.91, 1.43)
MOTOR_VOL, MOTOR_FLOOR, MOTOR_FADE = 0.5, 0.3, 0.05


def times(seconds):
    return np.arange(int(seconds * SR)) / SR


# noise whose spectrum is shape(frequency), periodic in its own length
def loop_noise(rng, seconds, shape):
    n = int(seconds * SR)
    f = np.fft.rfftfreq(n, 1 / SR)
    spec = shape(f) * np.exp(2j * np.pi * rng.random(len(f)))
    spec[0] = 0
    x = np.fft.irfft(spec, n)
    return x / np.max(np.abs(x))


# a slow unevenness that also returns to its start: 1 +- depth, turning cycles times in the loop
def wander(rng, t, seconds, cycles, depth):
    x = sum(np.sin(2 * np.pi * c * t / seconds + rng.random() * 6.283) for c in cycles) / len(cycles)
    return 1 + depth * x


def motor():
    rng = np.random.default_rng(20261104)
    t = times(MOTOR_S)
    x = np.zeros_like(t)
    #        Hz: amount (30 = the frame shaking, 60 = one turn of the prop, 180 = the blades, 840 = the motor's poles)
    tones = {30: 0.40, 60: 0.55, 120: 0.35, 180: 1.0, 240: 0.15, 360: 0.70, 540: 0.48, 720: 0.32, 900: 0.20, 1080: 0.12,
             840: 0.17, 1680: 0.10, 2520: 0.04}
    for hz, amount in tones.items():
        x += amount * np.sin(2 * np.pi * hz * t + rng.random() * 6.283) * wander(rng, t, MOTOR_S, (3, 5, 7, 11), 0.18)
    air = loop_noise(rng, MOTOR_S, lambda f: np.where((f > 40) & (f < 7000), (np.maximum(f, 1) / 180) ** -0.9, 0))
    # (the blades chop the air: the thrum of a big rotor)
    chop = (1 + 0.45 * np.sin(2 * np.pi * BLADE_HZ * t)) * (1 + 0.3 * np.sin(2 * np.pi * 60 * t + 1.0))
    x = x / np.max(np.abs(x)) + 0.22 * air * chop * wander(rng, t, MOTOR_S, (2, 9), 0.25)
    x = np.tanh(1.8 * x / np.max(np.abs(x)))
    return x / np.max(np.abs(x)) * 0.8


def wind():
    rng = np.random.default_rng(20261105)
    seconds = 8.0
    t = times(seconds)
    x = loop_noise(rng, seconds, lambda f: np.where(f > 30, 1 / (1 + (f / 250) ** 2) ** 0.6, 0))
    x = x * wander(rng, t, seconds, (1, 2, 3, 5), 0.35)
    return x / np.max(np.abs(x)) * 0.7


# the loop played from start at pitches(t), as the engine's resampler would, for len(pitches) samples
def played(loop, pitches, start):
    at = (start * SR + np.cumsum(pitches)) % len(loop)
    i = at.astype(int)
    k = at - i
    return loop[i] * (1 - k) + loop[(i + 1) % len(loop)] * k


def preview(loop):
    t = times(9.0)
    share = np.interp(t, (0, 1.5, 3, 4.5, 6, 7.5, 9), (0.08, 0.08, 0.385, 0.385, 1.0, 1.0, 0.08))
    x = np.zeros_like(t)
    for k in range(4):
        pitch = np.clip((PITCH_LOW + (PITCH_HIGH - PITCH_LOW) * np.sqrt(share)) * DETUNE[k], 0.4, 2.0)
        vol = MOTOR_VOL * np.minimum(share / MOTOR_FADE, 1) * (MOTOR_FLOOR + (1 - MOTOR_FLOOR) * share ** 0.7)
        x += vol * played(loop, pitch, START[k])
    return x / max(1, np.max(np.abs(x)))


def write(name, x):
    os.makedirs(OUT, exist_ok=True)
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
    print("%s: %.1f s, peak %.2f" % (name, len(x) / SR, np.max(np.abs(x))))


# (where a sound's energy sits, in Hz; how much of it is under 300 Hz; RMS over peak; the jump where the loop joins against
# the largest jump inside it)
def measure(x):
    p = np.abs(np.fft.rfft(x)) ** 2
    f = np.fft.rfftfreq(len(x), 1 / SR)
    d = np.abs(np.diff(x))
    return {"centroid": float(np.sum(f * p) / np.sum(p)), "under300": float(np.sum(p[f < 300]) / np.sum(p)),
            "rms_peak": float(np.sqrt(np.mean(x * x)) / np.max(np.abs(x))), "seam": float(abs(x[0] - x[-1]) / np.max(d))}


if __name__ == "__main__":
    m = motor()
    write("BikeMotor", m)
    write("BikeWind", wind())
    write("BikePreview", preview(m))
    print("BikeMotor", {k: round(v, 3) for k, v in measure(m).items()})
