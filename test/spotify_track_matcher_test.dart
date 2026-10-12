import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/spotify_sync_service.dart';

void main() {
  group('SpotifyTrackMatcher', () {
    test('requires exact normalized title and compatible artist', () {
      expect(SpotifyTrackMatcher.isExactCompatible(title: 'Hello!', artist: 'Adele', candidateTitle: 'Hello', candidateArtists: ['Adele']), isTrue);
      expect(SpotifyTrackMatcher.isExactCompatible(title: 'Hello', artist: 'Adele', candidateTitle: 'Hello', candidateArtists: ['Lionel Richie']), isFalse);
      expect(SpotifyTrackMatcher.isExactCompatible(title: 'Hello', artist: 'Adele', candidateTitle: 'Hello (Live)', candidateArtists: ['Adele']), isFalse);
    });
  });
}
