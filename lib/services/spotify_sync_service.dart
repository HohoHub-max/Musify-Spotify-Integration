/*
 * Spotify account connection and incremental library synchronization.
 * Tokens are stored only in platform secure storage; non-secret metadata is
 * retained in the existing Hive settings box.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:musify/services/common_services.dart';
import 'package:musify/services/data_manager.dart';
import 'package:musify/services/playlists_manager.dart';
import 'package:musify/utilities/url_launcher.dart';

class SpotifyConfigurationException implements Exception {
  const SpotifyConfigurationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SpotifyApiException implements Exception {
  const SpotifyApiException(this.message, {this.retryAfter});
  final String message;
  final Duration? retryAfter;
  @override
  String toString() => message;
}

class SpotifySyncProgress {
  const SpotifySyncProgress({
    required this.processed,
    required this.total,
    required this.matched,
    required this.added,
    required this.alreadyPresent,
    required this.unmatched,
  });
  final int processed, total, matched, added, alreadyPresent, unmatched;
}

class SpotifySyncResult {
  const SpotifySyncResult({
    required this.matched,
    required this.added,
    required this.alreadyPresent,
    required this.unmatched,
  });
  final int matched, added, alreadyPresent, unmatched;
}

class SpotifyAccount {
  const SpotifyAccount({required this.id, required this.name});
  final String id, name;
}

class SpotifySyncService {
  SpotifySyncService._();
  static final instance = SpotifySyncService._();

  static const _redirectUri = 'musify://spotify/callback';
  static const _playlistName = 'lieblingsmusik';
  static const _tokenUrl = 'https://accounts.spotify.com/api/token';
  static const _apiBase = 'https://api.spotify.com/v1';
  static const _storage = FlutterSecureStorage();
  static const _clientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');
  static const _scopes = [
    'user-read-private',
    'playlist-read-private',
    'playlist-modify-private',
  ];

  final connection = ValueNotifier<SpotifyAccount?>(null);
  Completer<Uri>? _redirectCompleter;
  String? _expectedState;

  bool get isConnected => connection.value != null;

  Future<void> restore() async {
    final userId = await _storage.read(key: 'spotify_user_id');
    if (userId == null) return;
    try {
      final profile = await _request('GET', '/me');
      final account = SpotifyAccount(
        id: profile['id'] as String,
        name: (profile['display_name'] as String?) ?? profile['id'] as String,
      );
      if (account.id != userId) {
        await disconnect();
        return;
      }
      connection.value = account;
    } catch (_) {
      // Keep the secure refresh token for an offline retry, but do not claim a
      // connected account until it has been validated.
    }
  }

  Future<void> connect() async {
    if (_clientId.isEmpty) {
      throw const SpotifyConfigurationException(
        'Spotify is not configured. Start the app with SPOTIFY_CLIENT_ID.',
      );
    }
    if (_redirectCompleter != null) {
      throw const SpotifyApiException('Spotify authorization is already open.');
    }
    final verifier = _randomUrlSafe(64);
    final state = _randomUrlSafe(32);
    _expectedState = state;
    await _storage.write(key: 'spotify_pkce_verifier', value: verifier);
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');
    final uri = Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': _clientId,
      'response_type': 'code',
      'redirect_uri': _redirectUri,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
      'state': state,
      'scope': _scopes.join(' '),
    });
    _redirectCompleter = Completer<Uri>();
    await launchURL(uri);
    final redirect = await _redirectCompleter!.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () => throw const SpotifyApiException('Spotify authorization timed out.'),
    );
    try {
      await _finishAuthorization(redirect);
    } finally {
      _redirectCompleter = null;
      _expectedState = null;
      await _storage.delete(key: 'spotify_pkce_verifier');
    }
  }

  /// Called by the app's single deep-link entry point.
  void handleRedirect(Uri uri) {
    if (uri.scheme != 'musify' || uri.host != 'spotify' || uri.path != '/callback') return;
    final completer = _redirectCompleter;
    if (completer != null && !completer.isCompleted) completer.complete(uri);
  }

  Future<void> _finishAuthorization(Uri uri) async {
    if (uri.queryParameters['state'] != _expectedState) {
      throw const SpotifyApiException('Spotify authorization state did not match.');
    }
    if (uri.queryParameters.containsKey('error')) {
      throw SpotifyApiException('Spotify authorization was cancelled or denied.');
    }
    final code = uri.queryParameters['code'];
    final verifier = await _storage.read(key: 'spotify_pkce_verifier');
    if (code == null || verifier == null) {
      throw const SpotifyApiException('Spotify authorization response was incomplete.');
    }
    final response = await http.post(Uri.parse(_tokenUrl), body: {
      'client_id': _clientId,
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': _redirectUri,
      'code_verifier': verifier,
    });
    final body = _json(response);
    if (response.statusCode != 200) throw SpotifyApiException(_error(body));
    await _saveTokens(body);
    final profile = await _request('GET', '/me');
    final account = SpotifyAccount(
      id: profile['id'] as String,
      name: (profile['display_name'] as String?) ?? profile['id'] as String,
    );
    await _storage.write(key: 'spotify_user_id', value: account.id);
    await addOrUpdateData<String>('settings', 'spotify_account_id', account.id);
    connection.value = account;
  }

  Future<SpotifySyncResult> synchronize({ValueChanged<SpotifySyncProgress>? onProgress}) async {
    final account = connection.value;
    if (account == null) throw const SpotifyApiException('Spotify is not connected.');
    final playlistId = await _findOrCreatePlaylist(account.id);
    final existing = await _playlistTrackUris(playlistId);
    final songs = _librarySongs();
    final submitted = <String>{};
    var matched = 0, added = 0, already = 0, unmatched = 0, processed = 0;
    final additions = <String>[];
    for (final song in songs) {
      final uri = await _matchSong(song);
      processed++;
      if (uri == null) {
        unmatched++;
      } else if (!submitted.add(uri)) {
        already++;
      } else {
        matched++;
        if (existing.contains(uri)) {
          already++;
        } else {
          additions.add(uri);
        }
      }
      onProgress?.call(SpotifySyncProgress(processed: processed, total: songs.length, matched: matched, added: added, alreadyPresent: already, unmatched: unmatched));
    }
    for (var i = 0; i < additions.length; i += 100) {
      final batch = additions.skip(i).take(100).toList();
      await _request('POST', '/playlists/$playlistId/items', body: {'uris': batch});
      added += batch.length;
      onProgress?.call(SpotifySyncProgress(processed: processed, total: songs.length, matched: matched, added: added, alreadyPresent: already, unmatched: unmatched));
    }
    return SpotifySyncResult(matched: matched, added: added, alreadyPresent: already, unmatched: unmatched);
  }

  List<Map> _librarySongs() {
    final songs = <Map>[...userLikedSongsList.value.whereType<Map>()];
    for (final playlist in getUserCustomPlaylists()) {
      final list = playlist['list'];
      if (list is List) songs.addAll(list.whereType<Map>());
    }
    return songs.where((song) => _text(song['title']).isNotEmpty && _text(song['artist']).isNotEmpty).toList();
  }

  Future<String?> _matchSong(Map song) async {
    final title = _text(song['title']);
    final artist = _text(song['artist']);
    final response = await _request('GET', '/search', query: {
      'q': 'track:$title artist:$artist', 'type': 'track', 'limit': '5',
    });
    final items = ((response['tracks'] as Map?)?['items'] as List? ?? []).whereType<Map>();
    for (final item in items) {
      if (SpotifyTrackMatcher.isExactCompatible(
        title: title,
        artist: artist,
        candidateTitle: _text(item['name']),
        candidateArtists: (item['artists'] as List? ?? [])
            .whereType<Map>()
            .map((e) => _text(e['name'])),
      )) return item['uri'] as String?;
    }
    return null;
  }

  Future<String> _findOrCreatePlaylist(String userId) async {
    final savedUser = await getData('settings', 'spotify_playlist_account_id');
    final savedId = await getData('settings', 'spotify_playlist_id');
    if (savedUser == userId && savedId is String) {
      try {
        final found = await _request('GET', '/playlists/$savedId');
        if ((found['owner'] as Map?)?['id'] == userId) return savedId;
      } catch (_) {}
    }
    var offset = 0;
    while (true) {
      final page = await _request('GET', '/me/playlists', query: {'limit': '50', 'offset': '$offset'});
      final items = (page['items'] as List? ?? []).whereType<Map>();
      for (final item in items) {
        if (item['name'] == _playlistName && (item['owner'] as Map?)?['id'] == userId) {
          final id = item['id'] as String;
          await _rememberPlaylist(userId, id);
          return id;
        }
      }
      if (items.length < 50) break;
      offset += items.length;
    }
    final created = await _request('POST', '/me/playlists', body: {'name': _playlistName, 'public': false, 'description': 'Synced by Musify'});
    final id = created['id'] as String;
    await _rememberPlaylist(userId, id);
    return id;
  }

  Future<void> _rememberPlaylist(String accountId, String playlistId) async {
    await addOrUpdateData<String>('settings', 'spotify_playlist_account_id', accountId);
    await addOrUpdateData<String>('settings', 'spotify_playlist_id', playlistId);
  }

  Future<Set<String>> _playlistTrackUris(String playlistId) async {
    final uris = <String>{};
    var offset = 0;
    while (true) {
      final page = await _request('GET', '/playlists/$playlistId/items', query: {'limit': '100', 'offset': '$offset', 'fields': 'items(track(uri)),next'});
      final items = (page['items'] as List? ?? []).whereType<Map>();
      for (final item in items) {
        final uri = (item['track'] as Map?)?['uri'];
        if (uri is String) uris.add(uri);
      }
      if (page['next'] == null) break;
      offset += items.length;
    }
    return uris;
  }

  Future<Map<String, dynamic>> _request(String method, String path, {Map<String, String>? query, Object? body, bool retried = false}) async {
    var token = await _validAccessToken();
    Future<http.Response> send() {
      final uri = Uri.parse('$_apiBase$path').replace(queryParameters: query);
      return switch (method) {
        'GET' => http.get(uri, headers: {'Authorization': 'Bearer $token'}),
        'POST' => http.post(uri, headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'}, body: jsonEncode(body)),
        _ => throw UnsupportedError(method),
      };
    }
    var response = await send();
    if (response.statusCode == 401 && !retried) {
      await _refreshToken();
      return _request(method, path, query: query, body: body, retried: true);
    }
    if (response.statusCode == 429) {
      final seconds = int.tryParse(response.headers['retry-after'] ?? '') ?? 1;
      throw SpotifyApiException('Spotify is rate limiting requests. Please retry shortly.', retryAfter: Duration(seconds: seconds));
    }
    final decoded = _json(response);
    if (response.statusCode < 200 || response.statusCode >= 300) throw SpotifyApiException(_error(decoded));
    return decoded;
  }

  Future<String> _validAccessToken() async {
    final expires = int.tryParse(await _storage.read(key: 'spotify_expires_at') ?? '') ?? 0;
    if (DateTime.now().millisecondsSinceEpoch >= expires - 60000) await _refreshToken();
    final token = await _storage.read(key: 'spotify_access_token');
    if (token == null) throw const SpotifyApiException('Spotify credentials are missing.');
    return token;
  }

  Future<void> _refreshToken() async {
    final refresh = await _storage.read(key: 'spotify_refresh_token');
    if (refresh == null || _clientId.isEmpty) throw const SpotifyApiException('Spotify authorization expired. Please reconnect.');
    final response = await http.post(Uri.parse(_tokenUrl), body: {'client_id': _clientId, 'grant_type': 'refresh_token', 'refresh_token': refresh});
    final body = _json(response);
    if (response.statusCode != 200) throw SpotifyApiException('Spotify authorization expired. Please reconnect.');
    await _saveTokens(body, previousRefresh: refresh);
  }

  Future<void> _saveTokens(Map<String, dynamic> body, {String? previousRefresh}) async {
    await _storage.write(key: 'spotify_access_token', value: body['access_token'] as String);
    await _storage.write(key: 'spotify_refresh_token', value: (body['refresh_token'] as String?) ?? previousRefresh);
    final seconds = body['expires_in'] as int? ?? 3600;
    await _storage.write(key: 'spotify_expires_at', value: '${DateTime.now().millisecondsSinceEpoch + seconds * 1000}');
  }

  Future<void> disconnect() async {
    for (final key in ['spotify_access_token', 'spotify_refresh_token', 'spotify_expires_at', 'spotify_user_id', 'spotify_pkce_verifier']) {
      await _storage.delete(key: key);
    }
    await deleteData('settings', 'spotify_account_id');
    await deleteData('settings', 'spotify_playlist_account_id');
    await deleteData('settings', 'spotify_playlist_id');
    connection.value = null;
  }

  static Map<String, dynamic> _json(http.Response response) {
    if (response.body.isEmpty) return <String, dynamic>{};
    final value = jsonDecode(response.body);
    return value is Map<String, dynamic> ? value : <String, dynamic>{};
  }
  static String _error(Map<String, dynamic> body) => (body['error'] is Map ? (body['error'] as Map)['message'] : body['error'])?.toString() ?? 'Spotify request failed.';
  static String _text(dynamic value) => value?.toString().trim() ?? '';
  static String _normal(String value) => value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  static String _randomUrlSafe(int length) => base64Url.encode(List<int>.generate(length, (_) => Random.secure().nextInt(256))).replaceAll('=', '').substring(0, length);
}




/// Conservative, deterministic matcher kept independent of HTTP for testing.
class SpotifyTrackMatcher {
  static bool isExactCompatible({
    required String title,
    required String artist,
    required String candidateTitle,
    required Iterable<String> candidateArtists,
  }) {
    final requestedTitle = _normalize(title);
    final requestedArtist = _normalize(artist);
    return requestedTitle.isNotEmpty && requestedArtist.isNotEmpty &&
        requestedTitle == _normalize(candidateTitle) &&
        candidateArtists.map(_normalize).where((value) => value.isNotEmpty).any(
          (value) => value == requestedArtist || value.contains(requestedArtist) || requestedArtist.contains(value),
        );
  }

  static String _normalize(String value) => value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}
