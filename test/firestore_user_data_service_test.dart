import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musix/services/firestore_user_data_service.dart';

void main() {
  test('buildUserDocumentSeedData seeds only small profile metadata', () {
    final Map<String, dynamic> data =
        FirestoreUserDataService.buildUserDocumentSeedData(
          email: '  hello.sachinthalakshan@gmail.com  ',
          existingLikedSongs: <String>['song-a'],
          existingDislikedSongs: <String>['song-b'],
          existingUpdatedAt: Timestamp.now(),
        );

    expect(data['email'], 'hello.sachinthalakshan@gmail.com');
    expect(data['schemaVersion'], 2);
    expect(data.containsKey('updatedAt'), isFalse);
    expect(data.containsKey('likedSongs'), isFalse);
    expect(data.containsKey('dislikedSongs'), isFalse);
  });

  test('buildUserDocumentSeedData adds a revision for a new user document', () {
    final Map<String, dynamic> data =
        FirestoreUserDataService.buildUserDocumentSeedData(
          email: 'listener@example.com',
          existingLikedSongs: null,
          existingDislikedSongs: null,
        );

    expect(data['email'], 'listener@example.com');
    expect(data['schemaVersion'], 2);
    expect(data['updatedAt'], isA<FieldValue>());
    expect(data.containsKey('likedSongs'), isFalse);
    expect(data.containsKey('dislikedSongs'), isFalse);
  });

  test('buildUserDocumentSeedData does not repair legacy array fields', () {
    final Map<String, dynamic> data =
        FirestoreUserDataService.buildUserDocumentSeedData(
          email: 'listener@example.com',
          existingLikedSongs: const <String>['song-a'],
          existingDislikedSongs: 'invalid',
          existingUpdatedAt: Timestamp.now(),
        );

    expect(data.containsKey('likedSongs'), isFalse);
    expect(data.containsKey('dislikedSongs'), isFalse);
    expect(data.containsKey('updatedAt'), isFalse);
  });

  test(
    'buildSanitizedUserDocumentData keeps legacy arrays out of user doc',
    () {
      final Timestamp revision = Timestamp.now();
      final Map<String, dynamic> data =
          FirestoreUserDataService.buildSanitizedUserDocumentData(
            email: '  listener@example.com  ',
            existingLikedSongs: <dynamic>['song-a', 'song-a', ' ', 7],
            existingDislikedSongs: 'invalid',
            existingPreferenceProfile: <String, dynamic>{
              'artistKeys': <String>['artist-a'],
              'legacyKey': true,
            },
            existingUpdatedAt: revision,
          );

      expect(data['email'], 'listener@example.com');
      expect(data['schemaVersion'], 2);
      expect(data.containsKey('likedSongs'), isFalse);
      expect(data.containsKey('dislikedSongs'), isFalse);
      expect(data.containsKey('displayName'), isFalse);
      expect(
        data['preferenceProfile'],
        const CloudPreferenceProfile.empty().toMap(),
      );
      expect(data['updatedAt'], revision);
    },
  );

  test(
    'buildSanitizedUserDocumentData omits display name to match Firestore rules',
    () {
      final Map<String, dynamic> data =
          FirestoreUserDataService.buildSanitizedUserDocumentData(
            email: 'listener@example.com',
            displayName: 'Sachi',
            existingDisplayName: 'Legacy Name',
            existingLikedSongs: const <String>[],
            existingDislikedSongs: const <String>[],
            existingPreferenceProfile: const CloudPreferenceProfile.empty()
                .toMap(),
          );

      expect(data.containsKey('displayName'), isFalse);
    },
  );

  test('cloudDocumentIdForSongId creates safe stable ids for remote songs', () {
    final String id = FirestoreUserDataService.cloudDocumentIdForSongId(
      'url:https://example.com/music/song.mp3',
    );

    expect(id, isNot(contains('/')));
    expect(id, isNot(contains('=')));
    expect(
      id,
      FirestoreUserDataService.cloudDocumentIdForSongId(
        'url:https://example.com/music/song.mp3',
      ),
    );
  });

  test('FirestoreUserDataException detects permission denied failures', () {
    const FirestoreUserDataException permissionError =
        FirestoreUserDataException(
          'Permission denied. Check your Firestore security rules.',
        );
    const FirestoreUserDataException codedPermissionError =
        FirestoreUserDataException(
          'Cloud sync blocked.',
          code: 'permission-denied',
        );
    const FirestoreUserDataException otherError = FirestoreUserDataException(
      'Firestore is temporarily unavailable. Please try again.',
    );

    expect(permissionError.isPermissionDenied, isTrue);
    expect(codedPermissionError.isPermissionDenied, isTrue);
    expect(otherError.isPermissionDenied, isFalse);
  });
}
