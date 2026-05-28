import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';
import '../core/app_logger.dart';
import '../core/models.dart';

class FirestoreUserDataService {
  FirestoreUserDataService({
    FirebaseFirestore? firestore,
    FirebaseAuth? firebaseAuth,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _firebaseAuth = firebaseAuth ?? FirebaseAuth.instance;

  static const int _cloudSchemaVersion = 2;
  static const String _songPreferenceLiked = 'liked';
  static const String _songPreferenceDisliked = 'disliked';
  static const String _songPreferenceNone = 'none';
  static const int _nativeWriteBatchLimit = 450;
  static const int _nativeReadPageSize = 200;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _firebaseAuth;

  bool get supportsCloudSync => true;

  bool get _useRestApiOnWindows => !kIsWeb && Platform.isWindows;

  String? get currentUserId => _firebaseAuth.currentUser?.uid;

  @visibleForTesting
  static String cloudDocumentIdForSongId(String songId) {
    final String trimmed = songId.trim();
    if (trimmed.isEmpty) {
      return '_';
    }
    return base64Url.encode(utf8.encode(trimmed)).replaceAll('=', '');
  }

  @visibleForTesting
  static Map<String, dynamic> buildUserDocumentSeedData({
    required String email,
    String? displayName,
    Object? existingLikedSongs,
    Object? existingDislikedSongs,
    Object? existingUpdatedAt,
  }) {
    final Map<String, dynamic> data = <String, dynamic>{
      'email': email.trim(),
      'schemaVersion': _cloudSchemaVersion,
    };
    if (existingUpdatedAt == null) {
      data['updatedAt'] = FieldValue.serverTimestamp();
    }
    return data;
  }

  @visibleForTesting
  static Map<String, dynamic> buildSanitizedUserDocumentData({
    required String email,
    String? displayName,
    Object? existingLikedSongs,
    Object? existingDislikedSongs,
    Object? existingPreferenceProfile,
    Object? existingDisplayName,
    Object? existingUpdatedAt,
  }) {
    bool isValidPreferenceProfileMap(Object? value) {
      if (value is! Map<String, dynamic>) {
        return false;
      }
      const Set<String> allowedKeys = <String>{
        'profileVersion',
        'artistKeys',
        'genreKeys',
        'moodKeys',
        'languageKeys',
        'yearKeys',
        'prefersRecentYears',
        'completedListenCount',
        'artistScores',
        'genreScores',
        'moodScores',
        'languageScores',
        'languageConfidenceScores',
        'yearScores',
        'avoidedArtistScores',
        'avoidedGenreScores',
        'avoidedMoodScores',
        'avoidedLanguageScores',
        'avoidedYearScores',
        'recentArtistScores',
        'recentGenreScores',
        'recentMoodScores',
        'recentLanguageScores',
        'recentYearScores',
        'skipArtistScores',
        'skipGenreScores',
        'skipMoodScores',
        'skipLanguageScores',
        'skipYearScores',
        'energyScores',
        'sessionContextScores',
        'sourceWeights',
        'noveltyPreference',
        'popularityPreference',
        'repeatAffinity',
        'primaryLanguage',
        'secondaryLanguages',
        'preferredYearFloor',
      };
      final Set<String> keys = value.keys.toSet();
      if (keys.difference(allowedKeys).isNotEmpty) {
        return false;
      }

      bool isValidStringListValue(Object? listValue) {
        return listValue is List<dynamic> &&
            listValue.every((dynamic item) => item is String);
      }

      bool isValidScoreMapValue(Object? mapValue) {
        return mapValue is Map<String, dynamic> &&
            mapValue.values.every(
              (dynamic item) => item is num || item is String,
            );
      }

      return isValidStringListValue(value['artistKeys']) &&
          isValidStringListValue(value['genreKeys']) &&
          isValidStringListValue(value['moodKeys']) &&
          isValidStringListValue(value['languageKeys']) &&
          (value['profileVersion'] == null || value['profileVersion'] is num) &&
          (value['yearKeys'] == null ||
              isValidStringListValue(value['yearKeys'])) &&
          value['prefersRecentYears'] is bool &&
          (value['completedListenCount'] == null ||
              value['completedListenCount'] is num) &&
          (value['artistScores'] == null ||
              isValidScoreMapValue(value['artistScores'])) &&
          (value['genreScores'] == null ||
              isValidScoreMapValue(value['genreScores'])) &&
          (value['moodScores'] == null ||
              isValidScoreMapValue(value['moodScores'])) &&
          (value['languageScores'] == null ||
              isValidScoreMapValue(value['languageScores'])) &&
          (value['languageConfidenceScores'] == null ||
              isValidScoreMapValue(value['languageConfidenceScores'])) &&
          (value['yearScores'] == null ||
              isValidScoreMapValue(value['yearScores'])) &&
          (value['avoidedArtistScores'] == null ||
              isValidScoreMapValue(value['avoidedArtistScores'])) &&
          (value['avoidedGenreScores'] == null ||
              isValidScoreMapValue(value['avoidedGenreScores'])) &&
          (value['avoidedMoodScores'] == null ||
              isValidScoreMapValue(value['avoidedMoodScores'])) &&
          (value['avoidedLanguageScores'] == null ||
              isValidScoreMapValue(value['avoidedLanguageScores'])) &&
          (value['avoidedYearScores'] == null ||
              isValidScoreMapValue(value['avoidedYearScores'])) &&
          (value['recentArtistScores'] == null ||
              isValidScoreMapValue(value['recentArtistScores'])) &&
          (value['recentGenreScores'] == null ||
              isValidScoreMapValue(value['recentGenreScores'])) &&
          (value['recentMoodScores'] == null ||
              isValidScoreMapValue(value['recentMoodScores'])) &&
          (value['recentLanguageScores'] == null ||
              isValidScoreMapValue(value['recentLanguageScores'])) &&
          (value['recentYearScores'] == null ||
              isValidScoreMapValue(value['recentYearScores'])) &&
          (value['skipArtistScores'] == null ||
              isValidScoreMapValue(value['skipArtistScores'])) &&
          (value['skipGenreScores'] == null ||
              isValidScoreMapValue(value['skipGenreScores'])) &&
          (value['skipMoodScores'] == null ||
              isValidScoreMapValue(value['skipMoodScores'])) &&
          (value['skipLanguageScores'] == null ||
              isValidScoreMapValue(value['skipLanguageScores'])) &&
          (value['skipYearScores'] == null ||
              isValidScoreMapValue(value['skipYearScores'])) &&
          (value['energyScores'] == null ||
              isValidScoreMapValue(value['energyScores'])) &&
          (value['sessionContextScores'] == null ||
              isValidScoreMapValue(value['sessionContextScores'])) &&
          (value['sourceWeights'] == null ||
              isValidScoreMapValue(value['sourceWeights'])) &&
          (value['noveltyPreference'] == null ||
              value['noveltyPreference'] is num) &&
          (value['popularityPreference'] == null ||
              value['popularityPreference'] is num) &&
          (value['repeatAffinity'] == null ||
              value['repeatAffinity'] is num) &&
          (value['primaryLanguage'] == null ||
              value['primaryLanguage'] is String) &&
          (value['secondaryLanguages'] == null ||
              isValidStringListValue(value['secondaryLanguages'])) &&
          (value['preferredYearFloor'] == null ||
              value['preferredYearFloor'] is num);
    }

    final Object updatedAt = existingUpdatedAt is Timestamp
        ? existingUpdatedAt
        : FieldValue.serverTimestamp();
    return <String, dynamic>{
      'email': email.trim(),
      'schemaVersion': _cloudSchemaVersion,
      'preferenceProfile':
          isValidPreferenceProfileMap(existingPreferenceProfile)
          ? existingPreferenceProfile
          : const CloudPreferenceProfile.empty().toMap(),
      'updatedAt': updatedAt,
    };
  }

  Future<void> syncCurrentUserProfile({
    required String email,
    String? displayName,
  }) async {
    final User? user = _firebaseAuth.currentUser;
    if (user == null) {
      return;
    }

    if (_useRestApiOnWindows) {
      try {
        final Map<String, dynamic> fields = <String, dynamic>{
          'email': _stringField(email.trim()),
          'schemaVersion': _integerField(_cloudSchemaVersion),
          'updatedAt': _timestampField(DateTime.now().toUtc()),
        };
        await _setRestDocument(
          _userDocumentPath(user.uid),
          fields: fields,
          updateMaskFieldPaths: fields.keys.toList(growable: false),
        );
      } on FirestoreUserDataException {
        rethrow;
      } catch (_) {
        throw const FirestoreUserDataException(
          'Could not save your Firestore profile.',
        );
      }
      return;
    }

    try {
      await _userDocument(user.uid).set(<String, dynamic>{
        'email': email.trim(),
        'schemaVersion': _cloudSchemaVersion,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } on FirebaseException catch (error) {
      throw FirestoreUserDataException(_friendlyMessage(error));
    } catch (_) {
      throw const FirestoreUserDataException(
        'Could not save your Firestore profile.',
      );
    }
  }

  Stream<FirestoreUserData> watchCurrentUserData({
    Duration windowsPollInterval = const Duration(seconds: 3),
  }) async* {
    final User? user = _firebaseAuth.currentUser;
    if (user == null) {
      yield const FirestoreUserData.empty();
      return;
    }

    if (_useRestApiOnWindows) {
      AppLogger.info('Firestore', 'Watching user library with REST polling');
      yield await loadCurrentUserData();
      while (_firebaseAuth.currentUser?.uid == user.uid) {
        await Future<void>.delayed(windowsPollInterval);
        if (_firebaseAuth.currentUser?.uid != user.uid) {
          break;
        }
        yield await loadCurrentUserData();
      }
      return;
    }

    AppLogger.info(
      'Firestore',
      'Watching user library with snapshot listeners',
    );
    await ensureCurrentUserDocument();
    yield* _watchCurrentUserDataFirestore(user);
  }

  Future<void> ensureCurrentUserDocument() async {
    final User? user = _firebaseAuth.currentUser;
    if (user == null) {
      return;
    }

    if (_useRestApiOnWindows) {
      AppLogger.trace('Firestore', 'Ensuring current user document with REST');
      try {
        final _FirestoreRestUserDocument existing = await _loadUserDocumentRest(
          user,
        );
        if (existing.exists && existing.updatedAt != null) {
          return;
        }
        final Map<String, dynamic> fields = <String, dynamic>{
          'email': _stringField(user.email?.trim() ?? ''),
          'schemaVersion': _integerField(_cloudSchemaVersion),
        };
        if (!existing.exists || existing.updatedAt == null) {
          fields['updatedAt'] = _timestampField(DateTime.now().toUtc());
        }
        await _setRestDocument(
          _userDocumentPath(user.uid),
          fields: fields,
          updateMaskFieldPaths: fields.keys.toList(growable: false),
        );
      } on FirestoreUserDataException {
        rethrow;
      } catch (_) {
        throw const FirestoreUserDataException(
          'Could not prepare your Firestore profile.',
        );
      }
      return;
    }

    try {
      AppLogger.trace(
        'Firestore',
        'Ensuring current user document with native Firestore',
      );
      final DocumentReference<Map<String, dynamic>> userDoc = _userDocument(
        user.uid,
      );
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await userDoc
          .get();
      final Map<String, dynamic> existingData =
          snapshot.data() ?? <String, dynamic>{};

      await userDoc.set(
        buildSanitizedUserDocumentData(
          email: user.email?.trim() ?? '',
          displayName: user.displayName,
          existingLikedSongs: existingData['likedSongs'],
          existingDislikedSongs: existingData['dislikedSongs'],
          existingPreferenceProfile: existingData['preferenceProfile'],
          existingDisplayName: existingData['displayName'],
          existingUpdatedAt: existingData['updatedAt'],
        ),
      );
    } on FirebaseException catch (error) {
      throw FirestoreUserDataException(_friendlyMessage(error));
    } catch (_) {
      throw const FirestoreUserDataException(
        'Could not prepare your Firestore profile.',
      );
    }
  }

  Future<FirestoreUserData> loadCurrentUserData() async {
    final User? user = _firebaseAuth.currentUser;
    if (user == null) {
      return const FirestoreUserData.empty();
    }

    if (_useRestApiOnWindows) {
      try {
        AppLogger.info('Firestore', 'Loading user library with REST');
        final _FirestoreRestUserDocument userData = await _loadUserDocumentRest(
          user,
        );
        final _SongPreferenceIds preferenceIds =
            await _loadSongPreferenceIdsRest(user, userData);
        final List<UserPlaylist> playlists = await _loadPlaylistMetadataRest(
          user,
        );
        return FirestoreUserData(
          email: userData.email.trim(),
          likedSongIds: preferenceIds.likedSongIds,
          dislikedSongIds: preferenceIds.dislikedSongIds,
          preferenceProfile: userData.preferenceProfile,
          playlists: playlists,
          libraryRevision: userData.updatedAt,
        );
      } on FirestoreUserDataException {
        rethrow;
      } catch (_) {
        throw const FirestoreUserDataException(
          'Could not load your Firestore library.',
        );
      }
    }

    await ensureCurrentUserDocument();

    try {
      AppLogger.info('Firestore', 'Loading user library with native Firestore');
      final DocumentSnapshot<Map<String, dynamic>> userSnapshot =
          await _userDocument(user.uid).get();
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> playlistDocuments =
          await _loadPlaylistMetadataDocumentsFirestore(user);

      final Map<String, dynamic> userData =
          userSnapshot.data() ?? <String, dynamic>{};
      final _SongPreferenceIds preferenceIds =
          await _loadSongPreferenceIdsFirestore(user, userData);
      final List<UserPlaylist> playlists =
          playlistDocuments
              .map(_playlistMetadataFromSnapshot)
              .toList(growable: false)
            ..sort(_sortPlaylists);
      unawaited(
        _cleanupLegacyPlaylistSongIdsFirestore(
          playlistDocuments.where(_playlistDocumentHasLegacySongIds),
        ),
      );

      return FirestoreUserData(
        email: (userData['email'] as String? ?? user.email ?? '').trim(),
        likedSongIds: preferenceIds.likedSongIds,
        dislikedSongIds: preferenceIds.dislikedSongIds,
        preferenceProfile: _readPreferenceProfile(
          userData['preferenceProfile'],
        ),
        playlists: playlists,
        libraryRevision: _readNullableDateTime(userData['updatedAt']),
      );
    } on FirebaseException catch (error) {
      throw FirestoreUserDataException(_friendlyMessage(error));
    } catch (_) {
      throw const FirestoreUserDataException(
        'Could not load your Firestore library.',
      );
    }
  }

  Future<void> setLikedSong({
    required String songId,
    required bool isLiked,
  }) async {
    final User? user = _firebaseAuth.currentUser;
    if (user == null) {
      return;
    }

    if (_useRestApiOnWindows) {
      try {
        await ensureCurrentUserDocument();
        await _writeSongPreferenceRest(
          user: user,
          songId: songId,
          state: isLiked ? _songPreferenceLiked : _songPreferenceNone,
        );
        await _touchUserRevisionRest(user);
      } on FirestoreUserDataException {
        rethrow;
      } catch (_) {
        throw const FirestoreUserDataException(
          'Could not update liked songs in Firestore.',
        );
      }
      return;
    }

    await ensureCurrentUserDocument();

    try {
      final WriteBatch batch = _firestore.batch();
      final DocumentReference<Map<String, dynamic>> userDoc = _userDocument(
        user.uid,
      );
      final DocumentReference<Map<String, dynamic>> preferenceDoc =
          _songPreferenceDocument(user.uid, songId);

      batch.set(userDoc, <String, dynamic>{
        'email': user.email?.trim() ?? '',
        'schemaVersion': _cloudSchemaVersion,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      batch.set(preferenceDoc, <String, dynamic>{
        'songId': songId,
        'state': isLiked ? _songPreferenceLiked : _songPreferenceNone,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await batch.commit();
    } on FirebaseException catch (error) {
      throw FirestoreUserDataException(_friendlyMessage(error));
    } catch (_) {
      throw const FirestoreUserDataException(
        'Could not update liked songs in Firestore.',
      );
    }
  }

  Future<void> setDislikedSong({
    required String songId,
    required bool isDisliked,
  }) async {
    final User? user = _firebaseAuth.currentUser;
    if (user == null) {
      return;
    }

    if (_useRestApiOnWindows) {
      try {
        await ensureCurrentUserDocument();
        await _writeSongPreferenceRest(
          user: user,
          songId: songId,
          state: isDisliked ? _songPreferenceDisliked : _songPreferenceNone,
        );
        await _touchUserRevisionRest(user);
      } on FirestoreUserDataException {
        rethrow;
      } catch (_) {
        throw const FirestoreUserDataException(
          'Could not update disliked songs in Firestore.',
        );
      }
      return;
    }

    await ensureCurrentUserDocument();

    try {
      final WriteBatch batch = _firestore.batch();
      final DocumentReference<Map<String, dynamic>> userDoc = _userDocument(
        user.uid,
      );
      final DocumentReference<Map<String, dynamic>> preferenceDoc =
          _songPreferenceDocument(user.uid, songId);

      batch.set(userDoc, <String, dynamic>{
        'email': user.email?.trim() ?? '',
        'schemaVersion': _cloudSchemaVersion,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      batch.set(preferenceDoc, <String, dynamic>{
        'songId': songId,
        'state': isDisliked ? _songPreferenceDisliked : _songPreferenceNone,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await batch.commit();
    } on FirebaseException catch (error) {
      throw FirestoreUserDataException(_friendlyMessage(error));
    } catch (_) {
      throw const FirestoreUserDataException(
        'Could not update disliked songs in Firestore.',
      );
    }
  }

  Future<void> savePreferenceProfile({
    required CloudPreferenceProfile profile,
  }) async {
    final User? user = _firebaseAuth.currentUser;
    if (user == null) {
      return;
    }

    if (_useRestApiOnWindows) {
      try {
        await ensureCurrentUserDocument();
        await _setRestDocument(
          _userDocumentPath(user.uid),
          fields: <String, dynamic>{
            'email': _stringField(user.email?.trim() ?? ''),
            'schemaVersion': _integerField(_cloudSchemaVersion),
            'preferenceProfile': _profileField(profile),
            'updatedAt': _timestampField(DateTime.now().toUtc()),
          },
          updateMaskFieldPaths: const <String>[
            'email',
            'schemaVersion',
            'preferenceProfile',
            'updatedAt',
          ],
        );
      } on FirestoreUserDataException {
        rethrow;
      } catch (_) {
        throw const FirestoreUserDataException(
          'Could not update your recommendation profile in Firestore.',
        );
      }
      return;
    }

    await ensureCurrentUserDocument();

    try {
      await _userDocument(user.uid).set(<String, dynamic>{
        'email': user.email?.trim() ?? '',
        'schemaVersion': _cloudSchemaVersion,
        'preferenceProfile': profile.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } on FirebaseException catch (error) {
      throw FirestoreUserDataException(_friendlyMessage(error));
    } catch (_) {
      throw const FirestoreUserDataException(
        'Could not update your recommendation profile in Firestore.',
      );
    }
  }

  Future<void> upsertPlaylist(UserPlaylist playlist) async {
    final User? user = _firebaseAuth.currentUser;
    if (user == null) {
      return;
    }

    final UserPlaylist? remotePlaylist = await loadPlaylistMetadata(playlist.id);
    final DateTime? localRevision = playlist.lastSyncedAt;
    if (remotePlaylist != null &&
        localRevision != null &&
        remotePlaylist.updatedAt.isAfter(localRevision)) {
      throw const FirestoreUserDataException(
        'This playlist changed on another device before your edit was synced.',
        code: 'playlist-conflict',
      );
    }

    final List<String> sanitizedSongIds = playlist.songIds
        .map((String id) => id.trim())
        .where((String id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final int playlistSongCount = playlist.songIdsComplete
        ? sanitizedSongIds.length
        : playlist.displaySongCount;

    if (_useRestApiOnWindows) {
      try {
        await ensureCurrentUserDocument();
        await _setRestDocument(
          _playlistDocumentPath(user.uid, playlist.id),
          fields: <String, dynamic>{
            'name': _stringField(playlist.name.trim()),
            'schemaVersion': _integerField(_cloudSchemaVersion),
            'songCount': _integerField(playlistSongCount),
            'createdAt': _timestampField(playlist.createdAt),
            'updatedAt': _timestampField(playlist.updatedAt),
          },
          updateMaskFieldPaths: const <String>[
            'name',
            'schemaVersion',
            'songCount',
            'createdAt',
            'updatedAt',
          ],
        );
        if (playlist.songIdsComplete) {
          await _syncPlaylistSongsRest(
            user: user,
            playlistId: playlist.id,
            songIds: sanitizedSongIds,
          );
        }
        await _touchUserRevisionRest(user);
      } on FirestoreUserDataException {
        rethrow;
      } catch (_) {
        throw const FirestoreUserDataException(
          'Could not save the playlist to Firestore.',
        );
      }
      return;
    }

    await ensureCurrentUserDocument();

    try {
      final WriteBatch batch = _firestore.batch();
      batch.set(
        _playlistsCollection(user.uid).doc(playlist.id),
        <String, dynamic>{
          'name': playlist.name.trim(),
          'schemaVersion': _cloudSchemaVersion,
          'songCount': playlistSongCount,
          'createdAt': Timestamp.fromDate(playlist.createdAt),
          'updatedAt': Timestamp.fromDate(playlist.updatedAt),
        },
        SetOptions(merge: true),
      );
      batch.set(_userDocument(user.uid), <String, dynamic>{
        'email': user.email?.trim() ?? '',
        'schemaVersion': _cloudSchemaVersion,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await batch.commit();
      if (playlist.songIdsComplete) {
        await _syncPlaylistSongsFirestore(
          user: user,
          playlistId: playlist.id,
          songIds: sanitizedSongIds,
        );
      }
    } on FirebaseException catch (error) {
      throw FirestoreUserDataException(_friendlyMessage(error));
    } catch (_) {
      throw const FirestoreUserDataException(
        'Could not save the playlist to Firestore.',
      );
    }
  }

  Future<void> deletePlaylist(String playlistId) async {
    final User? user = _firebaseAuth.currentUser;
    if (user == null) {
      return;
    }

    if (_useRestApiOnWindows) {
      try {
        await ensureCurrentUserDocument();
        await _deletePlaylistSongsRest(user: user, playlistId: playlistId);
        await _deleteRestDocument(_playlistDocumentPath(user.uid, playlistId));
        await _touchUserRevisionRest(user);
      } on FirestoreUserDataException {
        rethrow;
      } catch (_) {
        throw const FirestoreUserDataException(
          'Could not delete the playlist from Firestore.',
        );
      }
      return;
    }

    await ensureCurrentUserDocument();

    try {
      await _deletePlaylistSongsFirestore(user: user, playlistId: playlistId);
      final WriteBatch batch = _firestore.batch();
      batch.delete(_playlistsCollection(user.uid).doc(playlistId));
      batch.set(_userDocument(user.uid), <String, dynamic>{
        'email': user.email?.trim() ?? '',
        'schemaVersion': _cloudSchemaVersion,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await batch.commit();
    } on FirebaseException catch (error) {
      throw FirestoreUserDataException(_friendlyMessage(error));
    } catch (_) {
      throw const FirestoreUserDataException(
        'Could not delete the playlist from Firestore.',
      );
    }
  }

  Future<UserPlaylist?> loadPlaylistMetadata(String playlistId) async {
    final User? user = _firebaseAuth.currentUser;
    if (user == null) {
      return null;
    }

    if (_useRestApiOnWindows) {
      try {
        final Map<String, dynamic>? document = await _getRestDocument(
          _playlistDocumentPath(user.uid, playlistId),
        );
        if (document == null) {
          return null;
        }
        return _playlistMetadataFromRestDocument(document);
      } on FirestoreUserDataException {
        rethrow;
      } catch (_) {
        throw const FirestoreUserDataException(
          'Could not load the playlist metadata from Firestore.',
        );
      }
    }

    try {
      final DocumentSnapshot<Map<String, dynamic>> snapshot =
          await _playlistsCollection(user.uid).doc(playlistId).get();
      if (!snapshot.exists) {
        return null;
      }
      return _playlistMetadataFromData(
        id: snapshot.id,
        data: snapshot.data() ?? <String, dynamic>{},
      );
    } on FirebaseException catch (error) {
      throw FirestoreUserDataException(_friendlyMessage(error));
    } catch (_) {
      throw const FirestoreUserDataException(
        'Could not load the playlist metadata from Firestore.',
      );
    }
  }

  Future<UserPlaylist?> loadPlaylistSongs(String playlistId) async {
    final User? user = _firebaseAuth.currentUser;
    if (user == null) {
      return null;
    }

    if (_useRestApiOnWindows) {
      try {
        final Map<String, dynamic>? document = await _getRestDocument(
          _playlistDocumentPath(user.uid, playlistId),
        );
        if (document == null) {
          return null;
        }
        return await _playlistWithSongsFromRestDocument(user, document);
      } on FirestoreUserDataException {
        rethrow;
      } catch (_) {
        throw const FirestoreUserDataException(
          'Could not load the playlist from Firestore.',
        );
      }
    }

    try {
      final DocumentSnapshot<Map<String, dynamic>> snapshot =
          await _playlistsCollection(user.uid).doc(playlistId).get();
      if (!snapshot.exists) {
        return null;
      }
      return await _playlistWithSongsFromSnapshot(user, snapshot);
    } on FirebaseException catch (error) {
      throw FirestoreUserDataException(_friendlyMessage(error));
    } catch (_) {
      throw const FirestoreUserDataException(
        'Could not load the playlist from Firestore.',
      );
    }
  }

  Future<_FirestoreRestUserDocument> _loadUserDocumentRest(User user) async {
    final Map<String, dynamic>? document = await _getRestDocument(
      _userDocumentPath(user.uid),
    );
    if (document == null) {
      return _FirestoreRestUserDocument(
        exists: false,
        email: user.email?.trim() ?? '',
        likedSongIds: <String>{},
        dislikedSongIds: <String>{},
        preferenceProfile: const CloudPreferenceProfile.empty(),
        updatedAt: null,
      );
    }
    final Map<String, dynamic> fields =
        (document['fields'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    return _FirestoreRestUserDocument(
      exists: true,
      email: _readRestStringField(fields['email']) ?? user.email?.trim() ?? '',
      likedSongIds: _readRestStringArrayField(fields['likedSongs']),
      dislikedSongIds: _readRestStringArrayField(fields['dislikedSongs']),
      preferenceProfile: _readRestPreferenceProfile(
        fields['preferenceProfile'],
      ),
      updatedAt: _readNullableRestDateTimeField(fields['updatedAt']),
    );
  }

  Future<List<UserPlaylist>> _loadPlaylistMetadataRest(User user) async {
    final List<Map<String, dynamic>> documents = await _listRestDocuments(
      _playlistsCollectionPath(user.uid),
    );
    final List<UserPlaylist> playlists =
        documents.map(_playlistMetadataFromRestDocument).toList(growable: false)
          ..sort(_sortPlaylists);
    return playlists;
  }

  Future<_SongPreferenceIds> _loadSongPreferenceIdsRest(
    User user,
    _FirestoreRestUserDocument userData,
  ) async {
    final _SongPreferenceIds result = _SongPreferenceIds(
      likedSongIds: Set<String>.from(userData.likedSongIds),
      dislikedSongIds: Set<String>.from(userData.dislikedSongIds),
    )..normalize();
    final List<Map<String, dynamic>> documents = await _listRestDocuments(
      _songPreferencesCollectionPath(user.uid),
    );
    for (final Map<String, dynamic> document in documents) {
      _applyRestSongPreferenceDocument(result, document);
    }
    return result..normalize();
  }

  Future<void> _writeSongPreferenceRest({
    required User user,
    required String songId,
    required String state,
  }) async {
    await _setRestDocument(
      _songPreferenceDocumentPath(user.uid, songId),
      fields: <String, dynamic>{
        'songId': _stringField(songId),
        'state': _stringField(state),
        'updatedAt': _timestampField(DateTime.now().toUtc()),
      },
      updateMaskFieldPaths: const <String>['songId', 'state', 'updatedAt'],
    );
  }

  Future<DateTime?> loadCurrentUserRevision() async {
    final User? user = _firebaseAuth.currentUser;
    if (user == null) {
      return null;
    }

    if (_useRestApiOnWindows) {
      AppLogger.trace('Firestore', 'Loading user library revision with REST');
      final _FirestoreRestUserDocument existing = await _loadUserDocumentRest(
        user,
      );
      if (existing.exists) {
        return existing.updatedAt;
      }
      await ensureCurrentUserDocument();
      final _FirestoreRestUserDocument created = await _loadUserDocumentRest(
        user,
      );
      return created.updatedAt;
    }

    await ensureCurrentUserDocument();
    try {
      AppLogger.trace(
        'Firestore',
        'Loading user library revision with native Firestore',
      );
      final DocumentSnapshot<Map<String, dynamic>> snapshot =
          await _userDocument(user.uid).get();
      final Map<String, dynamic> data = snapshot.data() ?? <String, dynamic>{};
      return _readNullableDateTime(data['updatedAt']);
    } on FirebaseException catch (error) {
      throw FirestoreUserDataException(_friendlyMessage(error));
    } catch (_) {
      throw const FirestoreUserDataException(
        'Could not load your Firestore library revision.',
      );
    }
  }

  Future<_SongPreferenceIds> _loadSongPreferenceIdsFirestore(
    User user,
    Map<String, dynamic> userData,
  ) async {
    final _SongPreferenceIds result = _SongPreferenceIds(
      likedSongIds: _readSongIds(userData['likedSongs']),
      dislikedSongIds: _readSongIds(userData['dislikedSongs']),
    )..normalize();
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents =
        await _getCollectionPagesFirestore(
          _songPreferencesCollection(user.uid).orderBy(FieldPath.documentId),
        );
    for (final QueryDocumentSnapshot<Map<String, dynamic>> document
        in documents) {
      _applySongPreferenceData(result, document.data());
    }
    return result..normalize();
  }

  Future<UserPlaylist> _playlistWithSongsFromSnapshot(
    User user,
    DocumentSnapshot<Map<String, dynamic>> snapshot,
  ) async {
    final Map<String, dynamic> data = snapshot.data() ?? <String, dynamic>{};
    final List<String> cloudSongIds = await _loadPlaylistSongIdsFirestore(
      user: user,
      playlistId: snapshot.id,
    );
    final List<String> legacySongIds = _readOrderedSongIds(data['songIds']);
    final List<String> songIds = cloudSongIds.isNotEmpty
        ? cloudSongIds
        : legacySongIds;
    return _playlistFromData(
      id: snapshot.id,
      data: data,
      songIds: songIds,
      songIdsComplete: true,
    );
  }

  Future<List<String>> _loadPlaylistSongIdsFirestore({
    required User user,
    required String playlistId,
  }) async {
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents =
        await _getCollectionPagesFirestore(
          _playlistSongsCollection(user.uid, playlistId).orderBy('position'),
        );
    return documents
        .map((QueryDocumentSnapshot<Map<String, dynamic>> document) {
          return (document.data()['songId'] as String? ?? '').trim();
        })
        .where((String id) => id.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> _syncPlaylistSongsFirestore({
    required User user,
    required String playlistId,
    required List<String> songIds,
  }) async {
    final CollectionReference<Map<String, dynamic>> collection =
        _playlistSongsCollection(user.uid, playlistId);
    final QuerySnapshot<Map<String, dynamic>> existingSnapshot =
        await collection.get();
    final Set<String> desiredSongIds = songIds.toSet();
    final List<DocumentReference<Map<String, dynamic>>> deleteRefs =
        <DocumentReference<Map<String, dynamic>>>[];

    for (final QueryDocumentSnapshot<Map<String, dynamic>> document
        in existingSnapshot.docs) {
      final String existingSongId = (document.data()['songId'] as String? ?? '')
          .trim();
      if (existingSongId.isEmpty || !desiredSongIds.contains(existingSongId)) {
        deleteRefs.add(document.reference);
      }
    }

    int operationCount = 0;
    WriteBatch batch = _firestore.batch();

    Future<void> commitIfFull() async {
      if (operationCount < _nativeWriteBatchLimit) {
        return;
      }
      await batch.commit();
      batch = _firestore.batch();
      operationCount = 0;
    }

    for (final DocumentReference<Map<String, dynamic>> ref in deleteRefs) {
      batch.delete(ref);
      operationCount += 1;
      await commitIfFull();
    }

    for (int index = 0; index < songIds.length; index++) {
      final String songId = songIds[index];
      final DocumentReference<Map<String, dynamic>> ref = collection.doc(
        cloudDocumentIdForSongId(songId),
      );
      batch.set(ref, <String, dynamic>{
        'songId': songId,
        'position': index,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      operationCount += 1;
      await commitIfFull();
    }

    if (operationCount > 0) {
      await batch.commit();
    }
  }

  Future<void> _deletePlaylistSongsFirestore({
    required User user,
    required String playlistId,
  }) async {
    final QuerySnapshot<Map<String, dynamic>> songsSnapshot =
        await _playlistSongsCollection(user.uid, playlistId).get();
    int operationCount = 0;
    WriteBatch batch = _firestore.batch();
    for (final QueryDocumentSnapshot<Map<String, dynamic>> document
        in songsSnapshot.docs) {
      batch.delete(document.reference);
      operationCount += 1;
      if (operationCount >= _nativeWriteBatchLimit) {
        await batch.commit();
        batch = _firestore.batch();
        operationCount = 0;
      }
    }
    if (operationCount > 0) {
      await batch.commit();
    }
  }

  Stream<FirestoreUserData> _watchCurrentUserDataFirestore(User user) {
    final StreamController<FirestoreUserData> controller =
        StreamController<FirestoreUserData>();
    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
    userSubscription;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
    playlistsSubscription;
    Map<String, dynamic> currentUserData = <String, dynamic>{};
    List<UserPlaylist> currentPlaylists = <UserPlaylist>[];
    bool hasUserSnapshot = false;
    bool hasPlaylistsSnapshot = false;

    void emitIfReady() {
      if (!hasUserSnapshot || !hasPlaylistsSnapshot || controller.isClosed) {
        return;
      }
      controller.add(
        FirestoreUserData(
          email: (currentUserData['email'] as String? ?? user.email ?? '')
              .trim(),
          likedSongIds: _readSongIds(currentUserData['likedSongs']),
          dislikedSongIds: _readSongIds(currentUserData['dislikedSongs']),
          preferenceProfile: _readPreferenceProfile(
            currentUserData['preferenceProfile'],
          ),
          playlists: currentPlaylists,
          libraryRevision: _readNullableDateTime(currentUserData['updatedAt']),
        ),
      );
    }

    FirestoreUserDataException toFirestoreException(Object error) {
      if (error is FirestoreUserDataException) {
        return error;
      }
      if (error is FirebaseException) {
        return FirestoreUserDataException(_friendlyMessage(error));
      }
      return const FirestoreUserDataException(
        'Could not load your Firestore library.',
      );
    }

    userSubscription = _userDocument(user.uid).snapshots().listen(
      (DocumentSnapshot<Map<String, dynamic>> snapshot) {
        currentUserData = snapshot.data() ?? <String, dynamic>{};
        hasUserSnapshot = true;
        emitIfReady();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!controller.isClosed) {
          controller.addError(toFirestoreException(error), stackTrace);
        }
      },
    );

    playlistsSubscription = _playlistsCollection(user.uid).snapshots().listen(
      (QuerySnapshot<Map<String, dynamic>> snapshot) {
        unawaited(
          _cleanupLegacyPlaylistSongIdsFirestore(
            snapshot.docs.where(_playlistDocumentHasLegacySongIds),
          ),
        );
        currentPlaylists =
            snapshot.docs
                .map(_playlistMetadataFromSnapshot)
                .toList(growable: false)
              ..sort(_sortPlaylists);
        hasPlaylistsSnapshot = true;
        emitIfReady();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!controller.isClosed) {
          controller.addError(toFirestoreException(error), stackTrace);
        }
      },
    );

    controller.onCancel = () async {
      await userSubscription?.cancel();
      await playlistsSubscription?.cancel();
    };

    return controller.stream;
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  _loadPlaylistMetadataDocumentsFirestore(User user) {
    return _getCollectionPagesFirestore(
      _playlistsCollection(user.uid).orderBy(FieldPath.documentId),
    );
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  _getCollectionPagesFirestore(
    Query<Map<String, dynamic>> baseQuery,
  ) async {
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents =
        <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    DocumentSnapshot<Map<String, dynamic>>? lastDocument;

    while (true) {
      Query<Map<String, dynamic>> pageQuery = baseQuery.limit(
        _nativeReadPageSize,
      );
      if (lastDocument != null) {
        pageQuery = pageQuery.startAfterDocument(lastDocument);
      }
      final QuerySnapshot<Map<String, dynamic>> snapshot = await pageQuery.get();
      if (snapshot.docs.isEmpty) {
        break;
      }
      documents.addAll(snapshot.docs);
      if (snapshot.docs.length < _nativeReadPageSize) {
        break;
      }
      lastDocument = snapshot.docs.last;
    }

    return documents;
  }

  bool _playlistDocumentHasLegacySongIds(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    return _readOrderedSongIds(document.data()['songIds']).isNotEmpty;
  }

  Future<void> _cleanupLegacyPlaylistSongIdsFirestore(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> documents,
  ) async {
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> staleDocuments =
        documents.toList(growable: false);
    if (staleDocuments.isEmpty) {
      return;
    }

    AppLogger.info(
      'Firestore',
      'Removing legacy playlist songIds from ${staleDocuments.length} docs',
    );

    int operationCount = 0;
    WriteBatch batch = _firestore.batch();

    Future<void> commitIfFull() async {
      if (operationCount < _nativeWriteBatchLimit) {
        return;
      }
      await batch.commit();
      batch = _firestore.batch();
      operationCount = 0;
    }

    for (final QueryDocumentSnapshot<Map<String, dynamic>> document
        in staleDocuments) {
      batch.update(document.reference, <String, dynamic>{
        'songIds': FieldValue.delete(),
      });
      operationCount += 1;
      await commitIfFull();
    }

    if (operationCount > 0) {
      await batch.commit();
    }
  }

  Future<Map<String, dynamic>?> _getRestDocument(String path) async {
    final _RestResponse response = await _sendRestRequest(
      'GET',
      _documentUri(path),
    );
    if (response.statusCode == HttpStatus.notFound) {
      return null;
    }
    _throwIfRestError(
      response,
      fallbackMessage: 'Could not load your Firestore library.',
    );
    final Object? decoded = jsonDecode(response.body);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  Future<List<Map<String, dynamic>>> _listRestDocuments(String path) async {
    final _RestResponse response = await _sendRestRequest(
      'GET',
      _documentUri(path),
    );
    if (response.statusCode == HttpStatus.notFound) {
      return <Map<String, dynamic>>[];
    }
    _throwIfRestError(
      response,
      fallbackMessage: 'Could not load your Firestore library.',
    );
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      return <Map<String, dynamic>>[];
    }
    final List<dynamic> rawDocuments =
        decoded['documents'] as List<dynamic>? ?? <dynamic>[];
    return rawDocuments.whereType<Map<String, dynamic>>().toList(
      growable: false,
    );
  }

  Future<void> _setRestDocument(
    String path, {
    required Map<String, dynamic> fields,
    List<String>? updateMaskFieldPaths,
  }) async {
    final _RestResponse response = await _sendRestRequest(
      'PATCH',
      _documentUri(path, updateMaskFieldPaths: updateMaskFieldPaths),
      body: jsonEncode(<String, dynamic>{'fields': fields}),
      contentType: 'application/json',
    );
    _throwIfRestError(
      response,
      fallbackMessage: 'Could not save the playlist to Firestore.',
    );
  }

  Future<void> _deleteRestDocument(String path) async {
    final _RestResponse response = await _sendRestRequest(
      'DELETE',
      _documentUri(path),
    );
    if (response.statusCode == HttpStatus.notFound) {
      return;
    }
    _throwIfRestError(
      response,
      fallbackMessage: 'Could not delete the playlist from Firestore.',
    );
  }

  Future<_RestResponse> _sendRestRequest(
    String method,
    Uri uri, {
    String? body,
    String? contentType,
  }) async {
    final User? user = _firebaseAuth.currentUser;
    final String? token = await user?.getIdToken();
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.openUrl(method, uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (contentType != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      if (body != null && body.isNotEmpty) {
        request.write(body);
      }
      final HttpClientResponse response = await request.close();
      final String responseBody = await utf8.decoder.bind(response).join();
      return _RestResponse(statusCode: response.statusCode, body: responseBody);
    } on SocketException {
      throw const FirestoreUserDataException(
        'Firestore is temporarily unavailable. Please try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  void _throwIfRestError(
    _RestResponse response, {
    required String fallbackMessage,
  }) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    final String? message = _extractRestErrorMessage(response.body);
    throw FirestoreUserDataException(message ?? fallbackMessage);
  }

  String? _extractRestErrorMessage(String body) {
    if (body.trim().isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final Map<String, dynamic>? error =
          decoded['error'] as Map<String, dynamic>?;
      if (error == null) {
        return null;
      }
      final String status = (error['status'] as String? ?? '').trim();
      final String message = (error['message'] as String? ?? '').trim();
      switch (status) {
        case 'PERMISSION_DENIED':
          return 'Permission denied. Check your Firestore security rules.';
        case 'UNAVAILABLE':
          return 'Firestore is temporarily unavailable. Please try again.';
        case 'NOT_FOUND':
          return 'Requested Firestore data was not found.';
        case 'FAILED_PRECONDITION':
          return 'Firestore setup is incomplete. Check indexes and rules.';
        default:
          return message.isEmpty ? null : message;
      }
    } catch (_) {
      return null;
    }
  }

  UserPlaylist _playlistMetadataFromRestDocument(
    Map<String, dynamic> document,
  ) {
    final String namePath = (document['name'] as String? ?? '').trim();
    final String id = namePath.isEmpty ? '' : namePath.split('/').last;
    final Map<String, dynamic> fields =
        (document['fields'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    return _playlistFromData(
      id: id,
      data: <String, dynamic>{
        'name': _readRestStringField(fields['name']),
        'songIds': _readRestStringArrayValues(fields['songIds']),
        'songCount': _readRestIntField(fields['songCount']),
        'createdAt': _readRestDateTimeField(fields['createdAt']),
        'updatedAt': _readRestDateTimeField(fields['updatedAt']),
      },
      songIds: const <String>[],
      songIdsComplete: false,
    );
  }

  Future<UserPlaylist> _playlistWithSongsFromRestDocument(
    User user,
    Map<String, dynamic> document,
  ) async {
    final String namePath = (document['name'] as String? ?? '').trim();
    final String id = namePath.isEmpty ? '' : namePath.split('/').last;
    final Map<String, dynamic> fields =
        (document['fields'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final List<String> cloudSongIds = await _loadPlaylistSongIdsRest(
      user: user,
      playlistId: id,
    );
    final List<String> legacySongIds = _readRestStringArrayValues(
      fields['songIds'],
    );
    return _playlistFromData(
      id: id,
      data: <String, dynamic>{
        'name': _readRestStringField(fields['name']),
        'songIds': legacySongIds,
        'songCount': _readRestIntField(fields['songCount']),
        'createdAt': _readRestDateTimeField(fields['createdAt']),
        'updatedAt': _readRestDateTimeField(fields['updatedAt']),
      },
      songIds: cloudSongIds.isNotEmpty ? cloudSongIds : legacySongIds,
      songIdsComplete: true,
    );
  }

  Future<List<String>> _loadPlaylistSongIdsRest({
    required User user,
    required String playlistId,
  }) async {
    final List<Map<String, dynamic>> documents = await _listRestDocuments(
      _playlistSongsCollectionPath(user.uid, playlistId),
    );
    final List<_RestPlaylistSong> songs = <_RestPlaylistSong>[];
    for (final Map<String, dynamic> document in documents) {
      final Map<String, dynamic> fields =
          (document['fields'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      final String songId = (_readRestStringField(fields['songId']) ?? '')
          .trim();
      if (songId.isEmpty) {
        continue;
      }
      songs.add(
        _RestPlaylistSong(
          songId: songId,
          position: _readRestIntField(fields['position']) ?? songs.length,
        ),
      );
    }
    songs.sort((_RestPlaylistSong a, _RestPlaylistSong b) {
      final int positionCompare = a.position.compareTo(b.position);
      if (positionCompare != 0) {
        return positionCompare;
      }
      return a.songId.compareTo(b.songId);
    });
    return songs
        .map((_RestPlaylistSong song) => song.songId)
        .toList(growable: false);
  }

  Future<void> _syncPlaylistSongsRest({
    required User user,
    required String playlistId,
    required List<String> songIds,
  }) async {
    final List<Map<String, dynamic>> existingDocuments =
        await _listRestDocuments(
          _playlistSongsCollectionPath(user.uid, playlistId),
        );
    final Set<String> desiredSongIds = songIds.toSet();
    for (final Map<String, dynamic> document in existingDocuments) {
      final Map<String, dynamic> fields =
          (document['fields'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      final String existingSongId =
          (_readRestStringField(fields['songId']) ?? '').trim();
      if (existingSongId.isEmpty || desiredSongIds.contains(existingSongId)) {
        continue;
      }
      final String namePath = (document['name'] as String? ?? '').trim();
      if (namePath.isNotEmpty) {
        await _deleteRestDocument(namePath.split('/documents/').last);
      }
    }

    for (int index = 0; index < songIds.length; index++) {
      final String songId = songIds[index];
      await _setRestDocument(
        _playlistSongDocumentPath(user.uid, playlistId, songId),
        fields: <String, dynamic>{
          'songId': _stringField(songId),
          'position': _integerField(index),
          'updatedAt': _timestampField(DateTime.now().toUtc()),
        },
        updateMaskFieldPaths: const <String>['songId', 'position', 'updatedAt'],
      );
    }
  }

  Future<void> _deletePlaylistSongsRest({
    required User user,
    required String playlistId,
  }) async {
    final List<Map<String, dynamic>> documents = await _listRestDocuments(
      _playlistSongsCollectionPath(user.uid, playlistId),
    );
    for (final Map<String, dynamic> document in documents) {
      final String namePath = (document['name'] as String? ?? '').trim();
      if (namePath.isEmpty) {
        continue;
      }
      await _deleteRestDocument(namePath.split('/documents/').last);
    }
  }

  String? _readRestStringField(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final Object? stringValue = value['stringValue'];
    if (stringValue is String) {
      return stringValue;
    }
    return null;
  }

  int? _readRestIntField(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final Object? integerValue = value['integerValue'];
    if (integerValue is int) {
      return integerValue;
    }
    if (integerValue is String) {
      return int.tryParse(integerValue);
    }
    return null;
  }

  Set<String> _readRestStringArrayField(Object? value) {
    return _readRestStringArrayValues(value).toSet();
  }

  List<String> _readRestStringArrayValues(Object? value) {
    if (value is! Map<String, dynamic>) {
      return const <String>[];
    }
    final Map<String, dynamic>? arrayValue =
        value['arrayValue'] as Map<String, dynamic>?;
    final List<dynamic> values =
        arrayValue?['values'] as List<dynamic>? ?? <dynamic>[];
    final List<String> result = <String>[];
    final Set<String> seen = <String>{};
    for (final Map<String, dynamic> item
        in values.whereType<Map<String, dynamic>>()) {
      final String normalized = (item['stringValue'] as String? ?? '').trim();
      if (normalized.isEmpty || !seen.add(normalized)) {
        continue;
      }
      result.add(normalized);
    }
    return result;
  }

  DateTime _readRestDateTimeField(Object? value) {
    if (value is! Map<String, dynamic>) {
      return DateTime.now();
    }
    final String raw =
        (value['timestampValue'] as String? ??
                value['stringValue'] as String? ??
                '')
            .trim();
    return DateTime.tryParse(raw)?.toLocal() ?? DateTime.now();
  }

  DateTime? _readNullableRestDateTimeField(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final String raw =
        (value['timestampValue'] as String? ??
                value['stringValue'] as String? ??
                '')
            .trim();
    return raw.isEmpty ? null : DateTime.tryParse(raw)?.toLocal();
  }

  Map<String, dynamic> _stringField(String value) {
    return <String, dynamic>{'stringValue': value};
  }

  Map<String, dynamic> _stringArrayField(List<String> values) {
    if (values.isEmpty) {
      return <String, dynamic>{'arrayValue': <String, dynamic>{}};
    }
    return <String, dynamic>{
      'arrayValue': <String, dynamic>{
        'values': values
            .map((String value) => <String, dynamic>{'stringValue': value})
            .toList(growable: false),
      },
    };
  }

  Map<String, dynamic> _boolField(bool value) {
    return <String, dynamic>{'booleanValue': value};
  }

  Map<String, dynamic> _doubleField(double value) {
    return <String, dynamic>{'doubleValue': value};
  }

  Map<String, dynamic> _integerField(int value) {
    return <String, dynamic>{'integerValue': value.toString()};
  }

  Map<String, dynamic> _scoreMapField(Map<String, double> values) {
    if (values.isEmpty) {
      return <String, dynamic>{'mapValue': <String, dynamic>{}};
    }
    final List<MapEntry<String, double>> sorted = values.entries.toList()
      ..sort(
        (MapEntry<String, double> a, MapEntry<String, double> b) =>
            b.value.compareTo(a.value),
      );
    return <String, dynamic>{
      'mapValue': <String, dynamic>{
        'fields': <String, dynamic>{
          for (final MapEntry<String, double> entry in sorted)
            entry.key: _doubleField(entry.value),
        },
      },
    };
  }

  Map<String, dynamic> _profileField(CloudPreferenceProfile profile) {
    return <String, dynamic>{
      'mapValue': <String, dynamic>{
        'fields': <String, dynamic>{
          'profileVersion': _integerField(profile.profileVersion),
          'artistKeys': _stringArrayField(
            profile.artistKeyOrder.isEmpty
                ? profile.artistKeys.toList(growable: false)
                : profile.artistKeyOrder,
          ),
          'genreKeys': _stringArrayField(
            profile.genreKeys.toList(growable: false),
          ),
          'moodKeys': _stringArrayField(
            profile.moodKeys.toList(growable: false),
          ),
          'languageKeys': _stringArrayField(
            profile.languageKeys.toList(growable: false),
          ),
          'yearKeys': _stringArrayField(
            profile.yearKeys.toList(growable: false),
          ),
          'prefersRecentYears': _boolField(profile.prefersRecentYears),
          'completedListenCount': _integerField(profile.completedListenCount),
          'artistScores': _scoreMapField(profile.artistScores),
          'genreScores': _scoreMapField(profile.genreScores),
          'moodScores': _scoreMapField(profile.moodScores),
          'languageScores': _scoreMapField(profile.languageScores),
          'languageConfidenceScores': _scoreMapField(
            profile.languageConfidenceScores,
          ),
          'yearScores': _scoreMapField(profile.yearScores),
          'avoidedArtistScores': _scoreMapField(profile.avoidedArtistScores),
          'avoidedGenreScores': _scoreMapField(profile.avoidedGenreScores),
          'avoidedMoodScores': _scoreMapField(profile.avoidedMoodScores),
          'avoidedLanguageScores': _scoreMapField(
            profile.avoidedLanguageScores,
          ),
          'avoidedYearScores': _scoreMapField(profile.avoidedYearScores),
          'recentArtistScores': _scoreMapField(profile.recentArtistScores),
          'recentGenreScores': _scoreMapField(profile.recentGenreScores),
          'recentMoodScores': _scoreMapField(profile.recentMoodScores),
          'recentLanguageScores': _scoreMapField(
            profile.recentLanguageScores,
          ),
          'recentYearScores': _scoreMapField(profile.recentYearScores),
          'skipArtistScores': _scoreMapField(profile.skipArtistScores),
          'skipGenreScores': _scoreMapField(profile.skipGenreScores),
          'skipMoodScores': _scoreMapField(profile.skipMoodScores),
          'skipLanguageScores': _scoreMapField(profile.skipLanguageScores),
          'skipYearScores': _scoreMapField(profile.skipYearScores),
          'energyScores': _scoreMapField(profile.energyScores),
          'sessionContextScores': _scoreMapField(
            profile.sessionContextScores,
          ),
          'sourceWeights': _scoreMapField(profile.sourceWeights),
          'noveltyPreference': _doubleField(profile.noveltyPreference),
          'popularityPreference': _doubleField(profile.popularityPreference),
          'repeatAffinity': _doubleField(profile.repeatAffinity),
          'primaryLanguage': _stringField(profile.primaryLanguage),
          'secondaryLanguages': _stringArrayField(
            profile.secondaryLanguages.toList(growable: false),
          ),
          if (profile.preferredYearFloor != null)
            'preferredYearFloor': _integerField(profile.preferredYearFloor!),
        },
      },
    };
  }

  Map<String, dynamic> _timestampField(DateTime value) {
    return <String, dynamic>{'timestampValue': value.toUtc().toIso8601String()};
  }

  Future<void> _touchUserRevisionRest(User user) {
    return _setRestDocument(
      _userDocumentPath(user.uid),
      fields: <String, dynamic>{
        'email': _stringField(user.email?.trim() ?? ''),
        'schemaVersion': _integerField(_cloudSchemaVersion),
        'updatedAt': _timestampField(DateTime.now().toUtc()),
      },
      updateMaskFieldPaths: const <String>[
        'email',
        'schemaVersion',
        'updatedAt',
      ],
    );
  }

  Uri _documentUri(String path, {List<String>? updateMaskFieldPaths}) {
    final FirebaseOptions options = DefaultFirebaseOptions.currentPlatform;
    final StringBuffer buffer = StringBuffer(
      'https://firestore.googleapis.com'
      '/v1/projects/${options.projectId}/databases/(default)/documents/$path',
    );
    if (updateMaskFieldPaths != null && updateMaskFieldPaths.isNotEmpty) {
      buffer.write('?');
      for (int index = 0; index < updateMaskFieldPaths.length; index++) {
        if (index > 0) {
          buffer.write('&');
        }
        buffer.write(
          'updateMask.fieldPaths='
          '${Uri.encodeQueryComponent(updateMaskFieldPaths[index])}',
        );
      }
    }
    return Uri.parse(buffer.toString());
  }

  String _userDocumentPath(String userId) => 'users/$userId';

  String _songPreferencesCollectionPath(String userId) =>
      'users/$userId/songPreferences';

  String _songPreferenceDocumentPath(String userId, String songId) =>
      'users/$userId/songPreferences/${cloudDocumentIdForSongId(songId)}';

  String _playlistsCollectionPath(String userId) => 'users/$userId/playlists';

  String _playlistDocumentPath(String userId, String playlistId) =>
      'users/$userId/playlists/$playlistId';

  String _playlistSongsCollectionPath(String userId, String playlistId) =>
      'users/$userId/playlists/$playlistId/songs';

  String _playlistSongDocumentPath(
    String userId,
    String playlistId,
    String songId,
  ) =>
      'users/$userId/playlists/$playlistId/songs/'
      '${cloudDocumentIdForSongId(songId)}';

  int _sortPlaylists(UserPlaylist a, UserPlaylist b) {
    final int updatedCompare = b.updatedAt.compareTo(a.updatedAt);
    if (updatedCompare != 0) {
      return updatedCompare;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  DocumentReference<Map<String, dynamic>> _userDocument(String userId) {
    return _firestore.collection('users').doc(userId);
  }

  CollectionReference<Map<String, dynamic>> _playlistsCollection(
    String userId,
  ) {
    return _userDocument(userId).collection('playlists');
  }

  CollectionReference<Map<String, dynamic>> _songPreferencesCollection(
    String userId,
  ) {
    return _userDocument(userId).collection('songPreferences');
  }

  DocumentReference<Map<String, dynamic>> _songPreferenceDocument(
    String userId,
    String songId,
  ) {
    return _songPreferencesCollection(
      userId,
    ).doc(cloudDocumentIdForSongId(songId));
  }

  CollectionReference<Map<String, dynamic>> _playlistSongsCollection(
    String userId,
    String playlistId,
  ) {
    return _playlistsCollection(userId).doc(playlistId).collection('songs');
  }

  Set<String> _readSongIds(Object? value) {
    return _readOrderedSongIds(value).toSet();
  }

  List<String> _readOrderedSongIds(Object? value) {
    if (value is! List<dynamic>) {
      return const <String>[];
    }

    final List<String> result = <String>[];
    final Set<String> seen = <String>{};
    for (final dynamic item in value) {
      final String id = item.toString().trim();
      if (id.isEmpty || !seen.add(id)) {
        continue;
      }
      result.add(id);
    }
    return result;
  }

  CloudPreferenceProfile _readPreferenceProfile(Object? value) {
    if (value is! Map<String, dynamic>) {
      return const CloudPreferenceProfile.empty();
    }
    return CloudPreferenceProfile.fromMap(value);
  }

  CloudPreferenceProfile _readRestPreferenceProfile(Object? value) {
    if (value is! Map<String, dynamic>) {
      return const CloudPreferenceProfile.empty();
    }
    final Map<String, dynamic> mapValue =
        value['mapValue'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final Map<String, dynamic> fields =
        mapValue['fields'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final List<String> artistKeyOrder = _readRestStringArrayValues(
      fields['artistKeys'],
    );
    return CloudPreferenceProfile(
      profileVersion: _readRestIntField(fields['profileVersion']) ?? 1,
      artistKeys: artistKeyOrder.toSet(),
      artistKeyOrder: artistKeyOrder,
      genreKeys: _readRestStringArrayField(fields['genreKeys']),
      moodKeys: _readRestStringArrayField(fields['moodKeys']),
      languageKeys: _readRestStringArrayField(fields['languageKeys']),
      yearKeys: _readRestStringArrayField(fields['yearKeys']),
      prefersRecentYears: _readRestBoolField(fields['prefersRecentYears']),
      completedListenCount:
          _readRestIntField(fields['completedListenCount']) ?? 0,
      artistScores: _readRestDoubleMapField(fields['artistScores']),
      genreScores: _readRestDoubleMapField(fields['genreScores']),
      moodScores: _readRestDoubleMapField(fields['moodScores']),
      languageScores: _readRestDoubleMapField(fields['languageScores']),
      languageConfidenceScores: _readRestDoubleMapField(
        fields['languageConfidenceScores'],
      ),
      yearScores: _readRestDoubleMapField(fields['yearScores']),
      avoidedArtistScores: _readRestDoubleMapField(
        fields['avoidedArtistScores'],
      ),
      avoidedGenreScores: _readRestDoubleMapField(fields['avoidedGenreScores']),
      avoidedMoodScores: _readRestDoubleMapField(fields['avoidedMoodScores']),
      avoidedLanguageScores: _readRestDoubleMapField(
        fields['avoidedLanguageScores'],
      ),
      avoidedYearScores: _readRestDoubleMapField(fields['avoidedYearScores']),
      recentArtistScores: _readRestDoubleMapField(fields['recentArtistScores']),
      recentGenreScores: _readRestDoubleMapField(fields['recentGenreScores']),
      recentMoodScores: _readRestDoubleMapField(fields['recentMoodScores']),
      recentLanguageScores: _readRestDoubleMapField(
        fields['recentLanguageScores'],
      ),
      recentYearScores: _readRestDoubleMapField(fields['recentYearScores']),
      skipArtistScores: _readRestDoubleMapField(fields['skipArtistScores']),
      skipGenreScores: _readRestDoubleMapField(fields['skipGenreScores']),
      skipMoodScores: _readRestDoubleMapField(fields['skipMoodScores']),
      skipLanguageScores: _readRestDoubleMapField(
        fields['skipLanguageScores'],
      ),
      skipYearScores: _readRestDoubleMapField(fields['skipYearScores']),
      energyScores: _readRestDoubleMapField(fields['energyScores']),
      sessionContextScores: _readRestDoubleMapField(
        fields['sessionContextScores'],
      ),
      sourceWeights: _readRestDoubleMapField(fields['sourceWeights']),
      noveltyPreference:
          _readRestDoubleField(fields['noveltyPreference']) ?? 0.5,
      popularityPreference:
          _readRestDoubleField(fields['popularityPreference']) ?? 0.5,
      repeatAffinity: _readRestDoubleField(fields['repeatAffinity']) ?? 0.5,
      primaryLanguage:
          _readRestStringField(fields['primaryLanguage']) ?? 'unknown',
      secondaryLanguages: _readRestStringArrayField(
        fields['secondaryLanguages'],
      ),
      preferredYearFloor: _readRestIntField(fields['preferredYearFloor']),
    );
  }

  Map<String, double> _readRestDoubleMapField(Object? value) {
    if (value is! Map<String, dynamic>) {
      return const <String, double>{};
    }
    final Map<String, dynamic> mapValue =
        value['mapValue'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final Map<String, dynamic> fields =
        mapValue['fields'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final Map<String, double> result = <String, double>{};
    for (final MapEntry<String, dynamic> entry in fields.entries) {
      final double? parsed = _readRestDoubleField(entry.value);
      final String key = entry.key.trim();
      if (key.isEmpty || parsed == null) {
        continue;
      }
      result[key] = parsed;
    }
    return result;
  }

  double? _readRestDoubleField(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final Object? raw =
        value['doubleValue'] ?? value['integerValue'] ?? value['stringValue'];
    if (raw is num) {
      return raw.toDouble();
    }
    if (raw is String) {
      return double.tryParse(raw);
    }
    return null;
  }

  bool _readRestBoolField(Object? value) {
    if (value is! Map<String, dynamic>) {
      return false;
    }
    final Object? raw = value['booleanValue'];
    return raw == true || raw == 'true';
  }

  void _applyRestSongPreferenceDocument(
    _SongPreferenceIds preferenceIds,
    Map<String, dynamic> document,
  ) {
    final Map<String, dynamic> fields =
        (document['fields'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    _applySongPreferenceData(preferenceIds, <String, dynamic>{
      'songId': _readRestStringField(fields['songId']),
      'state': _readRestStringField(fields['state']),
    });
  }

  void _applySongPreferenceData(
    _SongPreferenceIds preferenceIds,
    Map<String, dynamic> data,
  ) {
    final String songId = (data['songId'] as String? ?? '').trim();
    if (songId.isEmpty) {
      return;
    }
    final String state = (data['state'] as String? ?? '').trim();
    switch (state) {
      case _songPreferenceLiked:
        preferenceIds.dislikedSongIds.remove(songId);
        preferenceIds.likedSongIds.add(songId);
        break;
      case _songPreferenceDisliked:
        preferenceIds.likedSongIds.remove(songId);
        preferenceIds.dislikedSongIds.add(songId);
        break;
      case _songPreferenceNone:
        preferenceIds.likedSongIds.remove(songId);
        preferenceIds.dislikedSongIds.remove(songId);
        break;
    }
  }

  UserPlaylist _playlistMetadataFromSnapshot(
    QueryDocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    return _playlistMetadataFromData(id: snapshot.id, data: snapshot.data());
  }

  UserPlaylist _playlistMetadataFromData({
    required String id,
    required Map<String, dynamic> data,
  }) {
    return _playlistFromData(
      id: id,
      data: data,
      songIds: const <String>[],
      songIdsComplete: false,
    );
  }

  UserPlaylist _playlistFromData({
    required String id,
    required Map<String, dynamic> data,
    required List<String> songIds,
    required bool songIdsComplete,
  }) {
    final List<String> legacySongIds = _readOrderedSongIds(data['songIds']);
    final int songCount =
        _readInt(data['songCount']) ?? songIds.length + legacySongIds.length;
    return UserPlaylist(
      id: id,
      name: (data['name'] as String? ?? 'Untitled Playlist').trim(),
      songIds: songIds,
      songCount: songIdsComplete ? songIds.length : songCount,
      songIdsComplete: songIdsComplete,
      createdAt: _readDateTime(data['createdAt']),
      updatedAt: _readDateTime(data['updatedAt']),
      lastSyncedAt: _readNullableDateTime(data['updatedAt']),
    );
  }

  int? _readInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  DateTime _readDateTime(Object? value) {
    if (value is DateTime) {
      return value;
    }
    if (value is Timestamp) {
      return value.toDate();
    }
    if (value is String) {
      return DateTime.tryParse(value) ?? DateTime.now();
    }
    return DateTime.now();
  }

  DateTime? _readNullableDateTime(Object? value) {
    if (value is Timestamp) {
      return value.toDate();
    }
    if (value is String) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  String _friendlyMessage(FirebaseException error) {
    switch (error.code) {
      case 'permission-denied':
        return 'Permission denied. Check your Firestore security rules.';
      case 'unavailable':
        return 'Firestore is temporarily unavailable. Please try again.';
      case 'not-found':
        return 'Requested Firestore data was not found.';
      case 'failed-precondition':
        return 'Firestore setup is incomplete. Check indexes and rules.';
      default:
        return error.message ?? 'A Firestore error occurred.';
    }
  }
}

class FirestoreUserData {
  const FirestoreUserData({
    required this.email,
    required this.likedSongIds,
    required this.dislikedSongIds,
    required this.preferenceProfile,
    required this.playlists,
    required this.libraryRevision,
  });

  const FirestoreUserData.empty()
    : email = '',
      likedSongIds = const <String>{},
      dislikedSongIds = const <String>{},
      preferenceProfile = const CloudPreferenceProfile.empty(),
      playlists = const <UserPlaylist>[],
      libraryRevision = null;

  final String email;
  final Set<String> likedSongIds;
  final Set<String> dislikedSongIds;
  final CloudPreferenceProfile preferenceProfile;
  final List<UserPlaylist> playlists;
  final DateTime? libraryRevision;
}

class CloudPreferenceProfile {
  const CloudPreferenceProfile({
    required this.profileVersion,
    required this.artistKeys,
    required this.artistKeyOrder,
    required this.genreKeys,
    required this.moodKeys,
    required this.languageKeys,
    required this.yearKeys,
    required this.prefersRecentYears,
    required this.completedListenCount,
    required this.artistScores,
    required this.genreScores,
    required this.moodScores,
    required this.languageScores,
    required this.languageConfidenceScores,
    required this.yearScores,
    required this.avoidedArtistScores,
    required this.avoidedGenreScores,
    required this.avoidedMoodScores,
    required this.avoidedLanguageScores,
    required this.avoidedYearScores,
    required this.recentArtistScores,
    required this.recentGenreScores,
    required this.recentMoodScores,
    required this.recentLanguageScores,
    required this.recentYearScores,
    required this.skipArtistScores,
    required this.skipGenreScores,
    required this.skipMoodScores,
    required this.skipLanguageScores,
    required this.skipYearScores,
    required this.energyScores,
    required this.sessionContextScores,
    required this.sourceWeights,
    required this.noveltyPreference,
    required this.popularityPreference,
    required this.repeatAffinity,
    required this.primaryLanguage,
    required this.secondaryLanguages,
    required this.preferredYearFloor,
  });

  const CloudPreferenceProfile.empty()
    : profileVersion = 1,
      artistKeys = const <String>{},
      artistKeyOrder = const <String>[],
      genreKeys = const <String>{},
      moodKeys = const <String>{},
      languageKeys = const <String>{},
      yearKeys = const <String>{},
      prefersRecentYears = false,
      completedListenCount = 0,
      artistScores = const <String, double>{},
      genreScores = const <String, double>{},
      moodScores = const <String, double>{},
      languageScores = const <String, double>{},
      languageConfidenceScores = const <String, double>{},
      yearScores = const <String, double>{},
      avoidedArtistScores = const <String, double>{},
      avoidedGenreScores = const <String, double>{},
      avoidedMoodScores = const <String, double>{},
      avoidedLanguageScores = const <String, double>{},
      avoidedYearScores = const <String, double>{},
      recentArtistScores = const <String, double>{},
      recentGenreScores = const <String, double>{},
      recentMoodScores = const <String, double>{},
      recentLanguageScores = const <String, double>{},
      recentYearScores = const <String, double>{},
      skipArtistScores = const <String, double>{},
      skipGenreScores = const <String, double>{},
      skipMoodScores = const <String, double>{},
      skipLanguageScores = const <String, double>{},
      skipYearScores = const <String, double>{},
      energyScores = const <String, double>{},
      sessionContextScores = const <String, double>{},
      sourceWeights = const <String, double>{},
      noveltyPreference = 0.5,
      popularityPreference = 0.5,
      repeatAffinity = 0.5,
      primaryLanguage = 'unknown',
      secondaryLanguages = const <String>{},
      preferredYearFloor = null;

  final int profileVersion;
  final Set<String> artistKeys;
  final List<String> artistKeyOrder;
  final Set<String> genreKeys;
  final Set<String> moodKeys;
  final Set<String> languageKeys;
  final Set<String> yearKeys;
  final bool prefersRecentYears;
  final int completedListenCount;
  final Map<String, double> artistScores;
  final Map<String, double> genreScores;
  final Map<String, double> moodScores;
  final Map<String, double> languageScores;
  final Map<String, double> languageConfidenceScores;
  final Map<String, double> yearScores;
  final Map<String, double> avoidedArtistScores;
  final Map<String, double> avoidedGenreScores;
  final Map<String, double> avoidedMoodScores;
  final Map<String, double> avoidedLanguageScores;
  final Map<String, double> avoidedYearScores;
  final Map<String, double> recentArtistScores;
  final Map<String, double> recentGenreScores;
  final Map<String, double> recentMoodScores;
  final Map<String, double> recentLanguageScores;
  final Map<String, double> recentYearScores;
  final Map<String, double> skipArtistScores;
  final Map<String, double> skipGenreScores;
  final Map<String, double> skipMoodScores;
  final Map<String, double> skipLanguageScores;
  final Map<String, double> skipYearScores;
  final Map<String, double> energyScores;
  final Map<String, double> sessionContextScores;
  final Map<String, double> sourceWeights;
  final double noveltyPreference;
  final double popularityPreference;
  final double repeatAffinity;
  final String primaryLanguage;
  final Set<String> secondaryLanguages;
  final int? preferredYearFloor;

  bool get isEmpty =>
      artistKeys.isEmpty &&
      genreKeys.isEmpty &&
      moodKeys.isEmpty &&
      languageKeys.isEmpty &&
      yearKeys.isEmpty &&
      artistScores.isEmpty &&
      genreScores.isEmpty &&
      moodScores.isEmpty &&
      languageScores.isEmpty &&
      languageConfidenceScores.isEmpty &&
      yearScores.isEmpty &&
      avoidedArtistScores.isEmpty &&
      avoidedGenreScores.isEmpty &&
      avoidedMoodScores.isEmpty &&
      avoidedLanguageScores.isEmpty &&
      avoidedYearScores.isEmpty &&
      recentArtistScores.isEmpty &&
      recentGenreScores.isEmpty &&
      recentMoodScores.isEmpty &&
      recentLanguageScores.isEmpty &&
      recentYearScores.isEmpty &&
      skipArtistScores.isEmpty &&
      skipGenreScores.isEmpty &&
      skipMoodScores.isEmpty &&
      skipLanguageScores.isEmpty &&
      skipYearScores.isEmpty &&
      energyScores.isEmpty &&
      sessionContextScores.isEmpty &&
      sourceWeights.isEmpty &&
      noveltyPreference == 0.5 &&
      popularityPreference == 0.5 &&
      repeatAffinity == 0.5 &&
      primaryLanguage == 'unknown' &&
      secondaryLanguages.isEmpty &&
      preferredYearFloor == null &&
      completedListenCount == 0 &&
      !prefersRecentYears;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'profileVersion': profileVersion,
      'artistKeys':
          (artistKeyOrder.isEmpty
                  ? artistKeys.toList(growable: false)
                  : artistKeyOrder)
              .toList(growable: false),
      'genreKeys': genreKeys.toList(growable: false),
      'moodKeys': moodKeys.toList(growable: false),
      'languageKeys': languageKeys.toList(growable: false),
      'yearKeys': yearKeys.toList(growable: false),
      'prefersRecentYears': prefersRecentYears,
      'completedListenCount': completedListenCount,
      'artistScores': artistScores,
      'genreScores': genreScores,
      'moodScores': moodScores,
      'languageScores': languageScores,
      'languageConfidenceScores': languageConfidenceScores,
      'yearScores': yearScores,
      'avoidedArtistScores': avoidedArtistScores,
      'avoidedGenreScores': avoidedGenreScores,
      'avoidedMoodScores': avoidedMoodScores,
      'avoidedLanguageScores': avoidedLanguageScores,
      'avoidedYearScores': avoidedYearScores,
      'recentArtistScores': recentArtistScores,
      'recentGenreScores': recentGenreScores,
      'recentMoodScores': recentMoodScores,
      'recentLanguageScores': recentLanguageScores,
      'recentYearScores': recentYearScores,
      'skipArtistScores': skipArtistScores,
      'skipGenreScores': skipGenreScores,
      'skipMoodScores': skipMoodScores,
      'skipLanguageScores': skipLanguageScores,
      'skipYearScores': skipYearScores,
      'energyScores': energyScores,
      'sessionContextScores': sessionContextScores,
      'sourceWeights': sourceWeights,
      'noveltyPreference': noveltyPreference,
      'popularityPreference': popularityPreference,
      'repeatAffinity': repeatAffinity,
      'primaryLanguage': primaryLanguage,
      'secondaryLanguages': secondaryLanguages.toList(growable: false),
      if (preferredYearFloor != null) 'preferredYearFloor': preferredYearFloor,
    };
  }

  factory CloudPreferenceProfile.fromMap(Map<String, dynamic> map) {
    Set<String> readSet(Object? value) {
      if (value is! List<dynamic>) {
        return <String>{};
      }
      return value
          .map((dynamic item) => item.toString().trim())
          .where((String item) => item.isNotEmpty)
          .toSet();
    }

    List<String> readOrderedList(Object? value) {
      if (value is! List<dynamic>) {
        return const <String>[];
      }
      final List<String> result = <String>[];
      final Set<String> seen = <String>{};
      for (final dynamic item in value) {
        final String normalized = item.toString().trim();
        if (normalized.isEmpty || !seen.add(normalized)) {
          continue;
        }
        result.add(normalized);
      }
      return result;
    }

    Map<String, double> readScoreMap(Object? value) {
      if (value is! Map<dynamic, dynamic>) {
        return const <String, double>{};
      }
      final Map<String, double> result = <String, double>{};
      for (final MapEntry<dynamic, dynamic> entry in value.entries) {
        final String key = entry.key.toString().trim();
        final Object? rawValue = entry.value;
        final double? parsed = switch (rawValue) {
          num number => number.toDouble(),
          String text => double.tryParse(text),
          _ => null,
        };
        if (key.isEmpty || parsed == null) {
          continue;
        }
        result[key] = parsed;
      }
      return result;
    }

    final List<String> artistKeyOrder = readOrderedList(map['artistKeys']);

    return CloudPreferenceProfile(
      profileVersion: switch (map['profileVersion']) {
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 1,
        _ => 1,
      },
      artistKeys: artistKeyOrder.toSet(),
      artistKeyOrder: artistKeyOrder,
      genreKeys: readSet(map['genreKeys']),
      moodKeys: readSet(map['moodKeys']),
      languageKeys: readSet(map['languageKeys']),
      yearKeys: readSet(map['yearKeys']),
      prefersRecentYears: map['prefersRecentYears'] == true,
      completedListenCount: switch (map['completedListenCount']) {
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 0,
        _ => 0,
      },
      artistScores: readScoreMap(map['artistScores']),
      genreScores: readScoreMap(map['genreScores']),
      moodScores: readScoreMap(map['moodScores']),
      languageScores: readScoreMap(map['languageScores']),
      languageConfidenceScores: readScoreMap(map['languageConfidenceScores']),
      yearScores: readScoreMap(map['yearScores']),
      avoidedArtistScores: readScoreMap(map['avoidedArtistScores']),
      avoidedGenreScores: readScoreMap(map['avoidedGenreScores']),
      avoidedMoodScores: readScoreMap(map['avoidedMoodScores']),
      avoidedLanguageScores: readScoreMap(map['avoidedLanguageScores']),
      avoidedYearScores: readScoreMap(map['avoidedYearScores']),
      recentArtistScores: readScoreMap(map['recentArtistScores']),
      recentGenreScores: readScoreMap(map['recentGenreScores']),
      recentMoodScores: readScoreMap(map['recentMoodScores']),
      recentLanguageScores: readScoreMap(map['recentLanguageScores']),
      recentYearScores: readScoreMap(map['recentYearScores']),
      skipArtistScores: readScoreMap(map['skipArtistScores']),
      skipGenreScores: readScoreMap(map['skipGenreScores']),
      skipMoodScores: readScoreMap(map['skipMoodScores']),
      skipLanguageScores: readScoreMap(map['skipLanguageScores']),
      skipYearScores: readScoreMap(map['skipYearScores']),
      energyScores: readScoreMap(map['energyScores']),
      sessionContextScores: readScoreMap(map['sessionContextScores']),
      sourceWeights: readScoreMap(map['sourceWeights']),
      noveltyPreference: switch (map['noveltyPreference']) {
        num value => value.toDouble(),
        String value => double.tryParse(value) ?? 0.5,
        _ => 0.5,
      },
      popularityPreference: switch (map['popularityPreference']) {
        num value => value.toDouble(),
        String value => double.tryParse(value) ?? 0.5,
        _ => 0.5,
      },
      repeatAffinity: switch (map['repeatAffinity']) {
        num value => value.toDouble(),
        String value => double.tryParse(value) ?? 0.5,
        _ => 0.5,
      },
      primaryLanguage: (map['primaryLanguage'] as String? ?? 'unknown').trim(),
      secondaryLanguages: readSet(map['secondaryLanguages']),
      preferredYearFloor: switch (map['preferredYearFloor']) {
        num value => value.toInt(),
        String value => int.tryParse(value),
        _ => null,
      },
    );
  }
}

class FirestoreUserDataException implements Exception {
  const FirestoreUserDataException(this.message, {this.code});

  final String message;
  final String? code;

  bool get isPermissionDenied =>
      (code ?? '').toLowerCase() == 'permission-denied' ||
      message.toLowerCase().startsWith('permission denied');

  @override
  String toString() => message;
}

class _FirestoreRestUserDocument {
  const _FirestoreRestUserDocument({
    required this.exists,
    required this.email,
    required this.likedSongIds,
    required this.dislikedSongIds,
    required this.preferenceProfile,
    required this.updatedAt,
  });

  final bool exists;
  final String email;
  final Set<String> likedSongIds;
  final Set<String> dislikedSongIds;
  final CloudPreferenceProfile preferenceProfile;
  final DateTime? updatedAt;
}

class _SongPreferenceIds {
  _SongPreferenceIds({
    required this.likedSongIds,
    required this.dislikedSongIds,
  });

  final Set<String> likedSongIds;
  final Set<String> dislikedSongIds;

  void normalize() {
    likedSongIds.removeAll(dislikedSongIds);
  }
}

class _RestPlaylistSong {
  const _RestPlaylistSong({required this.songId, required this.position});

  final String songId;
  final int position;
}

class _RestResponse {
  const _RestResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}
