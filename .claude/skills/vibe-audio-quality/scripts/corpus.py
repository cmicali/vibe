#!/usr/bin/env python3
"""Fetch public audio test corpora and run Vibe's decoders over them.

    corpus.py list                  each corpus, and whether it is downloaded
    corpus.py fetch NAME...         download into build/audio-quality/corpora/NAME
    corpus.py run NAME... | all     fetch what is missing, run the corpus test, record the results
    corpus.py run NAME --no-record  run, but leave docs/audio-quality/corpora.json alone

Each corpus is pinned to a commit, a dated archive or a published list. Only
the files Vibe plays are kept, beside the reference decodes the checks use.
Nothing downloaded is committed. A run writes its summary to
docs/audio-quality/corpora.json and redraws the page's corpus chart.
"""
import argparse
import datetime
import io
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
HOME = ROOT / 'build/audio-quality'
SUMMARY = ROOT / 'docs/audio-quality/corpora.json'
PLAYABLE = set(re.findall(r'@"(\w+)"', re.search(r'ordered = @\[(.*?)\];', (ROOT / 'Vibe/Common/PlayableExtensions.m')
                                                .read_text(), re.S).group(1)))

FLAC_COMMIT = 'aa7b0c6cf32994c106ae517a08134c28a96ff5b2'
ISO = 'https://standards.iso.org/iso-iec/14496/-26/ed-2/en/'
FATE = 'rsync://fate-suite.ffmpeg.org/fate-suite/'
FATE_DIRS = ['aac', 'audio-reference', 'audiomatch', 'caf', 'cover_art', 'gapless', 'id3v2', 'lossless-audio',
             'mp3-conformance', 'mpegaudio', 'ogg', 'ogg-flac', 'ogg-opus', 'ogg-vorbis', 'opus', 'vorbis', 'w64', 'wav']
MCGILL = 'https://www.mmsp.ece.mcgill.ca/Documents/AudioFormats/{}/Samples.html'
BW64_COMMIT = 'd3dae5c74deada286994c8a4c2a03edd82d65589'
CHROMIUM_COMMIT = 'e21a6b229410b91fc783268c812133b0f30ec1ce'
FIREFOX_COMMIT = 'd0e0fc69c10b345e8e1a83bae3d2da774970704d'
TAGLIB_TAG = 'v2.3.2'

# A file the corpus itself gets wrong, with the reason. It counts as known, not failed.
KNOWN = {
    'fate': {
        'vorbis/6.ogg': "FFmpeg's reference interleaves the six channels in WAVE order. Vibe keeps Vorbis I's order and "
                        'labels each channel. Put in WAVE order, the decode matches to an RMS of 3.6e-6.',
    },
}


def playable(name):
    return posixpath.splitext(name)[1][1:].lower() in PLAYABLE and '.ref.' not in name


def get(url, headers=None):
    request = urllib.request.Request(url, headers={'User-Agent': 'vibe-audio-quality', **(headers or {})})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def tarball(url, dest, keep):
    """The members `keep` maps to a path under dest, from a gzipped tarball streamed from url."""
    request = urllib.request.Request(url, headers={'User-Agent': 'vibe-audio-quality'})
    with urllib.request.urlopen(request, timeout=600) as response, tarfile.open(fileobj=response, mode='r|gz') as tar:
        for member in tar:
            name = keep(member.name) if member.isfile() else None
            if name:
                save(dest / name, tar.extractfile(member).read())


class Remote(io.RawIOBase):
    """A file read over HTTP range requests, so zipfile can take single members of a large archive."""

    def __init__(self, url):
        self.url, self.pos = url, 0
        request = urllib.request.Request(url, method='HEAD', headers={'User-Agent': 'vibe-audio-quality'})
        self.size = int(urllib.request.urlopen(request, timeout=120).headers['Content-Length'])

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        self.pos = offset if whence == 0 else self.pos + offset if whence == 1 else self.size + offset
        return self.pos

    def readinto(self, buffer):
        if self.pos >= self.size:
            return 0
        data = get(self.url, {'Range': f'bytes={self.pos}-{min(self.pos + len(buffer), self.size) - 1}'})
        buffer[:len(data)] = data
        self.pos += len(data)
        return len(data)


def fetch_flac(dest):
    def keep(name):
        parts = name.split('/')
        return '/'.join(parts[1:]) if len(parts) == 3 and parts[1] in ('subset', 'uncommon', 'faulty') \
            and playable(name) else None
    tarball(f'https://codeload.github.com/ietf-wg-cellar/flac-test-files/tar.gz/{FLAC_COMMIT}', dest, keep)


def fetch_iso(dest):
    # Every Layer III stream, as .mp3, and ISO's reference decode beside each one that has one.
    streams = set()
    with zipfile.ZipFile(io.BytesIO(get(ISO + 'compressedMpeg12.zip'))) as archive:
        for info in archive.infolist():
            name = posixpath.basename(info.filename)
            if name.startswith('l3_') and name.endswith('.mpg'):
                stem = name[:-4]
                streams.add(stem)
                save(dest / f'{stem}.mp3', archive.read(info))
    with zipfile.ZipFile(io.BufferedReader(Remote(ISO + 'referencesWav.zip'), 1 << 20)) as archive:
        for info in archive.infolist():
            name = posixpath.basename(info.filename)
            if name.endswith('.wav') and name[:-4] in streams:
                save(dest / f'{name[:-4]}.mp3.ref.wav', archive.read(info))


def fetch_fate(dest):
    patterns = [f'--include=*.{e}' for e in sorted(PLAYABLE)] + ['--include=*.bit', '--include=*.pcm', '--include=*.f32']
    for directory in FATE_DIRS:
        target = dest / directory
        target.mkdir(parents=True, exist_ok=True)
        subprocess.run(['rsync', '--contimeout=30', '--timeout=120', '-rltq', '--include=*/', *patterns, '--exclude=*',
                        f'{FATE}{directory}/', f'{target}/'], check=True)
    # Conformance streams as .mp3, each with its reference decode: float where FATE has one, else 16-bit.
    for stream in (dest / 'mp3-conformance').glob('*.bit'):
        stream.rename(stream.with_suffix('.mp3'))
    for directory, extension in (('mp3-conformance', '.mp3'), ('vorbis', '.ogg')):
        for path in list((dest / directory).iterdir()):
            source = path.with_suffix(extension)
            if path.suffix == '.f32' and source.exists():
                path.rename(f'{source}.ref.f32')
            elif path.suffix == '.pcm' and source.exists() and not Path(f'{source}.ref.f32').exists() \
                    and not path.with_suffix('.f32').exists():
                path.rename(f'{source}.ref.s16')
    for leftover in list(dest.rglob('*.pcm')) + list(dest.rglob('*.f32')) + list(dest.rglob('*.bit')):
        if '.ref.' not in leftover.name:
            leftover.unlink()


def fetch_wav(dest):
    for page, folder in (('WAVE', 'mcgill-wave'), ('AIFF', 'mcgill-aiff')):
        url = MCGILL.format(page)
        links = re.findall(r'href="([^"]+\.(?:wav|aif|aiff|aifc))"', get(url).decode('latin-1'), re.I)
        skipped = 0
        for link in sorted(set(links)):
            if not playable(link):
                skipped += 1
                continue
            save(dest / folder / posixpath.basename(link), get(urllib.parse.urljoin(url, link)))
        if skipped:
            print(f'corpus: {folder}: {skipped} files skipped, by an extension Vibe does not play')
    tarball(f'https://codeload.github.com/ebu/libbw64/tar.gz/{BW64_COMMIT}', dest,
            lambda name: f'bw64/{posixpath.basename(name)}' if '/tests/test_data/' in name and playable(name) else None)


def fetch_browser(dest):
    tarball(f'https://chromium.googlesource.com/chromium/src/+archive/{CHROMIUM_COMMIT}/media/test/data.tar.gz', dest,
            lambda name: f'chromium/{name.lstrip("./")}' if playable(name) else None)
    api = 'https://api.github.com/repos/mozilla-firefox/firefox'
    media = json.loads(get(f'{api}/contents/dom/media?ref={FIREFOX_COMMIT}'))
    tree = next(entry['sha'] for entry in media if entry['name'] == 'test')
    for entry in json.loads(get(f'{api}/git/trees/{tree}?recursive=1'))['tree']:
        if entry['type'] == 'blob' and playable(entry['path']):
            raw = f'https://raw.githubusercontent.com/mozilla-firefox/firefox/{FIREFOX_COMMIT}/dom/media/test/{entry["path"]}'
            save(dest / 'firefox' / entry['path'], get(urllib.parse.quote(raw, safe=':/')))


def fetch_taglib(dest):
    tarball(f'https://codeload.github.com/taglib/taglib/tar.gz/refs/tags/{TAGLIB_TAG}', dest,
            lambda name: name.split('/tests/data/', 1)[1] if '/tests/data/' in name and playable(name) else None)


# The paths whose FLAC MD5 the corpus vouches for. Other sets keep shortened
# copies of real files, whose STREAMINFO still states the whole file's MD5.
MD5_VOUCHED = {'flac': '^(subset|uncommon)/'}

CORPORA = {
    'flac': ('IETF CELLAR FLAC test files', f'github.com/ietf-wg-cellar/flac-test-files {FLAC_COMMIT[:12]}', fetch_flac),
    'mp3-iso': ('ISO/IEC 14496-26 Layer III conformance', 'standards.iso.org 14496-26 ed. 2 (2023-01-25)', fetch_iso),
    'fate': ('FFmpeg FATE audio samples', 'fate-suite.ffmpeg.org, ' + ', '.join(FATE_DIRS), fetch_fate),
    'wav': ('McGill WAVE and AIFF samples, EBU BW64 tests', f'mmsp.ece.mcgill.ca, ebu/libbw64 {BW64_COMMIT[:12]}',
            fetch_wav),
    'browser': ('Chromium and Firefox media tests',
                f'chromium {CHROMIUM_COMMIT[:12]}, firefox {FIREFOX_COMMIT[:12]}', fetch_browser),
    'taglib': ('TagLib test data', f'taglib {TAGLIB_TAG}', fetch_taglib),
}


def folder(name):
    return HOME / 'corpora' / name


def fetch(name):
    dest = folder(name)
    if (dest / '.complete').exists():
        return dest
    print(f'corpus: fetching {name} ({CORPORA[name][1]})', flush=True)
    shutil.rmtree(dest, ignore_errors=True)
    CORPORA[name][2](dest)
    count = sum(1 for path in dest.rglob('*') if path.is_file() and playable(path.name))
    (dest / '.complete').write_text(f'{count}\n')
    print(f'corpus: {name}: {count} playable files', flush=True)
    return dest


def run(name, record):
    dest = fetch(name)
    results = HOME / f'{name}.json'
    results.unlink(missing_ok=True)
    log = HOME / f'{name}.log'
    environment = dict(os.environ, TEST_RUNNER_VIBE_AUDIO_QUALITY_CORPUS=str(dest),
                       TEST_RUNNER_VIBE_AUDIO_QUALITY_RESULTS=str(results),
                       TEST_RUNNER_VIBE_AUDIO_QUALITY_MD5=MD5_VOUCHED.get(name, ''))
    print(f'corpus: running {name} (log: {log.relative_to(ROOT)})', flush=True)
    with log.open('w') as out:
        subprocess.run(['make', 'test-audio', 'ARGS=-only-testing:VibeAudioTests/AudioQualityCorpusTests'],
                       cwd=ROOT, env=environment, stdout=out, stderr=subprocess.STDOUT)
    if not results.exists():
        current = Path(f'{results}.current')
        crashed = current.read_text().strip() if current.exists() else None
        sys.exit(f'corpus: {name}: no results. ' + (f'The run died on {crashed}.' if crashed else f'See {log}.'))
    files = json.loads(results.read_text())['files']
    known = KNOWN.get(name, {})
    for r in files:
        if r['failures'] and r['file'] in known:
            r['known'], r['failures'] = known[r['file']], []
    summary = summarize(files)
    report(name, summary, files)
    if record:
        recorded = json.loads(SUMMARY.read_text()) if SUMMARY.exists() else {}
        recorded[name] = {'title': CORPORA[name][0], 'source': CORPORA[name][1],
                          'checked': datetime.date.today().isoformat(), 'groups': summary,
                          'failures': sorted(f'{r["file"]}: {"; ".join(r["failures"])}' for r in files if r['failures']),
                          'known': {r['file']: r['known'] for r in files if r.get('known')}}
        SUMMARY.write_text(json.dumps({k: recorded[k] for k in CORPORA if k in recorded}, indent=2) + '\n')
        subprocess.run([sys.executable, str(ROOT / 'scripts/docs/audio_quality.py')], check=True)


def summarize(files):
    """Counts for each top-level folder of the corpus, or for the corpus when it has none."""
    groups = {}
    for record in files:
        group = record['file'].split('/')[0] if '/' in record['file'] else ''
        g = groups.setdefault(group, dict(files=0, decoded=0, refused=0, valid=0, exact=0, warnings=0, known=0,
                                          failures=0))
        g['files'] += 1
        g['decoded' if record['outcome'] == 'decoded' else 'refused'] += record['outcome'] != 'hang'
        g['valid'] += bool(record.get('valid'))
        g['exact'] += bool(record.get('valid')) and not record['failures'] and not record.get('known')
        g['known'] += bool(record.get('known'))
        g['warnings'] += bool(record['warnings'])
        g['failures'] += bool(record['failures'])
    return groups


def report(name, summary, files):
    print(f'\n{name}: {"group":<24} {"files":>6} {"decoded":>8} {"refused":>8} {"valid":>6} {"exact":>6} '
          f'{"warn":>5} {"known":>6} {"fail":>5}')
    for group, g in summary.items():
        print(f'{"":{len(name)}}  {group or "(all)":<24} {g["files"]:>6} {g["decoded"]:>8} {g["refused"]:>8} '
              f'{g["valid"]:>6} {g["exact"]:>6} {g["warnings"]:>5} {g["known"]:>6} {g["failures"]:>5}')
    for kind in ('failures', 'known', 'warnings'):
        listed = [r for r in files if r.get(kind)]
        if listed:
            print(f'\n{kind}:')
            for r in listed[:60]:
                said = r[kind]
                print(f'  {r["file"]}: {said if isinstance(said, str) else "; ".join(said)}')
            if len(listed) > 60:
                print(f'  … and {len(listed) - 60} more (build/audio-quality/{name}.json)')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', choices=['list', 'fetch', 'run'])
    parser.add_argument('names', nargs='*')
    parser.add_argument('--no-record', action='store_true', help='leave docs/audio-quality/corpora.json alone')
    args = parser.parse_args()
    names = list(CORPORA) if args.names == ['all'] else args.names
    unknown = [n for n in names if n not in CORPORA]
    if unknown or (args.command != 'list' and not names):
        parser.error(f'name a corpus: {", ".join(CORPORA)} or all')
    if args.command == 'list':
        for name, (title, source, _) in CORPORA.items():
            marker = folder(name) / '.complete'
            state = f'{marker.read_text().strip()} files' if marker.exists() else 'not downloaded'
            print(f'{name:<8} {title} ({source}): {state}')
    for name in names:
        fetch(name) if args.command == 'fetch' else run(name, not args.no_record)


if __name__ == '__main__':
    main()
