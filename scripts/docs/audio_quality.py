"""Draws the charts and tables in docs/audio-quality.md.

    python3 scripts/docs/audio_quality.py

The numbers are measurements made once, by the tests the page names. They live
here, except the frequency response curves, which are in
docs/audio-quality/response.json because they are too long to read inline.

Every chart lists Vibe first, in blue, then Apple's, in orange, then
anything else, in gray. Rate pairs, formats and pitch settings keep one order.
"""
import json
from pathlib import Path

from charts import bars, curves, flow, table

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/audio-quality'
VIBE, APPLE, OTHER = 0, 1, 'gray'
PAIRS = ['44.1 → 48', '48 → 44.1', '44.1 → 96', '96 → 44.1', '88.2 → 44.1', '96 → 48', '192 → 48', '44.1 → 192']
LOWER = 'Lower is better. Green is the best in each row, red the worst.'


def ms(v):
    return (f'{v:,.0f} ms' if v >= 10 else f'{v:g} ms', v)


def db(v):
    return (f'{v:.1f}'.replace('-', '−'), v)


def pct(v, decimals=3):
    return f'{v:.{decimals}f}%'


def choice(title, rows):
    """What Vibe uses, the alternatives, and why each lost: (option, verdict, reason)."""
    tint = {'Chosen': 'good', 'Rejected': 'bad'}
    subtitle = 'Green is what Vibe uses. Red is what it doesn\'t.'
    if any(verdict == 'Fallback' for _, verdict, _ in rows):
        subtitle += ' The fallback covers what the choice can\'t.'
    return table(title, subtitle, ['Verdict', 'Why'],
                 [(name, [(verdict, tint[verdict]) if verdict in tint else verdict, reason], None)
                  for name, verdict, reason in rows], wrap_at={1: 420})


def lossy_choice():
    return choice('Formats for lossy files in bit-perfect output', [
        ('Float', 'Chosen', 'Keeps every decoded sample, peaks above full scale included.'),
        ('Widest integer', 'Fallback', 'Used when the device has no float format. Keeps the detail, but clips the '
                                       'peaks.'),
        ('16-bit', 'Rejected', 'Adds noise at −101 dBFS, and clips the peaks.')])


def mp3_choice():
    return choice('MP3 decoders considered', [
        ('dr_mp3', 'Chosen', 'Full precision, keeps the peaks, and 105 times inside the ISO limit. Less than half '
                             'the CPU of Apple\'s. One header file under a permissive license.'),
        ('Apple\'s decoder', 'Rejected', 'Only 16-bit on Apple silicon. Clips the peaks and silences the last 12 ms '
                                         'on every Mac. Still a choice in Settings > Advanced.'),
        ('BASS', 'Rejected', 'Matches dr_mp3 to the last bit or two, with about 15% more CPU. A 0.9 MB '
                             'closed-source library, free only for non-commercial use.'),
        ('FFmpeg, libmad, mpg123', 'Rejected', 'About as accurate. Copyleft licenses (LGPL or GPL), and each needs '
                                              'its own build.')])


def flac_choice():
    return choice('FLAC decoders considered', [
        ('dr_flac', 'Chosen', 'The same samples as Apple\'s, bit for bit. Uses the seek table. A quarter of the '
                              'CPU or less. Plays legal files Apple\'s refuses.'),
        ('Apple\'s decoder', 'Rejected', 'Ignores the seek table. A first seek into a long file can take seconds. '
                                         '4 to 7 times the CPU, and reads the file 2.4 to 5 times over.')])


def wav_choice():
    return choice('WAV and AIFF decoders considered', [
        ('dr_wav', 'Chosen', 'The same samples as Apple\'s, bit for bit. 1.4 to 3.2 times faster. Exact seeks in '
                             'IMA4, and plays 24 and 32-bit little-endian AIFF.'),
        ('Apple\'s decoder', 'Fallback', 'Inexact seeks in IMA4. Plays 24 and 32-bit little-endian AIFF at the '
                                         'wrong length. Still decodes what dr_wav can\'t.')])


def resampler_choice():
    return choice('Resamplers considered', [
        ('r8brain-free-src', 'Chosen', 'Cleaner on 90 of 103 measurements, and 8 to 30 times less CPU than '
                                       'Apple\'s. Its highest-precision preset, with a steep filter.'),
        ('Apple\'s converter', 'Rejected', 'More noise and distortion at every rate pair, even at its highest '
                                           'quality. 8 to 30 times the CPU.'),
        ('BASS', 'Rejected', 'Its default dulls the treble and passes 63 of 184 checks. Its highest setting passes '
                             '67, and costs more CPU than r8brain. Closed source.'),
        ('r8brain\'s default filter', 'Rejected', 'Cheaper, but starts rolling off at 21.39 kHz instead of '
                                                  '21.72 kHz.'),
        ('r8brain with dither', 'Rejected', 'Fixes five tiny cases where Apple measured better. Raises the noise '
                                            'everywhere else.')])


def pitch_choice():
    return choice('Pitch converters considered', [
        ('Vibe\'s converter', 'Chosen', 'Follows the fader as it moves. −148 dB or better at every setting, flat '
                                        'to 20 kHz, and it glides when dragged.'),
        ('Apple\'s Varispeed', 'Rejected', 'A third of the CPU. Its error reaches −83 dB at 20 kHz, it cuts the '
                                           'top end, and it jumps when dragged. Used before 1.16.'),
        ('Vibe\'s resampler', 'Rejected', 'Fixes its ratio when it\'s created. It can\'t follow the fader.'),
        ('A wider filter', 'Rejected', 'Flat to 20 kHz at −8%. Lets a 23.8 kHz tone back in at −101 dB at +1%.')])


def signal_path():
    return flow('Where the samples go', 'Every file decodes to 32-bit float. A dashed stage leaves the samples '
                'alone until you use it.', [
                    ('Regular output', 'Mac. Effects, pitch and other apps can play.', [
                        ('Decode', 'to 32-bit float', False),
                        ('Resample', 'if the rates differ', True),
                        ('Declick', '10 ms at the edges', True),
                        ('Pitch', 'away from 0%', True),
                        ('DJ FX', 'while in use', True),
                        ('Volume', 'below full only', True),
                        ('macOS', 'mixes, converts', False)]),
                    ('Bit-perfect output', 'Mac. The device is set to the file\'s rate.', [
                        ('Decode', 'to 32-bit float', False),
                        ('Declick', '10 ms, or off', True),
                        ('Volume', 'below full only', True),
                        ('Your device', 'the file\'s rate', False)]),
                    ('iPhone and iPad', 'iOS picks the rate for the route.', [
                        ('Decode', 'to 32-bit float', False),
                        ('Resample', 'if not the route\'s', True),
                        ('Declick', '10 ms at the edges', True),
                        ('DJ FX', 'while in use', True),
                        ('iOS', 'the route', False)])])


def lossy_decoders():
    good, bad = 'good', 'bad'
    return table('What each MP3 and AAC decoder hands Vibe',
                 'The loud test master, decoded the way Vibe decodes it. Green is good for the sound, red is bad.',
                 ['Precision', 'Peaks above full scale', 'If sent to the device as 16-bit'], [
                     ('MP3, Vibe', [('32-bit float', good), ('Kept, up to +0.49 dBFS', good),
                                             ('Adds noise, clips the peaks', bad)], None),
                     ('AAC, Apple', [('32-bit float', good), ('Kept, up to +0.79 dBFS', good),
                                     ('Adds noise at −101 dBFS, clips the peaks', bad)], None),
                     ('MP3, Apple on Apple silicon', [('16-bit only', bad), ('Clipped by the decoder', bad),
                                                      'Nothing, it is already 16-bit'], None),
                     ('MP3, Apple on Intel', [('32-bit float', good), ('Clipped at full scale', bad),
                                              ('Adds noise at −101 dBFS', bad)], None)])


def mp3_quality():
    good, bad = 'good', 'bad'
    return table('MP3 decoders: what you hear', 'Green is the best in each row, red the worst.',
                 ['Vibe', 'Apple,\nApple silicon', 'Apple,\nIntel', 'BASS'], [
                     ('Output', [('32-bit float', good), ('16-bit', bad), ('32-bit float', good),
                                 ('32-bit float', good)], None),
                     ('Error on a quiet passage, below the music', [('127 dB', 127), ('31 dB', 31), None,
                                                                    ('127 dB', 127)], 'higher'),
                     ('ISO accuracy, times inside the limit', [('105×', 105), ('1×', 1), ('150×', 150),
                                                               ('100×', 100)], 'higher'),
                     ('Peaks on a loud master', [('Kept', good), ('Clipped', bad), ('Clipped', bad),
                                                 ('Kept', good)], None),
                     ('Last 12 ms without gapless info', [('Played', good), ('Silent', bad), ('Silent', bad),
                                                          None], None)])


def mp3_accuracy():
    return bars('Accuracy on the ISO MP3 test',
                'How many times inside the ISO\'s full-accuracy limit each decoder stays, on its worst of seven '
                'test streams. 1× is right on the limit. Higher is better.',
                [('', [105, 1, 150, 100, 112, 106, 106])],
                [('Vibe', VIBE), ('Apple, Apple silicon', APPLE), ('Apple, Intel', APPLE),
                 ('BASS', OTHER), ('FFmpeg', OTHER), ('libmad', OTHER), ('mpg123', OTHER)],
                lambda v: f'{v:g}×')


def mp3_cost():
    return table('MP3 decoders: what they cost', 'A 320 kbps MP3 on an M4 Max. ' + LOWER,
                 ['Vibe', 'Apple', 'BASS'], [
                     ('CPU to play, fast core', [(pct(0.042), 0.042), (pct(0.096), 0.096), (pct(0.050), 0.050)],
                      'lower'),
                     ('CPU to play, efficiency core', [('0.12%', 0.12), ('0.32%', 0.32), ('0.14%', 0.14)], 'lower'),
                     ('Energy per hour of music', [('8.1 J', 8.1), ('16.8 J', 16.8), ('9.6 J', 9.6)], 'lower'),
                     ('Decoding a whole 6.5-minute track', [ms(161), ms(361), ms(188)], 'lower'),
                     ('Opening a file', [ms(0.06), ms(0.09), None], 'lower'),
                     ('Seeking, then reading 4,096 frames', [ms(0.15), ms(0.17), None], 'lower'),
                     ('Slowest 4,096-frame read', [ms(0.75), ms(2.4), None], 'lower'),
                     ('Memory per open file', [('60 KB', 60), ('177 KB', 177), '30 KB*'], 'lower'),
                     ('Data read to play a 15 MB file', [('17 MB', 17), ('235 MB', 235), '15.7 MB*'], 'lower'),
                     ('Added to the app', [('48 KB', 48), ('Nothing', 0), ('0.9 MB', 900)], 'lower')])


def mp3_cpu():
    files = [('CBR 320 kbps', 0.042, 0.096, 0.050), ('CBR 128 kbps', 0.031, 0.082, 0.037),
             ('VBR V0', 0.042, 0.100, 0.048), ('VBR V5', 0.031, 0.082, 0.036),
             ('CBR 256 kbps, 48 kHz', 0.039, 0.097, 0.046), ('Mono 64 kbps', 0.019, 0.042, 0.023),
             ('MPEG-2, 22.05 kHz', 0.017, 0.043, 0.019), ('MPEG-2.5, 11 kHz', 0.007, 0.018, 0.007),
             ('MP2 256 kbps', 0.023, 0.066, 0.030), ('Real track A, 320 kbps', 0.043, 0.097, 0.049),
             ('Real track B, 320 kbps', 0.042, 0.096, 0.048)]
    return bars('CPU to play each MP3',
                'Percent of one fast core on an M4 Max, the fastest of seven whole-file decodes. Lower is better.',
                [(name, list(v)) for name, *v in files],
                [('Vibe', VIBE), ('Apple', APPLE), ('BASS', OTHER)], lambda v: pct(v),
                fmt_tick=lambda v: f'{v:g}%')


def flac_seek():
    return table('FLAC: the first seek into a part not read yet',
                 'The file read from the SSD, not from memory. ' + LOWER,
                 ['Vibe', 'Apple'], [
                     ('Middle of a 4-minute track (27 MB)', [ms(0.9), ms(51)], 'lower'),
                     ('90% into it', [ms(1.4), ms(93)], 'lower'),
                     ('Middle of a 77-minute mix (604 MB)', [ms(2.6), ('1.16 s', 1160)], 'lower'),
                     ('90% into it', [ms(2.7), ('2.11 s', 2110)], 'lower')])


def flac_cost():
    return table('FLAC: what each decoder costs',
                 'Ranges run across 13 real tracks, 16 and 24-bit, 44.1 to 192 kHz. ' + LOWER,
                 ['Vibe', 'Apple'], [
                     ('CPU to play, fast core', [('0.022–0.10%', 0.10), ('0.086–0.58%', 0.58)], 'lower'),
                     ('CPU to play, efficiency core', [('0.057–0.41%', 0.41), ('0.26–1.9%', 1.9)], 'lower'),
                     ('Decoding a 3-minute 24/96 track, efficiency core', [('0.30 s', 0.30), ('1.59 s', 1.59)],
                      'lower'),
                     ('Decoding a 4-minute 16-bit track, fast core', [ms(55), ms(230)], 'lower'),
                     ('Data read to play a file', [('Its size', 1), ('2.4–5.1× its size', 5.1)], 'lower'),
                     ('Memory per open file', [('54–98 KB', 98), ('1.3–2.8 MB', 2800)], 'lower'),
                     ('Opening a file', [('0.3–0.5 ms', 0.5), ('0.5–0.8 ms', 0.8)], 'lower'),
                     ('Slowest 4,096-frame read, fast core', [ms(0.08), ms(0.85)], 'lower'),
                     ('Added to the app', [('118 KB', 118), ('Nothing', 0)], 'lower')])


def wav_decode():
    files = [('16-bit, 44.1 kHz WAV', 10, 21, 53, 116), ('24-bit, 96 kHz WAV', 33, 68, 154, 371),
             ('24-bit, 96 kHz AIFF', 32, 101, 166, 506), ('32-bit float, 96 kHz WAV', 39, 54, 172, 282)]
    return table('WAV and AIFF: decoding a whole 10-minute file', 'Stereo, on an M4 Max. ' + LOWER,
                 ['Vibe', 'Apple', 'Vibe', 'Apple'],
                 [(name, [ms(v) for v in vals], 'lower') for name, *vals in files],
                 spans=[('Fast core', 0, 1), ('Efficiency core', 2, 3)], compare=[[0, 1], [2, 3]])


THDN = ([-149.2, -150.0, -149.6, -151.2, -152.4, -152.6, -152.5, -149.6],
        [-145.8, -146.2, -145.9, -148.1, -148.7, -148.9, -147.9, -146.2])
TONES = ([-149.0, -149.1, -149.0, -150.3, -151.7, -151.7, -151.7, -148.9],
         [-145.6, -146.0, -145.6, -148.2, -147.3, -147.3, -150.3, -145.7])
ROUND_TRIP = ([-149.9, -149.4, -151.3, -148.9, -150.2, -150.2, -149.5, -151.8],
              [-143.3, -143.2, -145.7, -144.3, -142.7, -142.5, -145.8, -148.0])
CPU = ([0.098, 0.116, 0.127, 0.121, 0.061, 0.068, 0.115, 0.180],
       [0.890, 0.900, 1.771, 1.758, 1.595, 1.742, 3.489, 3.529])


def resampler_response():
    data = json.loads((OUT / 'response.json').read_text())

    def khz(v):
        return f'{v / 1000:g}k'

    return curves('Frequency response, 44.1 → 96 kHz',
                  'An impulse through each converter. Left: the whole output. Everything above 22.05 kHz is an '
                  'image of the input and has to go. Right: the top of the band, where both stay flat to 21.7 kHz.',
                  [dict(xs=data['wide']['hz'], series=[data['wide']['vibe'], data['wide']['apple']],
                        x=(0, 48000, 8000, khz), y=(-210, 0, 30), xlabel='Hz', ylabel='dB',
                        caption='The whole band'),
                   dict(xs=data['edge']['hz'], series=[data['edge']['vibe'], data['edge']['apple']],
                        x=(19000, 22000, 1000, khz), y=(-12, 0, 3), xlabel='Hz', ylabel='dB',
                        caption='The top of the band')],
                  [('Vibe', VIBE), ('Apple', APPLE)])


def resampler_quality():
    rows = [(f'{p} kHz', [db(THDN[0][i]), db(THDN[1][i]), db(TONES[0][i]), db(TONES[1][i]),
                          db(ROUND_TRIP[0][i]), db(ROUND_TRIP[1][i])], 'lower') for i, p in enumerate(PAIRS)]
    return table('Resampling: everything that isn\'t the music',
                 'In dB against the signal. More negative is better. Green is better, red is worse.',
                 ['Vibe', 'Apple'] * 3, rows,
                 spans=[('Worst distortion + noise', 0, 1), ('Twenty tones vs. a perfect copy', 2, 3),
                        ('There and back', 4, 5)], compare=[[0, 1], [2, 3], [4, 5]])


def resampler_cpu():
    return bars('CPU to resample in real time',
                'Percent of one core, measured in the player. Lower is better.',
                [(f'{p} kHz', [CPU[0][i], CPU[1][i]]) for i, p in enumerate(PAIRS)],
                [('Vibe', VIBE), ('Apple', APPLE)], lambda v: pct(v, 2), fmt_tick=lambda v: f'{v:g}%')


def resampler_dither():
    return table('Why there is no dither',
                 'Five of the cases where Apple measured better, and the noise everywhere else. In dB, more negative '
                 'is better.', ['Vibe,\nas shipped', 'Vibe,\nwith dither', 'Vibe, before\nfinal rounding',
                                'Apple'], [
                     ('CCIF intermodulation, 44.1 → 48', [db(-167.5), db(-173.7), db(-172.4), db(-173.1)], 'lower'),
                     ('CCIF intermodulation, 44.1 → 96', [db(-166.6), db(-171.8), db(-172.4), db(-171.1)], 'lower'),
                     ('SMPTE intermodulation, 48 → 44.1', [db(-158.4), db(-161.8), db(-162.6), db(-160.0)], 'lower'),
                     ('6 kHz tone distortion, 48 → 44.1', [db(-161.6), db(-170.0), db(-169.7), db(-165.8)], 'lower'),
                     ('1 kHz tone distortion, 192 → 48', [db(-157.2), db(-165.6), db(-165.9), db(-161.7)], 'lower'),
                     ('Noise, every other measurement', [('−150 to −157', -150), ('−147 to −148', -147),
                                                         ('−153 to −180', -153), None], 'lower')])


def resampler_setups():
    rows = [('44.1 → 48', 0.092, 0.102, 0.110, 0.107, 0.077), ('48 → 44.1', 0.098, 0.105, 0.116, 0.114, 0.080),
            ('44.1 → 96', 0.124, 0.131, 0.141, 0.137, 0.106), ('96 → 44.1', 0.119, 0.126, 0.139, 0.142, 0.095),
            ('192 → 48', 0.113, 0.117, 0.126, 0.127, 0.096), ('44.1 → 192', 0.175, 0.181, 0.202, 0.211, 0.152)]
    return table('Resampler setups tried',
                 'Percent of one core, two minutes of stereo, the middle of three runs. ' + LOWER,
                 ['Shipped', 'Extra FFT\npadding', 'Padding,\nno NEON', 'Another FFT\nlibrary', 'Default filter,\npadding'],
                 [(f'{p} kHz', [(f'{v:.3f}', v) for v in vals], 'lower') for p, *vals in rows])


def resampler_bass():
    return table('Vibe, Apple and BASS',
                 'The worst of the eight rate pairs unless the row says otherwise. Green is the best in each row, '
                 'red the worst.', ['Vibe', 'Apple', 'BASS,\nhighest', 'BASS,\ndefault'], [
                     ('Top end, 3 dB down (44.1 → 48)', [('21.83 kHz', 21830), ('21.80 kHz', 21800),
                                                         ('21.57 kHz', 21565), ('17.40 kHz', 17398)], 'higher'),
                     ('Distortion + noise (dB)', [db(-149.2), db(-145.8), db(-38.6), db(-19.8)], 'lower'),
                     ('Noise under a quiet tone (dB)', [db(-208.7), db(-205.6), db(-126.2), db(-126.1)], 'lower'),
                     ('Loudest false tone, converting down (dB)', [db(-154.2), db(-147.9), db(-76.3), db(-9.9)],
                      'lower'),
                     ('Twenty tones vs. a perfect copy (dB)', [db(-148.9), db(-145.6), db(-45.1), db(-15.5)], 'lower'),
                     ('CPU, 44.1 → 48 (% of one core)', [('0.090', 0.090), ('0.864', 0.864), ('1.159', 1.159),
                                                         ('0.081', 0.081)], 'lower'),
                     ('Checks passed, of 184', [('184', 184), ('184', 184), ('67', 67), ('63', 63)], 'higher')])


def pitch_quality():
    return table('The pitch fader: Vibe and Apple\'s Varispeed',
                 'Six settings from −16% to +16% at 48 kHz, as ranges. In dB against the signal unless the row '
                 'says otherwise. ' + LOWER, ['Vibe', 'Apple'], [
                     ('Distortion + noise, 1 kHz tone', [('−150 to −152', -150), ('−129 to −135', -129)], 'lower'),
                     ('Distortion + noise, 10 kHz tone', [('−150 to −153', -150), ('−93 to −99', -93)], 'lower'),
                     ('Distortion + noise, 20 kHz, −8% to +16%', [('−148 to −151', -148), ('−83 to −87', -83)],
                      'lower'),
                     ('Twenty tones at once', [('−149 to −150', -149), ('−96 to −99', -96)], 'lower'),
                     ('False tones when speeding up', [('−148 to −149', -148), ('−114 to −133', -114)], 'lower'),
                     ('CPU, % of one core', [('0.20–0.24%', 0.24), ('0.07%', 0.07)], 'lower')])


def pitch_top_end():
    rows = [('−16%', -123, -131), ('−8%', -3.0, -7.8), ('−1%', 0.0, -0.05), ('+1%', 0.0, -1.49),
            ('+8%', 0.0, -0.77), ('+16%', 0.0, -0.33)]

    def level(v):
        return (f'{v:.2f}' if abs(v) < 1 else f'{v:.1f}' if abs(v) < 10 else f'{v:.0f}').replace('-', '−'), v

    return table('The pitch fader: level of a 20 kHz tone',
                 'In dB, at 48 kHz. 0 is no loss, so higher is better. Green is better, red is worse.',
                 ['Vibe', 'Apple'],
                 [(f'Fader at {name}', [level(a), level(b)], 'higher') for name, a, b in rows])


CHARTS = {
    'signal-path': signal_path,
    'lossy-choice': lossy_choice,
    'lossy-decoders': lossy_decoders,
    'mp3-choice': mp3_choice,
    'flac-choice': flac_choice,
    'wav-choice': wav_choice,
    'resampler-choice': resampler_choice,
    'pitch-choice': pitch_choice,
    'mp3-quality': mp3_quality,
    'mp3-accuracy': mp3_accuracy,
    'mp3-cost': mp3_cost,
    'mp3-cpu': mp3_cpu,
    'flac-seek': flac_seek,
    'flac-cost': flac_cost,
    'wav-decode': wav_decode,
    'resampler-response': resampler_response,
    'resampler-quality': resampler_quality,
    'resampler-cpu': resampler_cpu,
    'resampler-dither': resampler_dither,
    'resampler-setups': resampler_setups,
    'resampler-bass': resampler_bass,
    'pitch-quality': pitch_quality,
    'pitch-top-end': pitch_top_end,
}


def main():
    page = (ROOT / 'docs/audio-quality.md').read_text()
    for name, draw in CHARTS.items():
        (OUT / f'{name}.svg').write_text(draw())
        if f'audio-quality/{name}.svg' not in page:
            print(f'audio_quality: docs/audio-quality.md does not show {name}.svg')
    print(f'audio_quality: {len(CHARTS)} charts')


if __name__ == '__main__':
    main()
