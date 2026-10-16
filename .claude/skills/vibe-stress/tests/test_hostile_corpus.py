import importlib.util
import random
import struct
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "make-hostile-corpus.py"
spec = importlib.util.spec_from_file_location("make_hostile_corpus", SCRIPT)
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)


def riff_chunks(data, at, big=False):
    """{tag: (size offset, size)} of a RIFF or AIFF file's top-level chunks."""
    chunks = {}
    while at + 8 <= len(data):
        tag = data[at:at + 4]
        size = struct.unpack_from(">I" if big else "<I", data, at + 4)[0]
        chunks[tag] = (at + 4, size)
        at += 8 + size + (size & 1)
    return chunks


def w64_chunks(data, at=40):
    """{tag: (size offset, body size)}; a size field under its own header
    (the size-zero shape) ends the walk, as it would end a reader's."""
    chunks = {}
    while at + 24 <= len(data):
        size = struct.unpack_from("<Q", data, at + 16)[0]
        chunks[data[at:at + 4]] = (at + 16, size - 24)
        if size < 24:
            break
        at += size + (-size % 8)
    return chunks


class MalformedAudioTests(unittest.TestCase):
    """Each shape must damage the field its name says. A mutation on the wrong
    byte makes a fixture that misses its advertised failure case."""

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory()
        cls.folder = Path(cls.dir.name)
        corpus.malformed_audio(cls.folder, random.Random(1))

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def shape(self, name):
        return (self.folder / name).read_bytes()

    def test_rf64_size_shapes_hit_the_data_chunk(self):
        chunks = riff_chunks(self.shape("rf64-size-zero.wav"), 12)
        self.assertEqual(chunks[b"data"][1], 0)
        self.assertEqual(riff_chunks(self.shape("rf64-size-odd.wav"), 12)[b"data"][1], 1001)

    def test_w64_size_shapes_hit_the_data_chunk(self):
        self.assertEqual(w64_chunks(self.shape("w64-size-zero.w64"))[b"data"][1], -24)
        self.assertEqual(w64_chunks(self.shape("w64-size-odd.w64"))[b"data"][1], 1001 - 24)

    def test_ms_adpcm_shapes_hit_the_fact_count_and_the_data_size(self):
        chunks = riff_chunks(self.shape("msadpcm-fact-count-past-data.wav"), 12)
        count = struct.unpack_from("<I", self.shape("msadpcm-fact-count-past-data.wav"), chunks[b"fact"][0] + 4)[0]
        self.assertEqual(count, 40 * 500 * 3)
        self.assertEqual(riff_chunks(self.shape("msadpcm-size-zero.wav"), 12)[b"data"][1], 0)

    def test_flac_rate_and_count_shapes_hit_the_streaminfo_fields(self):
        word = struct.unpack_from(">Q", self.shape("flac-extreme-rate.flac"), 18)[0]
        self.assertEqual(word >> 44, 0xFFFFF)
        self.assertEqual(word & ((1 << 36) - 1), 22050)
        word = struct.unpack_from(">Q", self.shape("flac-extreme-count.flac"), 18)[0]
        self.assertEqual(word & ((1 << 36) - 1), (1 << 36) - 1)
        self.assertEqual(word >> 44, 44100)


if __name__ == "__main__":
    unittest.main()
