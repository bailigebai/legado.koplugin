"""Credential export boundaries; TLS interoperability is tested separately."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('obsidian_connection', ROOT / 'scripts/obsidian_connection.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# A minimal PEM encoding fixture: verifies exact DER hashing and file export,
# not X.509 handshake validity (covered by the transport tests and real receiver).
LEAF = '-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----\n'
CA = '-----BEGIN CERTIFICATE-----\nBAUG\n-----END CERTIFICATE-----\n'


class ConnectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.vault = self.root / 'vault'
        self.data = self.vault / '.obsidian/plugins/obsidian-local-rest-api/data.json'
        self.data.parent.mkdir(parents=True)
        self.settings = {'apiKey': 'fake-key', 'port': 27124, 'bindingHost': '192.168.2.196',
                         'crypto': {'cert': LEAF, 'caCert': CA, 'privateKey': 'fake-private'}}
        self.save()

    def save(self):
        self.data.write_text(json.dumps(self.settings), encoding='utf-8-sig')

    def test_export_pins_leaf_and_keeps_private_key_out(self):
        output = self.root / 'device'
        safe_result = module.export(self.vault, output)
        config = json.loads((output / 'obsidian-connection.json').read_text(encoding='utf-8'))
        self.assertEqual(config['certificate_sha256'], hashlib.sha256(b'\x01\x02\x03').hexdigest())
        self.assertEqual(config['api_key'], 'fake-key')
        self.assertEqual(config['ca_file'], 'obsidian-ca.pem')
        self.assertEqual((output / config['ca_file']).read_text(), CA)
        self.assertNotIn('fake-key', json.dumps(safe_result))
        self.assertNotIn('fake-private', ''.join(p.read_text() for p in output.iterdir()))

    def test_existing_files_are_preserved(self):
        output = self.root / 'existing'
        output.mkdir()
        original = output / 'obsidian-ca.pem'
        original.write_text('user certificate')
        with self.assertRaises(ValueError):
            module.export(self.vault, output)
        self.assertEqual(original.read_text(), 'user certificate')
        self.assertFalse((output / 'obsidian-connection.json').exists())

    def test_repository_destination_refused_before_write(self):
        with self.assertRaises(ValueError):
            module.export(self.vault, ROOT / 'downloads')

    def test_disabled_or_not_enabled_receiver_does_not_create_files(self):
        self.settings['crypto'] = {}
        self.save()
        output = self.root / 'not-created'
        with self.assertRaises(ValueError):
            module.export(self.vault, output)
        self.assertFalse(output.exists())
        self.settings['crypto'] = {'cert': LEAF}
        self.settings['enableSecureServer'] = False
        self.save()
        with self.assertRaises(ValueError):
            module.export(self.vault, output)

    def test_cli_failure_does_not_echo_private_configuration(self):
        self.settings['apiKey'] = 'fake-key\nBAD'
        self.save()
        result = io.StringIO()
        with patch.object(sys, 'argv', ['obsidian_connection.py', '--vault', str(self.vault),
                                      '--output-directory', str(self.root / 'output')]), contextlib.redirect_stdout(result):
            self.assertEqual(module.main(), 1)
        self.assertNotIn('fake-key', result.getvalue())
        self.assertNotIn('fake-private', result.getvalue())


if __name__ == '__main__':
    unittest.main()
