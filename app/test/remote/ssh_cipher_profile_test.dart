import 'package:dartssh2/dartssh2.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

const _defaults = SSHAlgorithms();

void main() {
  test('the default preference leads with ciphers that have no GHASH multiply', () {
    final cipher = sshClientAlgorithms().cipher;
    expect(cipher.first, SSHCipherType.chacha20poly1305);
    expect(
      cipher.indexOf(SSHCipherType.aes256gcm),
      greaterThan(cipher.indexOf(SSHCipherType.aes128ctr)),
      reason: 'AES-GCM costs a bit-serial GF(2^128) multiply per block',
    );
  });

  test('reordering never narrows what a peer can negotiate', () {
    expect(sshClientAlgorithms().cipher.toSet(), _defaults.cipher.toSet());
    expect(sshClientAlgorithms().cipher.where((type) => type.name.endsWith('-cbc')), isEmpty);
  });

  test('kex, host key and MAC preferences stay at the library defaults', () {
    final ours = sshClientAlgorithms();
    expect(ours.kex, _defaults.kex);
    expect(ours.hostkey, _defaults.hostkey);
    expect(ours.mac, _defaults.mac);
  });

  test('the legacy profile reproduces the original order for A/B runs', () {
    expect(sshClientAlgorithms(profile: 'legacy').cipher, _defaults.cipher);
    expect(sshClientAlgorithms(profile: 'legacy').cipher.first, SSHCipherType.aes256gcm);
  });
}
