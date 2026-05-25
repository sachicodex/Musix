import 'package:firebase_auth/firebase_auth.dart';

import 'firestore_user_data_service.dart';

class AuthService {
  AuthService({
    FirebaseAuth? firebaseAuth,
    FirestoreUserDataService? firestoreUserDataService,
  }) : _firebaseAuth = firebaseAuth ?? FirebaseAuth.instance,
       _firestoreUserDataService = firestoreUserDataService;

  final FirebaseAuth _firebaseAuth;
  final FirestoreUserDataService? _firestoreUserDataService;
  String? _pendingSuccessMessage;

  Stream<User?> get authStateChanges => _firebaseAuth.authStateChanges();

  User? get currentUser => _firebaseAuth.currentUser;

  String get currentUserEmail => currentUser?.email?.trim().isNotEmpty == true
      ? currentUser!.email!.trim()
      : 'No email address';

  String get currentUserDisplayName {
    final String? displayName = currentUser?.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }

    final String email = currentUser?.email?.trim() ?? '';
    if (email.isEmpty) {
      return 'Music Listener';
    }

    final String localPart = email.split('@').first.trim();
    final String cleaned = localPart.replaceAll(RegExp(r'[._-]+'), ' ').trim();
    if (cleaned.isEmpty) {
      return email;
    }

    return cleaned
        .split(RegExp(r'\s+'))
        .where((String word) => word.isNotEmpty)
        .map(_capitalize)
        .join(' ');
  }

  String get currentUserInitials {
    final List<String> words = currentUserDisplayName
        .split(RegExp(r'\s+'))
        .where((String word) => word.isNotEmpty)
        .toList(growable: false);

    if (words.isEmpty) {
      return 'MU';
    }

    if (words.length == 1) {
      final String word = words.first;
      return word.length >= 2
          ? word.substring(0, 2).toUpperCase()
          : word.toUpperCase();
    }

    return '${words.first[0]}${words.last[0]}'.toUpperCase();
  }

  String get currentUserShortUid {
    final String uid = currentUser?.uid ?? '';
    if (uid.isEmpty) {
      return 'Unavailable';
    }
    return uid.length <= 8 ? uid : uid.substring(0, 8).toUpperCase();
  }

  bool get isCurrentUserEmailVerified => currentUser?.emailVerified ?? false;

  Future<void> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    try {
      final UserCredential credential = await _firebaseAuth
          .createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final User? user = credential.user;
      final String trimmedName = name.trim();
      if (user != null && trimmedName.isNotEmpty) {
        await user.updateDisplayName(trimmedName);
        await user.reload();
      }
      await _syncProfileBestEffort(
        email: email.trim(),
        displayName: trimmedName,
      );
      _pendingSuccessMessage = 'Account created successfully.';
    } on FirebaseAuthException catch (error) {
      throw AuthException(_messageForFirebaseAuthError(error));
    } catch (_) {
      throw const AuthException(
        'Could not create your account right now. Please try again.',
      );
    }
  }

  Future<void> signIn({required String email, required String password}) async {
    try {
      await _firebaseAuth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      await _syncProfileBestEffort(
        email: email.trim(),
        displayName: _firebaseAuth.currentUser?.displayName,
      );
      _pendingSuccessMessage = 'Logged in successfully.';
    } on FirebaseAuthException catch (error) {
      throw AuthException(_messageForFirebaseAuthError(error));
    } catch (_) {
      throw const AuthException(
        'Could not log you in right now. Please try again.',
      );
    }
  }

  Future<void> signOut() async {
    try {
      _pendingSuccessMessage = 'Logged out successfully.';
      await _firebaseAuth.signOut();
    } on FirebaseAuthException catch (error) {
      _pendingSuccessMessage = null;
      throw AuthException(_messageForFirebaseAuthError(error));
    } catch (_) {
      _pendingSuccessMessage = null;
      throw const AuthException(
        'Could not log you out right now. Please try again.',
      );
    }
  }

  String? takePendingSuccessMessage() {
    final String? message = _pendingSuccessMessage;
    _pendingSuccessMessage = null;
    return message;
  }

  String _messageForFirebaseAuthError(FirebaseAuthException error) {
    switch (error.code) {
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'email-already-in-use':
        return 'That email address is already in use.';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters.';
      case 'wrong-password':
      case 'user-not-found':
      case 'invalid-credential':
        return 'Wrong email or password.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait and try again.';
      case 'network-request-failed':
        return 'Network error. Check your internet connection.';
      case 'operation-not-allowed':
        return 'Email and Password sign-in is not enabled in Firebase.';
      default:
        return error.message ?? 'Authentication failed. Please try again.';
    }
  }

  String _capitalize(String value) {
    if (value.isEmpty) {
      return value;
    }
    return '${value[0].toUpperCase()}${value.substring(1).toLowerCase()}';
  }

  Future<void> _syncProfileBestEffort({
    required String email,
    String? displayName,
  }) async {
    try {
      await _firestoreUserDataService?.syncCurrentUserProfile(
        email: email,
        displayName: displayName,
      );
    } catch (_) {}
  }
}

class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
