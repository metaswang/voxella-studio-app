#!/usr/bin/env python3
"""Prepare reusable local build dependencies without building or publishing."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys


class PrerequisiteError(RuntimeError):
    pass


def load_environment(root, config):
    selected = root / ('.env.prod' if config == 'release' and (root / '.env.prod').is_file() else '.env')
    if not selected.is_file():
        return dict(os.environ)
    # Match bundle.sh's shell configuration; capture all values without logging them.
    result = subprocess.run(
        ['bash', '-c', 'set -a; source "$1" >/dev/null || exit; env -0', 'build-config', str(selected)],
        capture_output=True, check=False,
    )
    if result.returncode:
        raise PrerequisiteError('Unable to load the selected local build environment.')
    return dict(item.decode().split('=', 1) for item in result.stdout.split(b'\0') if b'=' in item)


class BuildPrerequisites:
    def __init__(self, root, env, *, check_only=False):
        self.root = root
        self.env = dict(env)
        self.check_only = check_only

    def run(self, args, *, stream=False, timeout=45):
        try:
            return subprocess.run(
                args, env=self.env, stdin=subprocess.DEVNULL,
                capture_output=not stream, text=True, timeout=timeout, check=False,
            )
        except subprocess.TimeoutExpired:
            raise PrerequisiteError(f'{args[0]} timed out; existing credentials and caches were preserved.') from None

    def cached_profile(self):
        path = self.root / '.secrets/notary-profile.env'
        if path.is_file():
            for line in path.read_text().splitlines():
                if line.startswith('NOTARY_PROFILE='):
                    values = shlex.split(line.split('=', 1)[1])
                    if len(values) == 1:
                        return values[0]
        return None

    def save_profile(self, profile):
        path = self.root / '.secrets/notary-profile.env'
        content = f'NOTARY_PROFILE={shlex.quote(profile)}\n'
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if not path.exists() or path.read_text() != content:
            path.write_text(content)
        path.chmod(0o600)

    def ensure_notary(self):
        profile = self.env.get('NOTARY_PROFILE') or self.cached_profile()
        if not profile:
            plist = self.root / 'Sources/VoxstudioPro/Resources/Info.plist'
            with plist.open('rb') as stream:
                profile = f"{plistlib.load(stream)['CFBundleIdentifier']}.notary"

        def check():
            return self.run(['xcrun', 'notarytool', 'history', '--keychain-profile', profile, '--no-progress'])

        result = check()
        if result.returncode:
            message = (result.stdout + result.stderr).lower()
            recoverable = any(value in message for value in (
                'no keychain password item found', '401', 'unauthorized', 'invalid credentials',
            ))
            if not recoverable:
                raise PrerequisiteError('Notary service/Keychain access is unavailable; credentials were not changed. Retry after restoring access.')
            if self.check_only:
                raise PrerequisiteError('Notary profile needs recovery. Run this command without --check-only to reuse the configured API key.')
            # Select one complete configuration, never mix keys from different issuers.
            key_id = issuer = key_path = None
            for fields in (
                ('NOTARY_API_KEY_ID', 'NOTARY_API_ISSUER', 'NOTARY_API_KEY_PATH'),
                ('APP_STORE_CONNECT_API_KEY_ID', 'APP_STORE_CONNECT_API_ISSUER_ID', 'APP_STORE_CONNECT_API_PRIVATE_KEY_PATH'),
            ):
                configured_id, configured_issuer, configured_path = (self.env.get(field) for field in fields)
                if configured_id and configured_issuer:
                    key_id, issuer, key_path = configured_id, configured_issuer, configured_path
                    break
            if not key_path and key_id:
                key_path = str(self.root / '.secrets' / f'AuthKey_{key_id}.p8')
            if not all((key_id, issuer, key_path)):
                raise PrerequisiteError('Notary recovery needs a Team API key path, Key ID and Issuer ID in NOTARY_API_* or APP_STORE_CONNECT_API_*; alternatively store an app-specific-password profile once.')
            key = Path(key_path).expanduser()
            if not key.is_absolute():
                key = self.root / key
            if not key.is_file() or key.suffix != '.p8':
                raise PrerequisiteError('Configured notarization private key must be an existing .p8 file.')
            if key.is_relative_to(self.root):
                ignored = self.run(['git', '-C', str(self.root), 'check-ignore', '-q', str(key)])
                if ignored.returncode:
                    raise PrerequisiteError('The local notarization private key must be Git-ignored before recovery.')
            key.chmod(0o600)
            print('==> Restoring notary profile from the configured Team API key', flush=True)
            stored = self.run([
                'xcrun', 'notarytool', 'store-credentials', profile,
                '--key', str(key), '--key-id', key_id, '--issuer', issuer, '--validate',
            ])
            if stored.returncode:
                raise PrerequisiteError('Apple rejected the configured notarization credentials. Correct the existing API key configuration before notarizing.')
            if check().returncode:
                raise PrerequisiteError('Restored notary profile could not be verified; notarization has not started.')
        self.env['NOTARY_PROFILE'] = profile
        if not self.check_only:
            self.save_profile(profile)
        print('==> Notary Keychain profile verified', flush=True)

    def metal_ready(self):
        return self.run(['xcrun', '-sdk', 'macosx', 'metal', '-v']).returncode == 0

    def metal_cache(self):
        selected = self.run(['xcode-select', '--print-path'])
        version = self.run(['xcodebuild', '-version'])
        if selected.returncode or version.returncode:
            raise PrerequisiteError('Select a working Xcode before initializing the Metal compiler.')
        fingerprint = hashlib.sha256((selected.stdout + version.stdout).encode()).hexdigest()[:16]
        configured = self.env.get('METAL_TOOLCHAIN_CACHE_DIR')
        base = Path(configured).expanduser() if configured else self.root / '.build/toolchains/MetalToolchain'
        if not base.is_absolute():
            base = self.root / base
        return base / fingerprint

    def import_cached_metal(self, cache):
        # Only complete exports for this exact Xcode selection are candidates.
        exports = sorted(cache.glob('*.exportedBundle')) or sorted(cache.glob('*.dmg'))
        for export in exports:
            result = self.run(['xcodebuild', '-importComponent', 'MetalToolchain', '-importPath', str(export)], stream=True, timeout=120)
            if result.returncode == 0 and self.metal_ready():
                return True
        return False

    def ensure_metal(self):
        if self.metal_ready():
            print('==> Metal compiler ready; no component download needed', flush=True)
            return
        if self.check_only:
            raise PrerequisiteError('Selected Xcode needs Metal Toolchain initialization. Run this command without --check-only once.')
        cache = self.metal_cache()
        cache.mkdir(parents=True, exist_ok=True)
        if self.import_cached_metal(cache):
            print('==> Metal compiler restored from the local component cache', flush=True)
            return
        try:
            timeout = int(self.env.get('METAL_INSTALL_TIMEOUT_SECONDS', '1800'))
        except ValueError:
            raise PrerequisiteError('METAL_INSTALL_TIMEOUT_SECONDS must be a positive integer.') from None
        if timeout <= 0:
            raise PrerequisiteError('METAL_INSTALL_TIMEOUT_SECONDS must be a positive integer.')
        print('==> Initializing Metal Toolchain once for the selected Xcode; keeping an offline export', flush=True)
        downloaded = self.run([
            'xcodebuild', '-downloadComponent', 'MetalToolchain', '-exportPath', str(cache),
        ], stream=True, timeout=timeout)
        if downloaded.returncode:
            raise PrerequisiteError('Apple Metal component download failed; retry initialization after restoring download access.')
        if not self.metal_ready() and not self.import_cached_metal(cache):
            raise PrerequisiteError('Metal component command completed but the compiler is unavailable; initialize it in Xcode > Settings > Components.')
        print('==> Metal compiler initialized', flush=True)

    def prepare(self, mode, *, notary_only=False):
        if mode == 'dist':
            self.ensure_notary()
        if not notary_only:
            self.ensure_metal()
        if mode in ('sign', 'dist') and not self.env.get('DEVELOPER_ID_PROVISIONING_PROFILE'):
            profile = self.root / '.secrets/VoxStudio_Developer_ID.provisionprofile'
            if profile.is_file():
                self.env['DEVELOPER_ID_PROVISIONING_PROFILE'] = str(profile)

    def write_resolved_environment(self, destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        assignments = [
            f'{key}={shlex.quote(self.env[key])}'
            for key in ('NOTARY_PROFILE', 'DEVELOPER_ID_PROVISIONING_PROFILE') if self.env.get(key)
        ]
        destination.write_text('\n'.join(assignments) + '\n')
        destination.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', choices=('debug', 'release'), default='debug')
    parser.add_argument('--mode', choices=('dev', 'fast', 'sign', 'dist', 'mas'), default='sign')
    parser.add_argument('--check-only', action='store_true', help='Validate without downloads or credential writes.')
    parser.add_argument('--notary-only', action='store_true', help='Check/recover the dist profile without Metal initialization.')
    parser.add_argument('--environment-loaded', action='store_true', help='Caller has already loaded its build environment.')
    parser.add_argument('--resolved-env', type=Path, help='Write resolved non-secret settings for bundle.sh.')
    args = parser.parse_args()
    if args.notary_only and args.mode != 'dist':
        parser.error('--notary-only requires --mode dist')
    if args.check_only and args.resolved_env:
        parser.error('--check-only cannot write --resolved-env')
    root = Path(__file__).resolve().parents[1]
    try:
        env = dict(os.environ) if args.environment_loaded else load_environment(root, args.config)
        prerequisites = BuildPrerequisites(root, env, check_only=args.check_only)
        prerequisites.prepare(args.mode, notary_only=args.notary_only)
        if args.resolved_env:
            prerequisites.write_resolved_environment(args.resolved_env)
    except (PrerequisiteError, OSError, ValueError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
