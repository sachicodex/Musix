import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/colors.dart';
import '../../services/auth_service.dart';
import '../../ui/musix_ui.dart';

/// Entry screen after Firebase auth — hosts the main Musix shell.
class AuthenticatedHomeScreen extends StatefulWidget {
  const AuthenticatedHomeScreen({super.key});

  @override
  State<AuthenticatedHomeScreen> createState() =>
      _AuthenticatedHomeScreenState();
}

class _AuthenticatedHomeScreenState extends State<AuthenticatedHomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      final String? message = context
          .read<AuthService>()
          .takePendingSuccessMessage();
      if (message == null) {
        return;
      }

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: MusixColors.success,
          ),
        );
    });
  }

  @override
  Widget build(BuildContext context) {
    return const MusixAuthenticatedHome();
  }
}
