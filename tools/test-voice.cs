// Tests the bridge's voice loudness by distance and the handheld radio (walkie) sound (Voice.Level, Voice.RadioFx in
// bridge/SurrounSyncBridge.cs). Built with the bridge's sources and run by tools/test-voice.py.

using System;

static class TestVoice
{
    static int failed;

    static void Check(bool ok, string what)
    {
        Console.WriteLine((ok ? "  ok   " : "  FAIL ") + what);
        if (!ok) failed++;
    }

    static byte[] Sine(double hz, double amp, int n, uint rate)
    {
        var b = new byte[n * 2];
        for (int i = 0; i < n; i++)
        {
            int v = (int)(amp * Math.Sin(2 * Math.PI * hz * i / rate));
            b[i * 2] = (byte)(v & 0xff); b[i * 2 + 1] = (byte)((v >> 8) & 0xff);
        }
        return b;
    }

    // loudness of the second half (the filters have settled by then)
    static double Rms(byte[] b)
    {
        int n = b.Length / 2; double s = 0; int c = 0;
        for (int i = n / 2; i < n; i++) { double v = (short)(b[i * 2] | (b[i * 2 + 1] << 8)); s += v * v; c++; }
        return Math.Sqrt(s / c);
    }

    static double Radio(double hz, double amp)
    {
        var b = Sine(hz, amp, 24000, 24000);
        Voice.RadioFx(new VoiceOut(), b, b.Length, 24000, 1.0);
        return Rms(b);
    }

    static int Main()
    {
        bool radio;
        Console.WriteLine("voice_level_by_distance");
        Check(Voice.Level(3, false, out radio) == 1.0 && !radio, "close by: full, plain voice");
        Check(Math.Abs(Voice.Level(30, false, out radio) - (1 - 25 / 45.0)) < 1e-9 && !radio, "30 m without a walkie: as before");
        Check(Voice.Level(60, false, out radio) == 0 && !radio, "60 m without a walkie: not heard, as before");
        Check(Voice.Level(10, true, out radio) > Voice.WalkieLevel && !radio, "10 m with a walkie: the near voice is louder, plain");
        Check(Voice.Level(30, true, out radio) == Voice.WalkieLevel && radio, "30 m with a walkie: through the radio");
        Check(Voice.Level(149, true, out radio) == Voice.WalkieLevel && radio, "149 m with a walkie: still through the radio (3x 50 m)");
        Check(Voice.Level(151, true, out radio) == 0 && !radio, "151 m with a walkie: out of range");
        Check(Voice.Level(999, true, out radio) == 0, "other world (999): nothing even with a walkie");

        Console.WriteLine("walkie_sounds_like_a_radio");
        double low = Radio(100, 8000), mid = Radio(1000, 8000), high = Radio(9000, 8000);
        Check(mid > 2.5 * low, string.Format("100 Hz cut against 1 kHz ({0:0} vs {1:0})", low, mid));
        Check(mid > 2 * high, string.Format("9 kHz cut against 1 kHz ({0:0} vs {1:0})", high, mid));
        var quiet = new byte[48000];
        Voice.RadioFx(new VoiceOut(), quiet, quiet.Length, 24000, 1.0);
        double hiss = Rms(quiet);
        Check(hiss > 20 && hiss < 400, string.Format("a faint hiss under silence ({0:0})", hiss));
        var loud = Sine(1000, 32000, 24000, 24000);
        Voice.RadioFx(new VoiceOut(), loud, loud.Length, 24000, 1.0);
        int peak = 0;
        for (int i = 0; i + 1 < loud.Length; i += 2) peak = Math.Max(peak, Math.Abs((int)(short)(loud[i] | (loud[i + 1] << 8))));
        Check(peak <= 32767 && Rms(loud) > 20000, string.Format("a loud voice is squashed, not wrapped around (peak {0}, rms {1:0})", peak, Rms(loud)));
        // the filters carry over from one packet to the next: two halves on one player = the whole in one go
        var whole = Sine(700, 9000, 4800, 24000);
        var parts = (byte[])whole.Clone();
        Voice.RadioFx(new VoiceOut(), whole, whole.Length, 24000, 0.7);
        var who = new VoiceOut();
        var a = new byte[4800]; var b = new byte[parts.Length - 4800];
        Buffer.BlockCopy(parts, 0, a, 0, a.Length); Buffer.BlockCopy(parts, 4800, b, 0, b.Length);
        Voice.RadioFx(who, a, a.Length, 24000, 0.7); Voice.RadioFx(who, b, b.Length, 24000, 0.7);
        bool same = true;
        for (int i = 0; i < a.Length; i++) if (a[i] != whole[i]) same = false;
        for (int i = 0; i < b.Length; i++) if (b[i] != whole[4800 + i]) same = false;
        Check(same, "one player's radio sound runs on across packets (no click at each packet)");

        Console.WriteLine(failed == 0 ? "ALL PASSED" : failed + " FAILED");
        return failed == 0 ? 0 : 1;
    }
}
