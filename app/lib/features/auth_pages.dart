import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/state.dart';
import '../data/api.dart';
import '../ui/widgets.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _signUp = false;
  bool _busy = false;
  String? _message;

  String? get _redirect => kIsWeb ? Uri.base.removeFragment().toString() : null;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final auth = Supabase.instance.client.auth;
    try {
      if (_signUp) {
        final res = await auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
          data: {'full_name': _name.text.trim()},
          emailRedirectTo: _redirect,
        );
        if (res.session == null) {
          setState(() => _message = 'Check your email to confirm your account, then sign in.');
        }
      } else {
        await auth.signInWithPassword(email: _email.text.trim(), password: _password.text);
      }
    } catch (e) {
      setState(() => _message = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _message = 'Enter your email first.');
      return;
    }
    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(email, redirectTo: _redirect);
      setState(() => _message = 'Password reset email sent.');
    } catch (e) {
      setState(() => _message = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Form(
                  key: _form,
                  child: AutofillGroup(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Icon(Icons.menu_book_rounded, size: 44, color: scheme.primary),
                      const SizedBox(height: 8),
                      Text('Hisab Kitab', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                      Text('Where is our money?', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 24),
                      if (_signUp) ...[
                        TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Full name')),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(labelText: 'Email'),
                        validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        obscureText: true,
                        autofillHints: [_signUp ? AutofillHints.newPassword : AutofillHints.password],
                        decoration: const InputDecoration(labelText: 'Password'),
                        validator: (v) => (v == null || v.length < (_signUp ? 10 : 1)) ? (_signUp ? 'Use at least 10 characters' : 'Required') : null,
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: _busy
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : Text(_signUp ? 'Create account' : 'Sign in'),
                        ),
                      ),
                      if (_message != null) ...[
                        const SizedBox(height: 12),
                        Text(_message!, textAlign: TextAlign.center),
                      ],
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => setState(() {
                          _signUp = !_signUp;
                          _message = null;
                        }),
                        child: Text(_signUp ? 'Have an account? Sign in' : 'New team member? Request access'),
                      ),
                      if (!_signUp) TextButton(onPressed: _reset, child: const Text('Forgot password?')),
                    ]),
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

class PendingPage extends StatelessWidget {
  const PendingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: EmptyState(
          icon: Icons.hourglass_top,
          title: 'Waiting for approval',
          message: 'Your account (${AppState.session.email}) was created.\nAn admin must give you access in Settings → Users.',
          action: Wrap(spacing: 8, children: [
            OutlinedButton(onPressed: () => AppState.session.reload(), child: const Text('Check again')),
            TextButton(onPressed: () => Supabase.instance.client.auth.signOut(), child: const Text('Sign out')),
          ]),
        ),
      ),
    );
  }
}
