"""Real supervisor and wrappers with inert self-hosted children; never start audio capture."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('xcrun'), 'macOS Swift required')
class ResidentWorkerTests(unittest.TestCase):
    def test_owned_worker_deadlines_cancellation_and_restart(self):
        with tempfile.TemporaryDirectory(prefix='mesh-resident-worker-') as directory:
            tmp = Path(directory)
            # Compile the unchanged production Kokoro wrapper prefix, excluding the legacy
            # UI/session below it. Parakeet is compiled whole, with capture never constructed.
            source = (ROOT / 'ops/work_mac_copilot_app/M4LocalVoiceSession.swift').read_text()
            (tmp / 'Kokoro.swift').write_text(source.split('final class M4LocalAudioPlayerDelegate', 1)[0] + '\n#endif\n')
            binary = tmp / 'fixture'
            result = subprocess.run(['xcrun','swiftc','-D','M4_LOCAL_VOICE_SESSION','-module-cache-path',str(tmp/'cache'),
                '-target','arm64-apple-macos14.0','-parse-as-library',
                str(ROOT/'ops/work_mac_copilot_app/M4ResidentJSONWorker.swift'),
                str(ROOT/'ops/work_mac_copilot_app/M4ParakeetSpeechInput.swift'),str(tmp/'Kokoro.swift'),
                str(ROOT/'tests/mesh_resident_worker_fixture.swift'),'-o',str(binary)],capture_output=True,text=True,timeout=90)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            result = subprocess.run([str(binary)],capture_output=True,text=True,timeout=25)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('PASS resident worker lifecycle',result.stdout)

if __name__ == '__main__':
    unittest.main()
