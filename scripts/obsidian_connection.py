"""Export a device connection from an enabled Local REST API plugin.

Uses only Python's standard library. Credentials must be kept outside this
repository and copied separately from the public plugin installation archive.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import ssl
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]


def connection(vault: Path, host: str | None = None) -> tuple[dict, str]:
    data_path = vault / '.obsidian/plugins/obsidian-local-rest-api/data.json'
    if data_path.stat().st_size > 256 * 1024:
        raise ValueError('接收插件配置过大，未导出。')
    data = json.loads(data_path.read_text(encoding='utf-8-sig'))
    crypto = data.get('crypto') or {}
    cert = crypto.get('cert')
    ca = crypto.get('caCert') or cert
    if not isinstance(cert, str) or not isinstance(ca, str):
        raise ValueError('请先在 Obsidian 启用 Local REST API，生成接收证书。')
    for pem in (cert, ca):
        if pem.count('-----BEGIN CERTIFICATE-----') != 1:
            raise ValueError('接收证书格式无效，未导出。')
        ssl.PEM_cert_to_DER_cert(pem.strip())
    key = data.get('apiKey')
    if not isinstance(key, str) or not key or len(key) > 4096 or re.search(r'\s|[\x00-\x1f\x7f]', key):
        raise ValueError('接收密钥无效，未导出。')
    host = host or data.get('bindingHost')
    if (not isinstance(host, str) or not re.fullmatch(r'[A-Za-z0-9.-]{1,253}', host)
            or host in {'0.0.0.0', '127.0.0.1', 'localhost'}):
        raise ValueError('请用 --host 指定 Kindle 可以访问的电脑局域网地址。')
    port = data.get('port', 27124)
    if type(port) is not int or not 1 <= port <= 65535 or data.get('enableSecureServer') is False:
        raise ValueError('接收插件的 HTTPS 地址未启用或端口无效。')
    result = {
        'endpoint': f'https://{host}:{port}',
        'api_key': key,
        'certificate_sha256': hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.strip())).hexdigest(),
        'ca_file': 'obsidian-ca.pem',
        'folder': '阅读摘录/不亦阅乎',
    }
    return result, ca.strip() + '\n'


def export(vault: Path, output: Path, host: str | None = None) -> dict:
    output = output.resolve()
    if output.is_relative_to(REPOSITORY):
        raise ValueError('连接文件包含密钥，请选择源码仓库外的目录。')
    config, ca = connection(vault, host)
    targets = [output / 'obsidian-connection.json', output / 'obsidian-ca.pem']
    if any(target.exists() for target in targets):
        raise ValueError('目录已有连接文件，请选择新目录；原文件已保留。')
    output.mkdir(parents=True, exist_ok=True)
    contents = [json.dumps(config, ensure_ascii=False, indent=2) + '\n', ca]
    created = []
    try:
        for target, content in zip(targets, contents):
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            created.append(target)
            with os.fdopen(descriptor, 'w', encoding='utf-8', newline='\n') as stream:
                stream.write(content)
    except Exception:
        for target in created:
            target.unlink(missing_ok=True)
        raise
    return {'output_directory': str(output), 'endpoint': config['endpoint'], 'files': [p.name for p in targets]}


def main() -> int:
    parser = argparse.ArgumentParser(description='生成私有 Kindle Obsidian 连接文件，不显示密钥。')
    parser.add_argument('--vault', required=True, type=Path)
    parser.add_argument('--output-directory', required=True, type=Path)
    parser.add_argument('--host')
    args = parser.parse_args()
    try:
        result = export(args.vault, args.output_directory, args.host)
    except (OSError, ValueError, TypeError, AttributeError):
        # Never echo raw configuration, keys, or JSON parser excerpts.
        print('生成失败：请确认接收插件已启用、有 HTTPS 证书、电脑局域网地址有效，并选择源码仓库外的空目录。')
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
