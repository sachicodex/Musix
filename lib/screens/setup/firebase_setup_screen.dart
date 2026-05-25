import 'package:flutter/material.dart';

import '../../core/colors.dart';
import '../../core/theme.dart';

class FirebaseSetupScreen extends StatelessWidget {
  const FirebaseSetupScreen({super.key, this.errorMessage});

  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: musixPageDecoration(),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: musixPanelDecoration(
                    color: MusixColors.surfaceRaised,
                    borderColor: MusixColors.surfaceOutlineStrong,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(
                        Icons.settings_applications_rounded,
                        size: 52,
                        color: MusixColors.accentStrong,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Firebase Setup Required',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: MusixColors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'This auth flow is ready, but Firebase is not connected to this app yet.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: MusixColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '1. Create a Firebase project.\n'
                        '2. Enable Email/Password sign-in.\n'
                        '3. Run "flutterfire configure".\n'
                        '4. Add the generated Firebase files to this project.\n'
                        '5. Run the app again.',
                        style: TextStyle(color: Colors.white, height: 1.6),
                      ),
                      if (errorMessage != null) ...<Widget>[
                        const SizedBox(height: 16),
                        Text(
                          errorMessage!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: MusixColors.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
