import 'package:dartssh2/dartssh2.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

const _defaults = SSHAlgorithms();

void main() {
  test('the fast profile leads with AES-CTR instead of a per-block GHASH', () {
    final cipher = sshClientAlgorithms(profile: 'fast').cipher;
    expect(cipher.first, SSHCipherType.aes256ctr);
    expect(
      cipher.indexOf(SSHCipherType.aes256gcm),
      greaterThan(cipher.indexOf(SSHCipherType.aes128ctr)),
      reason: 'AES-GCM costs a bit-serial GF(2^128) multiply per block',
    );
  });

  test('ChaCha20 is never preferred over a cipher Terrapin cannot exploit', () {
    final cipher = sshClientAlgorithms(profile: 'fast').cipher;
    final chacha = cipher.indexOf(SSHCipherType.chacha20poly1305);
    for (final safe in <SSHCipherType>[
      SSHCipherType.aes256ctr,
      SSHCipherType.aes128ctr,
      SSHCipherType.aes256gcm,
      SSHCipherType.aes128gcm,
    ]) {
      expect(
        chacha,
        greaterThan(cipher.indexOf(safe)),
        reason: 'without strict KEX, prefix truncation works only on ChaCha20-Poly1305',
      );
    }
    expect(
      chacha,
      cipher.length - 1,
      reason: 'only a server offering nothing else should land on it',
    );
  });

  test('reordering never narrows what a peer can negotiate', () {
    final cipher = sshClientAlgorithms(profile: 'fast').cipher;
    expect(cipher.toSet(), _defaults.cipher.toSet());
    expect(cipher.where((type) => type.name.endsWith('-cbc')), isEmpty);
  });

  test('kex, host key and MAC preferences stay at the library defaults', () {
    final ours = sshClientAlgorithms(profile: 'fast');
    expect(ours.kex, _defaults.kex);
    expect(ours.hostkey, _defaults.hostkey);
    expect(ours.mac, _defaults.mac);
  });

  test('an unknown profile fails instead of silently picking one', () {
    expect(() => sshClientAlgorithms(profile: 'fats'), throwsArgumentError);
  });

  test('the legacy profile reproduces the original order for A/B runs', () {
    expect(sshClientAlgorithms(profile: 'legacy').cipher, _defaults.cipher);
    expect(sshClientAlgorithms(profile: 'legacy').cipher.first, SSHCipherType.aes256gcm);
  });
}
